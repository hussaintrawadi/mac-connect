package com.androidbridge.features.gallery

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ThumbnailUtils
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import com.androidbridge.proto.Messages.*
import com.google.protobuf.ByteString
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Serves the phone's photo + video gallery to the Mac. Queries MediaStore.Files
 * for images AND videos (newest first), generates small JPEG thumbnails, and
 * responds in pages. Full-resolution media is fetched by the Mac via the normal
 * file-download path using each item's `path`.
 */
class GalleryBridge(private val context: Context) {

    var onSendEnvelope: ((Envelope) -> Unit)? = null

    private val collection = MediaStore.Files.getContentUri("external")
    private val IMAGE = MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
    private val VIDEO = MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO

    fun handleRequest(request: GalleryRequest) {
        val offset = request.offset.coerceAtLeast(0)
        val limit = if (request.limit > 0) request.limit else 60
        val bucketId = request.bucketId ?: ""

        Thread {
            try {
                val (items, total) = loadMedia(offset, limit, bucketId)
                val response = GalleryResponse.newBuilder()
                    .addAllItems(items)
                    .setTotalCount(total)
                    .setOffset(offset)
                    .build()
                val env = Envelope.newBuilder()
                    .setTimestampMs(System.currentTimeMillis())
                    .setGalleryResponse(response)
                    .build()
                onSendEnvelope?.invoke(env)
                Log.i(TAG, "Sent ${items.size} gallery items (offset=$offset total=$total bucket=$bucketId)")
            } catch (e: Exception) {
                Log.e(TAG, "Gallery load failed", e)
            }
        }.start()
    }

    /** Folders/albums (Camera, Screenshots, WhatsApp, Movies, …) like the phone's gallery. */
    fun handleAlbumsRequest() {
        Thread {
            try {
                val albums = loadAlbums()
                val response = GalleryAlbumsResponse.newBuilder().addAllAlbums(albums).build()
                val env = Envelope.newBuilder()
                    .setTimestampMs(System.currentTimeMillis())
                    .setGalleryAlbumsResponse(response)
                    .build()
                onSendEnvelope?.invoke(env)
                Log.i(TAG, "Sent ${albums.size} gallery albums")
            } catch (e: Exception) {
                Log.e(TAG, "Gallery albums failed", e)
            }
        }.start()
    }

    private val mediaSelection =
        "(${MediaStore.Files.FileColumns.MEDIA_TYPE}=? OR ${MediaStore.Files.FileColumns.MEDIA_TYPE}=?)"
    private val mediaSelectionArgs = arrayOf(IMAGE.toString(), VIDEO.toString())

