import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import os

final class ScreenMirrorFeature: ObservableObject {
    @Published var isActive = false
    @Published var videoWidth: Int = 0
    @Published var videoHeight: Int = 0
    @Published var framesReceived: Int = 0
    @Published var framesDecoded: Int = 0

    private let logger = Logger(subsystem: "com.androidbridge.mac", category: "ScreenMirror")
    var onSendEnvelope: ((ABEnvelope) -> Void)?

    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            if displayLayer != nil {
                logger.info("Display layer attached — flushing \(self.pendingBuffers.count) pending frames")
                for buffer in pendingBuffers {
                    displayLayer?.enqueue(buffer)
                }
                pendingBuffers.removeAll()
            }
        }
    }
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    private var spsData: Data?
    private var ppsData: Data?
    private var lastFrameTime = CMTime.zero
    private var pendingBuffers: [CMSampleBuffer] = []
    private var frameCount = 0

    // MARK: - Config

    func handleVideoConfig(_ config: ABVideoConfig) {
        DispatchQueue.main.async {
            self.videoWidth = Int(config.width)
            self.videoHeight = Int(config.height)
            self.isActive = true
        }
        logger.info("Video config: \(config.width)x\(config.height) @ \(config.fps)fps")
    }

    // MARK: - Frame Handling

    func handleVideoFrame(_ frame: ABVideoFrame) {
        let nalData = frame.data
        guard !nalData.isEmpty else { return }

        frameCount += 1
        DispatchQueue.main.async { self.framesReceived = self.frameCount }
        if frameCount % 60 == 1 {
            logger.info("Video frame #\(self.frameCount): \(nalData.count) bytes, keyframe=\(frame.isKeyframe), layer=\(self.displayLayer != nil ? "yes" : "no")")
        }

        // Parse H.264 NAL units
        processNALUnits(nalData, timestampUs: frame.timestampUs, isKeyframe: frame.isKeyframe)
    }

    private func processNALUnits(_ data: Data, timestampUs: UInt64, isKeyframe: Bool) {
        var offset = 0

        while offset < data.count {
            // Look for NAL start codes (0x00000001 or 0x000001)
            var nalStart = -1
            var startCodeLen = 0

            if offset + 4 <= data.count {
                if data[offset] == 0 && data[offset+1] == 0 && data[offset+2] == 0 && data[offset+3] == 1 {
                    nalStart = offset + 4
                    startCodeLen = 4
                } else if data[offset] == 0 && data[offset+1] == 0 && data[offset+2] == 1 {
                    nalStart = offset + 3
                    startCodeLen = 3
                }
            }

            if nalStart == -1 {
                // No start code — treat entire data as one NAL unit (Annex B without start codes)
                handleSingleNAL(data, timestampUs: timestampUs)
                return
            }

            // Find next start code
            var nalEnd = data.count
            for i in nalStart..<(data.count - 3) {
                if data[i] == 0 && data[i+1] == 0 && (data[i+2] == 1 || (data[i+2] == 0 && i + 3 < data.count && data[i+3] == 1)) {
                    nalEnd = i
                    break
                }
            }

            let nalUnit = data[nalStart..<nalEnd]
            handleSingleNAL(Data(nalUnit), timestampUs: timestampUs)

            offset = nalEnd
        }
    }

    private func handleSingleNAL(_ nalData: Data, timestampUs: UInt64) {
        guard !nalData.isEmpty else { return }

        let nalType = nalData[0] & 0x1F

        switch nalType {
        case 7: // SPS
            spsData = nalData
            logger.debug("Received SPS (\(nalData.count) bytes)")
            tryCreateDecoder()

        case 8: // PPS
            ppsData = nalData
            logger.debug("Received PPS (\(nalData.count) bytes)")
            tryCreateDecoder()

        case 5, 1: // IDR (keyframe) or non-IDR slice
            decodeFrame(nalData, timestampUs: timestampUs)

        default:
            logger.debug("NAL type \(nalType) (\(nalData.count) bytes)")
        }
    }

    // MARK: - Decoder

    private func tryCreateDecoder() {
        guard let sps = spsData, let pps = ppsData else { return }
        guard decompressionSession == nil else { return }

        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        let sizes = [sps.count, pps.count]

        var formatDesc: CMFormatDescription?
        let status = spsBytes.withUnsafeBufferPointer { spsBuf in
            ppsBytes.withUnsafeBufferPointer { ppsBuf in
                let parameterSets = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                return parameterSets.withUnsafeBufferPointer { paramBuf in
                    sizes.withUnsafeBufferPointer { sizesBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: nil,
                            parameterSetCount: 2,
                            parameterSetPointers: paramBuf.baseAddress!,
                            parameterSetSizes: sizesBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc
                        )
                    }
                }
            }
        }

        guard status == noErr, let desc = formatDesc else {
            logger.error("Failed to create format description: \(status)")
            return
        }

        formatDescription = desc

        let decoderConfig: [String: Any] = [
            kVTDecompressionPropertyKey_RealTime as String: true
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, flags, imageBuffer, pts, duration in
                guard status == noErr, let imageBuffer else { return }
                let feature = Unmanaged<ScreenMirrorFeature>.fromOpaque(refcon!).takeUnretainedValue()
                feature.didDecodeFrame(imageBuffer, pts: pts)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        guard createStatus == noErr, let session else {
            logger.error("Failed to create decompression session: \(createStatus)")
            return
        }

        decompressionSession = session
        logger.info("H.264 decoder created")
    }

    private func decodeFrame(_ nalData: Data, timestampUs: UInt64) {
        guard let session = decompressionSession, let formatDesc = formatDescription else {
            return
        }

        // Convert to AVCC format (4-byte length prefix instead of start code)
        var avccData = Data(count: 4 + nalData.count)
        let nalLen = UInt32(nalData.count).bigEndian
        avccData.replaceSubrange(0..<4, with: withUnsafeBytes(of: nalLen) { Data($0) })
        avccData.replaceSubrange(4..<(4 + nalData.count), with: nalData)

        let dataLength = avccData.count
        let pts = CMTimeMake(value: Int64(timestampUs), timescale: 1_000_000)

        // Copy data into a CMBlockBuffer so it owns the memory
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return }

        status = avccData.withUnsafeBytes { rawBuf in
            CMBlockBufferReplaceDataBytes(
                with: rawBuf.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard status == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
        )

        CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sample = sampleBuffer else { return }

        let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        var infoFlags = VTDecodeInfoFlags()

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: decodeFlags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
    }

    private func didDecodeFrame(_ imageBuffer: CVImageBuffer, pts: CMTime) {
        guard let formatDesc = makeFormatDescription(for: imageBuffer) else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: CMTime.invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil,
            imageBuffer: imageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard let buffer = sampleBuffer else { return }

        // Tell the display layer to render this frame IMMEDIATELY instead of waiting
        // on a presentation timebase (which we never drive). Without this the layer
        // shows only the first frame and then freezes — exactly the "static image" bug.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        DispatchQueue.main.async {
            self.framesDecoded += 1
            if let layer = self.displayLayer {
                // If the layer has entered a failed state, flush so it can resume rendering.
                if layer.status == .failed {
                    layer.flush()
                }
                layer.enqueue(buffer)
            } else {
                // Queue the buffer until the display layer is attached
                self.pendingBuffers.append(buffer)
                // Keep at most 5 pending frames to avoid memory buildup
                if self.pendingBuffers.count > 5 {
                    self.pendingBuffers.removeFirst()
                }
                self.logger.debug("Display layer not ready — queued frame (pending: \(self.pendingBuffers.count))")
            }
        }
    }

    // MARK: - Input Events → Android

    func sendTouchDown(normalizedX: Float, normalizedY: Float) {
        var touch = ABTouchEvent()
        touch.action = .down
        touch.x = normalizedX
        touch.y = normalizedY

        var envelope = ABEnvelope()
        envelope.touchEvent = touch
        onSendEnvelope?(envelope)
    }

    func sendTouchMove(normalizedX: Float, normalizedY: Float) {
        var touch = ABTouchEvent()
        touch.action = .move
        touch.x = normalizedX
        touch.y = normalizedY

        var envelope = ABEnvelope()
        envelope.touchEvent = touch
        onSendEnvelope?(envelope)
    }

    func sendTouchUp(normalizedX: Float, normalizedY: Float) {
        var touch = ABTouchEvent()
        touch.action = .up
        touch.x = normalizedX
        touch.y = normalizedY

        var envelope = ABEnvelope()
        envelope.touchEvent = touch
        onSendEnvelope?(envelope)
    }

    /// Inject a directional swipe (down → move → up) — used by the context-menu
    /// swipe buttons as a reliable alternative to the trackpad.
    func sendSwipe(fromX: Float, fromY: Float, toX: Float, toY: Float) {
        sendTouchDown(normalizedX: fromX, normalizedY: fromY)
        sendTouchMove(normalizedX: (fromX + toX) / 2, normalizedY: (fromY + toY) / 2)
        sendTouchUp(normalizedX: toX, normalizedY: toY)
    }

    func sendLongPress(normalizedX: Float, normalizedY: Float) {
        var touch = ABTouchEvent()
        touch.action = .longPress
        touch.x = normalizedX
        touch.y = normalizedY

        var envelope = ABEnvelope()
        envelope.touchEvent = touch
        onSendEnvelope?(envelope)
    }

    func sendScroll(normalizedX: Float, normalizedY: Float, deltaY: Float) {
        var scroll = ABScrollEvent()
        scroll.x = normalizedX
        scroll.y = normalizedY
        scroll.dy = deltaY

        var envelope = ABEnvelope()
        envelope.scrollEvent = scroll
        onSendEnvelope?(envelope)
    }

    func sendKeyText(_ text: String) {
        var key = ABKeyEvent()
        key.text = text
        key.isPress = true

        var envelope = ABEnvelope()
        envelope.keyEvent = key
        onSendEnvelope?(envelope)
    }

    func sendSpecialKey(_ keyCode: Int32) {
        var key = ABKeyEvent()
        key.keyCode = keyCode
        key.isPress = true

        var envelope = ABEnvelope()
        envelope.keyEvent = key
        onSendEnvelope?(envelope)
    }

    // MARK: - Cleanup

    func stop() {
        decompressionSession = nil
        formatDescription = nil
        spsData = nil
        ppsData = nil
        pendingBuffers.removeAll()
        frameCount = 0
        DispatchQueue.main.async {
            self.isActive = false
        }
    }

    private func makeFormatDescription(for imageBuffer: CVImageBuffer) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }
}
