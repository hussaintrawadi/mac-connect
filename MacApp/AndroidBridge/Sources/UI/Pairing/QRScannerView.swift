import SwiftUI
import AVFoundation
import os

struct QRScannerView: NSViewRepresentable {
    let onCodeScanned: (String) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = QRCameraView()
        view.onCodeScanned = onCodeScanned
        view.startScanning()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class QRCameraView: NSView, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "QRScanner")
    private var hasScanned = false

    func startScanning() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            logger.error("No camera available")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }

            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = bounds
            previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer = CALayer()
            layer?.addSublayer(previewLayer)
            wantsLayer = true

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                session.startRunning()
            }

            logger.info("QR scanner started")
        } catch {
            logger.error("Camera setup failed: \(error.localizedDescription)")
        }
    }

    func stopScanning() {
        session.stopRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else {
            return
        }

        hasScanned = true
        logger.info("QR code scanned")
        stopScanning()
        onCodeScanned?(value)
    }
}