    private fun loadAlbums(): List<GalleryAlbum> {
        val resolver = context.contentResolver
        val projection = arrayOf(
            MediaStore.Files.FileColumns.BUCKET_ID,
            MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.MEDIA_TYPE
        )
        val sort = "${MediaStore.Files.FileColumns.DATE_ADDED} DESC"
        val cursor = resolver.query(collection, projection, mediaSelection, mediaSelectionArgs, sort)
            ?: return emptyList()

        data class Acc(val name: String, var count: Int, val coverPath: String, val coverIsVideo: Boolean)
        val map = LinkedHashMap<String, Acc>()  // insertion order = newest-first
        var total = 0
        var allCover = ""
        var allCoverVideo = false
        // Virtual "Videos" album spanning all buckets.
        var videoCount = 0
        var videoCover = ""

        cursor.use {
            val idCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_ID)
            val nameCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME)
            val dataCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
            val typeCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            while (it.moveToNext()) {
                val bid = it.getString(idCol) ?: continue
                val path = it.getString(dataCol) ?: ""
                val isVideo = it.getInt(typeCol) == VIDEO
                if (allCover.isEmpty()) { allCover = path; allCoverVideo = isVideo }
                if (isVideo) {
                    videoCount++
                    if (videoCover.isEmpty()) videoCover = path
                }
                total++
                val acc = map[bid]
                if (acc == null) {
                    map[bid] = Acc(it.getString(nameCol) ?: "Album", 1, path, isVideo)
                } else {
                    acc.count++
                }
            }
        }

        val albums = mutableListOf<GalleryAlbum>()
        // Virtual "All Photos" album first (id = "").
        GalleryAlbum.newBuilder().setId("").setName("All Media").setCount(total).also { b ->
            makeThumbnail(allCover, allCoverVideo)?.let { b.coverThumbnail = ByteString.copyFrom(it) }
            albums.add(b.build())
        }
        // Virtual "Videos" album (id = "__videos__") aggregating every video.
        if (videoCount > 0) {
            GalleryAlbum.newBuilder().setId(VIDEOS_BUCKET).setName("Videos").setCount(videoCount).also { b ->
                makeThumbnail(videoCover, true)?.let { b.coverThumbnail = ByteString.copyFrom(it) }
                albums.add(b.build())
            }
        }
        for ((bid, acc) in map) {
            GalleryAlbum.newBuilder().setId(bid).setName(acc.name).setCount(acc.count).also { b ->
                makeThumbnail(acc.coverPath, acc.coverIsVideo)?.let { b.coverThumbnail = ByteString.copyFrom(it) }
                albums.add(b.build())
            }
        }
        return albums
    }

    private fun loadMedia(offset: Int, limit: Int, bucketId: String = ""): Pair<List<GalleryItem>, Int> {
        val items = mutableListOf<GalleryItem>()
        val resolver = context.contentResolver
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.DATE_ADDED,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.WIDTH,
            MediaStore.Files.FileColumns.HEIGHT,
            MediaStore.Files.FileColumns.MEDIA_TYPE
        )
        val sortOrder = "${MediaStore.Files.FileColumns.DATE_ADDED} DESC"

        // Build selection: media-type filter, plus optional bucket / videos-only.
        var selection = mediaSelection
        var args = mediaSelectionArgs
        when {
            bucketId == VIDEOS_BUCKET -> {
                selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE}=?"
                args = arrayOf(VIDEO.toString())
            }
            bucketId.isNotEmpty() -> {
                selection = "$mediaSelection AND ${MediaStore.Files.FileColumns.BUCKET_ID}=?"
                args = arrayOf(IMAGE.toString(), VIDEO.toString(), bucketId)
            }
        }

        val cursor = resolver.query(collection, projection, selection, args, sortOrder)
            ?: return Pair(items, 0)

        cursor.use {
            val total = it.count
            if (offset >= total || !it.moveToPosition(offset)) return Pair(items, total)

            val idCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val nameCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val dateCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_ADDED)
            val sizeCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val dataCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
            val wCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.WIDTH)
            val hCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.HEIGHT)
            val typeCol = it.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)

            var count = 0
            do {
                if (count >= limit) break
                val id = it.getLong(idCol)
                val isVideo = it.getInt(typeCol) == VIDEO
                val name = it.getString(nameCol) ?: if (isVideo) "video_$id.mp4" else "image_$id.jpg"
                val date = it.getLong(dateCol) * 1000L  // DATE_ADDED is seconds
                val size = it.getLong(sizeCol)
                val path = it.getString(dataCol) ?: ""
                val w = it.getInt(wCol)
                val h = it.getInt(hCol)

                if (path.isEmpty()) { count++; continue }

                val builder = GalleryItem.newBuilder()
                    .setId(id.toString())
                    .setPath(path)
                    .setName(name)
                    .setDateTakenMs(date)
                    .setSizeBytes(size)
                    .setIsVideo(isVideo)
                    .setWidth(w)
                    .setHeight(h)

                makeThumbnail(path, isVideo)?.let { thumb -> builder.thumbnail = ByteString.copyFrom(thumb) }
                items.add(builder.build())
                count++
            } while (it.moveToNext())

            return Pair(items, total)
        }
    }

    private fun makeThumbnail(path: String, isVideo: Boolean): ByteArray? {
        return try {
            val bmp = if (isVideo) videoThumbnail(path) else imageThumbnail(path)
            if (bmp == null) return null
            val stream = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 72, stream)
            bmp.recycle()
            stream.toByteArray()
        } catch (e: Exception) {
            Log.w(TAG, "Thumbnail failed: $path", e)
            null
        }
    }

    private fun imageThumbnail(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0) return null

        val target = 256
        var sample = 1
        val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
        while (maxDim / (sample * 2) >= target) sample *= 2

        val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        val scale = target.toFloat() / maxOf(decoded.width, decoded.height)
        val tw = (decoded.width * scale).toInt().coerceAtLeast(1)
        val th = (decoded.height * scale).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(decoded, tw, th, true)
        if (scaled != decoded) decoded.recycle()
        return scaled
    }

    private fun videoThumbnail(path: String): Bitmap? {
        val file = File(path)
        if (!file.exists()) return null
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ThumbnailUtils.createVideoThumbnail(file, Size(256, 256), null)
            } else {
                @Suppress("DEPRECATION")
                ThumbnailUtils.createVideoThumbnail(path, MediaStore.Images.Thumbnails.MINI_KIND)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Video thumb failed: $path", e)
            null
        }
    }

    companion object {
        private const val TAG = "GalleryBridge"
        private const val VIDEOS_BUCKET = "__videos__"
        var instance: GalleryBridge? = null
    }
}
