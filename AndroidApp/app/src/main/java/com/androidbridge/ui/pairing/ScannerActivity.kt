package com.androidbridge.ui.pairing

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import com.androidbridge.R
import com.google.android.material.button.MaterialButton
import com.journeyapps.barcodescanner.CaptureManager
import com.journeyapps.barcodescanner.DecoratedBarcodeView

/**
 * Custom full-screen QR scanner. Uses ZXing's [CaptureManager] for all the
 * camera/decoding lifecycle so the result is returned in the exact format the
 * pairing flow's ScanContract expects — but with our own branded UI on top
 * (framed viewfinder, header, flashlight toggle) instead of the stock screen.
 */
class ScannerActivity : AppCompatActivity() {

    private lateinit var capture: CaptureManager
    private lateinit var barcodeView: DecoratedBarcodeView
    private var torchOn = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_scanner)

        barcodeView = findViewById(R.id.barcodeScanner)
        // Hide the stock status text; our own header explains what to do.
        barcodeView.setStatusText("")

        capture = CaptureManager(this, barcodeView)
        capture.initializeFromIntent(intent, savedInstanceState)
        capture.setShowMissingCameraPermissionDialog(true)
        capture.decode()

        findViewById<MaterialButton>(R.id.torchButton).setOnClickListener { toggleTorch() }
        findViewById<MaterialButton>(R.id.cancelButton).setOnClickListener {
            setResult(RESULT_CANCELED)
            finish()
        }
    }

    private fun toggleTorch() {
        torchOn = !torchOn
        if (torchOn) barcodeView.setTorchOn() else barcodeView.setTorchOff()
    }

    override fun onResume() {
        super.onResume()
        capture.onResume()
    }

    override fun onPause() {
        super.onPause()
        capture.onPause()
    }

    override fun onDestroy() {
        super.onDestroy()
        capture.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        capture.onSaveInstanceState(outState)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        capture.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
