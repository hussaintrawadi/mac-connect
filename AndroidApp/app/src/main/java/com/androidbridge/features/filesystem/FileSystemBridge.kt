package com.androidbridge.features.filesystem

import android.content.Context
import android.content.Intent
import android.os.Environment
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.androidbridge.proto.Messages.*
import com.google.protobuf.ByteString
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

class FileSystemBridge(private val context: Context? = null) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    private val activeUploads = mutableMapOf<String, UploadState>()

    private data class UploadState(
        val file: FileOutputStream,
        val destPath: String,
        val totalSize: Long,
        var receivedSize: Long = 0,
        val shareAfter: Boolean = false
    )

    fun handleListRequest(request: FileListRequest) {
        val path = if (request.path.isNullOrEmpty()) {
            Environment.getExternalStorageDirectory().absolutePath
        } else {
            request.path
        }

        val dir = File(path)
        if (!dir.exists() || !dir.isDirectory) {
            Log.w(TAG, "Invalid directory: $path")
            sendFileList(path, emptyList())
            return
        }

        val allFiles = dir.listFiles()
        Log.i(TAG, "listFiles() for $path returned ${allFiles?.size ?: "null"} items, canRead=${dir.canRead()}")

        // Direct File access (works fully only with All-Files-Access / MANAGE_EXTERNAL_STORAGE).
        val byPath = LinkedHashMap<String, FileEntry>()
        allFiles
            ?.filter { !it.name.startsWith(".") }
            ?.forEach { file ->
                byPath[file.absolutePath] = FileEntry.newBuilder()
                    .setName(file.name)
                    .setPath(file.absolutePath)
                    .setIsDirectory(file.isDirectory)
                    .setSizeBytes(if (file.isFile) file.length() else 0)
                    .setModifiedMs(file.lastModified())
                    .setMimeType(getMimeType(file))
                    .build()
            }

        // Fallback: even without full storage access, MediaStore lets us see media
        // files (photos/videos/audio/downloads). Merge any direct children not already
        // listed, so folders aren't shown empty.
        for (entry in mediaStoreChildren(path)) {
            if (!byPath.containsKey(entry.path)) byPath[entry.path] = entry
        }

        val entries = byPath.values
            .sortedWith(compareBy<FileEntry> { !it.isDirectory }.thenBy { it.name.lowercase() })

        val dirs = entries.count { it.isDirectory }
        val files = entries.count { !it.isDirectory }
        Log.i(TAG, "Listed $dirs dirs + $files files in $path (total=${entries.size})")

        // Two-phase response: ship the listing immediately (instant navigation),
        // then re-send it with thumbnails once they're generated.
        sendFileList(path, entries)

        Thread {
            val hasMedia = entries.any {
                !it.isDirectory && (it.mimeType.startsWith("image/") || it.mimeType.startsWith("video/"))
            }
            if (!hasMedia) return@Thread

            // Generate previews in parallel (was sequential — slow on media-heavy folders).
            val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6)
            val pool = java.util.concurrent.Executors.newFixedThreadPool(threads)
            val budget = java.util.concurrent.atomic.AtomicInteger(60)
            try {
                val withThumbs = entries.map { entry ->
                    pool.submit(java.util.concurrent.Callable {
                        if (!entry.isDirectory &&
                            (entry.mimeType.startsWith("image/") || entry.mimeType.startsWith("video/")) &&
                            budget.getAndDecrement() > 0
                        ) {
                            val thumb = fileThumbnail(entry.path, entry.mimeType.startsWith("video/"))
                            if (thumb != null) entry.toBuilder().setThumbnail(ByteString.copyFrom(thumb)).build()
                            else entry
                        } else entry
                    })
                }.map { it.get() }
                sendFileList(path, withThumbs)
            } finally {
                pool.shutdown()
            }
        }.start()
    }

    /** Finder-style file management from the Mac: new folder, rename, delete. */
    fun handleFileOperation(op: FileOperation) {
        var success = false
        var error = ""
        var parent = op.path
        try {
            when (op.op) {
                FileOperation.Op.CREATE_DIR -> {
                    val dir = File(op.path, op.name.ifEmpty { "New Folder" })
                    success = dir.mkdirs() || dir.exists()
                    if (!success) error = "Could not create folder"
                    parent = op.path
                }
                FileOperation.Op.RENAME -> {
                    val src = File(op.path)
                    val dst = File(src.parentFile, op.name)
                    success = src.exists() && !dst.exists() && src.renameTo(dst)
                    if (!success) error = if (dst.exists()) "Name already taken" else "Rename failed"
                    parent = src.parent ?: op.path
                }
                FileOperation.Op.DELETE -> {
                    val target = File(op.path)
                    success = target.deleteRecursively()
                    if (!success) error = "Delete failed"
                    parent = target.parent ?: op.path
                }
                else -> error = "Unknown operation"
            }
            // Keep MediaStore in sync so the gallery/file fallback reflects changes.
            if (success) {
                context?.let {
                    android.media.MediaScannerConnection.scanFile(it, arrayOf(parent), null, null)
                }
            }
        } catch (e: Exception) {
            error = e.message ?: "Operation failed"
        }

        val result = FileOperationResult.newBuilder()
            .setSuccess(success)
            .setError(error)
            .setParentPath(parent)
            .build()
        val env = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setFileOperationResult(result)
            .build()
        onSendEnvelope?.invoke(env)
        Log.i(TAG, "File op ${op.op} -> success=$success $error")
    }

    /** Tiny JPEG preview for the Mac file list (64px, quality 60). */
    private fun fileThumbnail(path: String, isVideo: Boolean): ByteArray? {
        return try {
            val bmp: android.graphics.Bitmap? = if (isVideo) {
                val f = File(path)
                if (!f.exists()) return null
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                    android.media.ThumbnailUtils.createVideoThumbnail(f, android.util.Size(64, 64), null)
                } else {
                    @Suppress("DEPRECATION")
                    android.media.ThumbnailUtils.createVideoThumbnail(
                        path, android.provider.MediaStore.Images.Thumbnails.MICRO_KIND
                    )
                }
            } else {
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeFile(path, bounds)
                if (bounds.outWidth <= 0) return null
                var sample = 1
                val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
                while (maxDim / (sample * 2) >= 64) sample *= 2
                android.graphics.BitmapFactory.decodeFile(
                    path, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
                )
            }
            if (bmp == null) return null
            val scale = 64f / maxOf(bmp.width, bmp.height)
            val scaled = android.graphics.Bitmap.createScaledBitmap(
                bmp,
                (bmp.width * scale).toInt().coerceAtLeast(1),
                (bmp.height * scale).toInt().coerceAtLeast(1),
                true
            )
            val out = java.io.ByteArrayOutputStream()
            scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 60, out)
            if (scaled != bmp) scaled.recycle()
            bmp.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    /** Direct-child media files of [parentPath] from MediaStore (no MANAGE_EXTERNAL_STORAGE needed). */
    private fun mediaStoreChildren(parentPath: String): List<FileEntry> {
        val ctx = context ?: return emptyList()
        val result = mutableListOf<FileEntry>()
        return try {
            val collection = android.provider.MediaStore.Files.getContentUri("external")
            val projection = arrayOf(
                android.provider.MediaStore.Files.FileColumns.DATA,
                android.provider.MediaStore.Files.FileColumns.DISPLAY_NAME,
                android.provider.MediaStore.Files.FileColumns.SIZE,
                android.provider.MediaStore.Files.FileColumns.DATE_MODIFIED
            )
            val prefix = if (parentPath.endsWith("/")) parentPath else "$parentPath/"
            val sel = "${android.provider.MediaStore.Files.FileColumns.DATA} LIKE ?"
            val args = arrayOf("$prefix%")
            ctx.contentResolver.query(collection, projection, sel, args, null)?.use { c ->
                val dataCol = c.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DATA)
                val nameCol = c.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DISPLAY_NAME)
                val sizeCol = c.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.SIZE)
                val modCol = c.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DATE_MODIFIED)
                while (c.moveToNext()) {
                    val data = c.getString(dataCol) ?: continue
                    // Only DIRECT children of parentPath (no nested sub-paths).
                    val rest = data.removePrefix(prefix)
                    if (rest.isEmpty() || rest.contains("/")) continue
                    val name = c.getString(nameCol) ?: rest
                    if (name.startsWith(".")) continue
                    result.add(
                        FileEntry.newBuilder()
                            .setName(name)
                            .setPath(data)
                            .setIsDirectory(false)
                            .setSizeBytes(c.getLong(sizeCol))
                            .setModifiedMs(c.getLong(modCol) * 1000L)
                            .setMimeType(getMimeType(File(data)))
                            .build()
                    )
                }
            }
            result
        } catch (e: Exception) {
            Log.w(TAG, "MediaStore children failed for $parentPath", e)
            emptyList()
        }
    }

    fun handleDownloadRequest(request: FileDownloadRequest) {
        val file = File(request.path)
        if (!file.exists() || !file.isFile) {
            Log.w(TAG, "File not found: ${request.path}")
            sendTransferComplete(request.transferId, ByteArray(0))
            return
        }

        Log.i(TAG, "Starting download: ${file.name} (${file.length()} bytes)")

        Thread {
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                val input = FileInputStream(file)
                val buffer = ByteArray(CHUNK_SIZE)
                var chunkIndex = 0
                var bytesRead: Int

                while (input.read(buffer).also { bytesRead = it } != -1) {
                    digest.update(buffer, 0, bytesRead)

                    val chunk = FileChunk.newBuilder()
                        .setTransferId(request.transferId)
                        .setChunkIndex(chunkIndex)
                        .setData(ByteString.copyFrom(buffer, 0, bytesRead))
                        .setIsLast(false)
                        .build()

                    val envelope = Envelope.newBuilder()
                        .setTimestampMs(System.currentTimeMillis())
                        .setFileChunk(chunk)
                        .build()
                    onSendEnvelope?.invoke(envelope)

                    chunkIndex++
                }

                input.close()

                // Send final empty chunk with isLast=true
                val lastChunk = FileChunk.newBuilder()
                    .setTransferId(request.transferId)
                    .setChunkIndex(chunkIndex)
                    .setData(ByteString.EMPTY)
                    .setIsLast(true)
                    .build()
                val lastEnvelope = Envelope.newBuilder()
                    .setTimestampMs(System.currentTimeMillis())
                    .setFileChunk(lastChunk)
                    .build()
                onSendEnvelope?.invoke(lastEnvelope)

                sendTransferComplete(request.transferId, digest.digest())
                Log.i(TAG, "Download complete: ${file.name} ($chunkIndex chunks)")
            } catch (e: Exception) {
                Log.e(TAG, "Download failed: ${file.name}", e)
                sendTransferCancel(request.transferId, e.message ?: "Download failed")
            }
        }.start()
    }

    fun handleUploadRequest(request: FileUploadRequest) {
        val destDir = if (request.destinationPath.isNullOrEmpty()) {
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        } else {
            File(request.destinationPath)
        }

        destDir.mkdirs()
        val destFile = File(destDir, request.fileName)

        try {
            val fos = FileOutputStream(destFile)
            activeUploads[request.transferId] = UploadState(
                file = fos,
                destPath = destFile.absolutePath,
                totalSize = request.totalSize,
                shareAfter = request.shareAfter
            )
            Log.i(TAG, "Upload started: ${request.fileName} → ${destFile.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start upload", e)
            sendTransferCancel(request.transferId, e.message ?: "Cannot create file")
        }
    }

    fun handleFileChunk(chunk: FileChunk) {
        val upload = activeUploads[chunk.transferId] ?: return

        try {
            if (chunk.data.size() > 0) {
                upload.file.write(chunk.data.toByteArray())
                upload.receivedSize += chunk.data.size()
            }

            if (chunk.isLast) {
                upload.file.flush()
                upload.file.close()
                activeUploads.remove(chunk.transferId)

                val file = File(upload.destPath)
                val digest = MessageDigest.getInstance("SHA-256")
                val hash = digest.digest(file.readBytes())

                sendTransferComplete(chunk.transferId, hash)
                Log.i(TAG, "Upload complete: ${upload.destPath} (${upload.receivedSize} bytes)")

                if (upload.shareAfter) {
                    shareFile(upload.destPath)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Chunk write failed", e)
            upload.file.close()
            activeUploads.remove(chunk.transferId)
            sendTransferCancel(chunk.transferId, e.message ?: "Write failed")
        }
    }

    fun handleTransferCancel(cancel: FileTransferCancel) {
        val upload = activeUploads.remove(cancel.transferId)
        upload?.file?.close()
        Log.i(TAG, "Transfer cancelled: ${cancel.transferId} — ${cancel.reason}")
    }

    private fun sendFileList(path: String, entries: List<FileEntry>) {
        val response = FileListResponse.newBuilder()
            .setPath(path)
            .addAllEntries(entries)
            .build()
        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setFileListResponse(response)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    private fun sendTransferComplete(transferId: String, sha256: ByteArray) {
        val complete = FileTransferComplete.newBuilder()
            .setTransferId(transferId)
            .setSha256(ByteString.copyFrom(sha256))
            .build()
        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setFileTransferComplete(complete)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    private fun sendTransferCancel(transferId: String, reason: String) {
        val cancel = FileTransferCancel.newBuilder()
            .setTransferId(transferId)
            .setReason(reason)
            .build()
        val envelope = Envelope.newBuilder()
            .setTimestampMs(System.currentTimeMillis())
            .setFileTransferCancel(cancel)
            .build()
        onSendEnvelope?.invoke(envelope)
    }

    /// Opens the Android share sheet for a file dropped from the Mac, so the user
    /// can send it into any app (editor, WhatsApp, etc.).
    private fun shareFile(path: String) {
        val ctx = context ?: return
        try {
            val file = File(path)
            val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = getMimeType(file)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(sendIntent, "Open with").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            ctx.startActivity(chooser)
            Log.i(TAG, "Share sheet opened for $path")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to share $path", e)
        }
    }

    private fun getMimeType(file: File): String {
        if (file.isDirectory) return "inode/directory"
        val ext = file.extension.lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    // MARK: - AirDrop push (phone → Mac)

    /**
     * Stream a shared content:// file to the Mac (AirDrop-style). The Mac saves it
     * into ~/Downloads and reveals it in Finder. Returns false if we're not connected.
     */
    fun pushUriToMac(uri: android.net.Uri): Boolean {
        val ctx = context ?: return false
        val send = onSendEnvelope ?: return false   // null = not connected

        val (name, size) = queryNameAndSize(ctx, uri)
        val transferId = UUID.randomUUID().toString()

        Thread {
            try {
                // Announce the incoming file so the Mac opens a receive slot.
                val req = FileUploadRequest.newBuilder()
                    .setDestinationPath("")            // "" → Mac's Downloads
                    .setFileName(name)
                    .setTotalSize(size)
                    .setTransferId(transferId)
                    .setShareAfter(false)
                    .build()
                send(Envelope.newBuilder().setTimestampMs(System.currentTimeMillis())
                    .setFileUploadRequest(req).build())

                var index = 0
                ctx.contentResolver.openInputStream(uri)?.use { input ->
                    val buffer = ByteArray(CHUNK_SIZE)
                    var read: Int
                    while (input.read(buffer).also { read = it } != -1) {
                        val chunk = FileChunk.newBuilder()
                            .setTransferId(transferId)
                            .setChunkIndex(index)
                            .setData(ByteString.copyFrom(buffer, 0, read))
                            .setIsLast(false)
                            .build()
                        send(Envelope.newBuilder().setTimestampMs(System.currentTimeMillis())
                            .setFileChunk(chunk).build())
                        index++
                    }
                }
                // Final marker chunk.
                val last = FileChunk.newBuilder()
                    .setTransferId(transferId)
                    .setChunkIndex(index)
                    .setData(ByteString.EMPTY)
                    .setIsLast(true)
                    .build()
                send(Envelope.newBuilder().setTimestampMs(System.currentTimeMillis())
                    .setFileChunk(last).build())
                Log.i(TAG, "Pushed $name ($size bytes) to Mac")
            } catch (e: Exception) {
                Log.e(TAG, "Push to Mac failed for $uri", e)
                sendTransferCancel(transferId, e.message ?: "Send failed")
            }
        }.start()
        return true
    }

    private fun queryNameAndSize(ctx: Context, uri: android.net.Uri): Pair<String, Long> {
        var name = "shared_file"
        var size = 0L
        try {
            ctx.contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val nameIdx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    val sizeIdx = c.getColumnIndex(android.provider.OpenableColumns.SIZE)
                    if (nameIdx >= 0 && !c.isNull(nameIdx)) name = c.getString(nameIdx)
                    if (sizeIdx >= 0 && !c.isNull(sizeIdx)) size = c.getLong(sizeIdx)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not resolve name/size for $uri", e)
        }
        return name to size
    }

    companion object {
        private const val TAG = "FileSystemBridge"
        private const val CHUNK_SIZE = 64 * 1024 // 64 KB chunks
        var instance: FileSystemBridge? = null
    }
}
