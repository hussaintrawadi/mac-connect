package com.androidbridge.ui.pairing

import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.androidbridge.R
import com.androidbridge.connection.PairingStore
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import org.json.JSONObject

class PairingActivity : AppCompatActivity() {

    private lateinit var pairingStore: PairingStore
    private lateinit var statusText: TextView

    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        if (result.contents != null) {
            handleScanResult(result.contents)
        } else {
            statusText.text = "Scan cancelled. Tap to try again."
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_pairing)

        pairingStore = PairingStore(this)
        pairingStore.generateKeyPair()

        statusText = findViewById(R.id.statusText)

        findViewById<com.google.android.material.button.MaterialButton>(R.id.scanButton)
            .setOnClickListener { launchScanner() }

        findViewById<com.google.android.material.button.MaterialButton>(R.id.cancelButton)
            .setOnClickListener {
                setResult(RESULT_CANCELED)
                finish()
            }
    }

    private fun launchScanner() {
        val options = ScanOptions().apply {
            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            setPrompt("")
            setCameraId(0)
            setBeepEnabled(false)
            setOrientationLocked(true)
            setCaptureActivity(ScannerActivity::class.java)
        }
        scanLauncher.launch(options)
    }

    private fun handleScanResult(contents: String) {
        runOnUiThread { statusText.text = "Connecting to Mac..." }

        Thread {
            try {
                val payload = JSONObject(contents)
                val version = payload.optInt("v", 0)
                if (version != PROTOCOL_VERSION) {
                    runOnUiThread { statusText.text = "Incompatible version. Update both apps." }
                    return@Thread
                }

                val port = payload.getInt("port")

                // Collect all IPs to try
                val ipsToTry = mutableListOf<String>()
                val primaryIp = payload.optString("ip", "")
                if (primaryIp.isNotEmpty() && primaryIp != "0.0.0.0") {
                    ipsToTry.add(primaryIp)
                }
                val ipsArray = payload.optJSONArray("ips")
                if (ipsArray != null) {
                    for (i in 0 until ipsArray.length()) {
                        val ip = ipsArray.getString(i)
                        if (ip !in ipsToTry && ip != "0.0.0.0") {
                            ipsToTry.add(ip)
                        }
                    }
                }

                if (ipsToTry.isEmpty()) {
                    runOnUiThread { statusText.text = "No IP address in QR code. Re-open pairing on Mac." }
                    return@Thread
                }

                Log.i(TAG, "Will try IPs: $ipsToTry on port $port")

                var connected = false
                var lastError: Exception? = null

                for (ip in ipsToTry) {
                    try {
                        Log.i(TAG, "Trying $ip:$port ...")
                        runOnUiThread { statusText.text = "Connecting to Mac..." }

                        val socket = java.net.Socket()
                        socket.connect(java.net.InetSocketAddress(ip, port), 5_000)
                        socket.soTimeout = 10_000

                        val input = socket.getInputStream()
                        val output = socket.getOutputStream()

                        // Step 1: READ Mac's info (Mac sends first)
                        val macHeader = readExactly(input, 4)
                        val macLength = ((macHeader[0].toInt() and 0xFF) shl 24) or
                            ((macHeader[1].toInt() and 0xFF) shl 16) or
                            ((macHeader[2].toInt() and 0xFF) shl 8) or
                            (macHeader[3].toInt() and 0xFF)

                        val macPayload = readExactly(input, macLength)
                        val macInfo = JSONObject(String(macPayload))
                        val macId = macInfo.getString("id")
                        val macPublicKeyB64 = macInfo.optString("pk", "")
                        val macName = macInfo.optString("name", "Mac")

                        Log.i(TAG, "Received Mac info: $macName (${macId.take(8)})")

                        // Step 2: SEND Android's info back
                        val publicKeyBytes = pairingStore.getPublicKeyBytes()
                        val deviceName = "${Build.MANUFACTURER} ${Build.MODEL}"
                        val androidInfo = JSONObject().apply {
                            put("id", pairingStore.getDeviceId())
                            put("pk", Base64.encodeToString(publicKeyBytes, Base64.NO_WRAP))
                            put("name", deviceName)
                        }.toString().toByteArray()

                        val header = ByteArray(4)
                        header[0] = (androidInfo.size shr 24 and 0xFF).toByte()
                        header[1] = (androidInfo.size shr 16 and 0xFF).toByte()
                        header[2] = (androidInfo.size shr 8 and 0xFF).toByte()
                        header[3] = (androidInfo.size and 0xFF).toByte()
                        output.write(header)
                        output.write(androidInfo)
                        output.flush()

                        socket.close()

                        // Store pairing
                        val macPublicKeyBytes = if (macPublicKeyB64.isNotEmpty()) {
                            Base64.decode(macPublicKeyB64, Base64.NO_WRAP)
                        } else {
                            macId.toByteArray()
                        }
                        val fingerprint = sha256Hex(macPublicKeyBytes)
                        pairingStore.savePairedMac(macId, fingerprint)

                        Log.i(TAG, "Paired with $macName via $ip")

                        runOnUiThread {
                            statusText.text = "Paired with $macName!"
                            Toast.makeText(this, "Paired with $macName", Toast.LENGTH_SHORT).show()
                            setResult(RESULT_OK)
                            finish()
                        }
                        connected = true
                        break

                    } catch (e: java.net.ConnectException) {
                        Log.w(TAG, "Connection refused on $ip:$port", e)
                        lastError = e
                    } catch (e: java.net.SocketTimeoutException) {
                        Log.w(TAG, "Timeout on $ip:$port", e)
                        lastError = e
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed on $ip:$port", e)
                        lastError = e
                    }
                }

                if (!connected) {
                    val msg = when (lastError) {
                        is java.net.ConnectException -> "Connection refused. Make sure Mac Connect is open on your Mac."
                        is java.net.SocketTimeoutException -> "Timed out. Check both devices are on the same Wi-Fi."
                        else -> "Could not connect: ${lastError?.message ?: "unknown error"}"
                    }
                    runOnUiThread { statusText.text = msg }
                }
            } catch (e: org.json.JSONException) {
                Log.e(TAG, "Invalid QR code data", e)
                runOnUiThread { statusText.text = "Invalid QR code. Scan the Mac Connect QR code." }
            } catch (e: Exception) {
                Log.e(TAG, "Pairing failed", e)
                runOnUiThread { statusText.text = "Pairing failed: ${e.message}" }
            }
        }.start()
    }

    private fun readExactly(input: java.io.InputStream, count: Int): ByteArray {
        val buf = ByteArray(count)
        var read = 0
        while (read < count) {
            val n = input.read(buf, read, count - read)
            if (n == -1) throw java.io.EOFException("Connection closed")
            read += n
        }
        return buf
    }

    private fun sha256Hex(data: ByteArray): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        return digest.digest(data).joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val TAG = "PairingActivity"
        private const val PROTOCOL_VERSION = 1
    }
}
