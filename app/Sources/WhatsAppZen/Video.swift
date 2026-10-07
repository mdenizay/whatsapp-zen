import AVFoundation
import AppKit
import CWACore
import CoreMedia
import SwiftUI
import VideoToolbox

/// Video for calls. The core carries H.264 as complete access units in
/// Annex B form (each NAL unit after a 00 00 00 01 start code); the camera,
/// the encoder, the decoder and the screen are this app's.
enum H264 {
    static let startCode = Data([0, 0, 0, 1])

    /// The NAL units of an Annex B stream, without their start codes.
    static func units(of data: Data) -> [Data] {
        var units: [Data] = []
        var start: Int?
        var zeros = 0
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0 {
                zeros += 1
            } else {
                if byte == 1, zeros >= 2 {
                    // A start code ends the unit before it (minus the zeros that belong to the code).
                    if let from = start {
                        let end = index - min(zeros, 3)
                        if end > from { units.append(data[from..<end]) }
                    }
                    start = index + 1
                }
                zeros = 0
            }
            index += 1
        }
        if let from = start, from < data.endIndex { units.append(data[from..<data.endIndex]) }
        return units
    }

    /// An encoder's output (length-prefixed units) as one Annex B access unit,
    /// with the parameter sets in front of every keyframe so that decoding can
    /// start there.
    static func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var out = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr, let pointer else { continue }
                out.append(startCode)
                out.append(pointer, count: size)
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
        var offset = 0
        while offset + 4 <= length {
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard size > 0, offset + size <= length else { break }
            out.append(startCode)
            out.append(contentsOf: bytes[offset..<offset + size])
            offset += size
        }
        return out
    }
}

/// The camera, encoded for a call. Frames go to the core as they come out
/// of the encoder; the same capture session feeds the local preview.
final class CameraEncoder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraEncoder()

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "call.camera")
    private var encoder: VTCompressionSession?
    private var lastFrame = CMTime.zero
    private var configured = false
    /// Where encoded frames go; the core, unless a test listens instead.
    var onFrame: (Data) -> Void = { data in
        data.withUnsafeBytes { WAVideoSend($0.bindMemory(to: UInt8.self).baseAddress, data.count) }
    }

    func start() {
        queue.async { [self] in
            if !configured {
                guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera),
                      session.canAddInput(input) else { return }
                session.beginConfiguration()
                // WhatsApp's own range: small enough for any connection.
                session.sessionPreset = .vga640x480
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            if let encoder {
                VTCompressionSessionInvalidate(encoder)
                self.encoder = nil
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // 15 frames a second, the pace the call's video clock is set to.
        guard CMTimeGetSeconds(CMTimeSubtract(time, lastFrame)) >= 1.0 / 15.5 else { return }
        lastFrame = time
        encode(image, at: time)
    }

    /// Encodes one picture. Also used directly by tests, without a camera.
    func encode(_ image: CVImageBuffer, at time: CMTime) {
        if encoder == nil {
            var created: VTCompressionSession?
            guard VTCompressionSessionCreate(allocator: nil, width: Int32(CVPixelBufferGetWidth(image)), height: Int32(CVPixelBufferGetHeight(image)),
                                             codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
                                             compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                             compressionSessionOut: &created) == noErr, let created else { return }
            // What WhatsApp expects: Constrained Baseline, no reordering, a
            // keyframe every two seconds so a lost one is soon made up for.
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: 600_000 as CFNumber)
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 15 as CFNumber)
            VTCompressionSessionPrepareToEncodeFrames(created)
            encoder = created
        }
        guard let encoder else { return }
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let data = H264.annexB(from: sample) else { return }
            self?.onFrame(data)
        }
    }
}

/// The other side's video: access units in, pictures on a layer.
final class RemoteVideo {
    static let shared = RemoteVideo()

    let layer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }()

    private let queue = DispatchQueue(label: "call.screen")
    private var format: CMVideoFormatDescription?
    private var parameters: (sps: Data, pps: Data)?
    /// Frames shown since the call began; for tests and for knowing video is flowing.
    private(set) var shown = 0

    /// Starts handing the core's frames to this screen.
    func attach() {
        WAVideoSetSink { pointer, length, _ in
            guard let pointer else { return }
            RemoteVideo.shared.show(Data(bytes: pointer, count: length))
        }
    }

    func reset() {
        queue.async { [self] in
            format = nil
            parameters = nil
            shown = 0
            layer.flushAndRemoveImage()
        }
    }

    func show(_ accessUnit: Data) {
        queue.async { [self] in
            guard let sample = sampleBuffer(for: accessUnit) else { return }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
            shown += 1
        }
    }

    /// Turns one Annex B access unit into a sample the system can decode:
    /// parameter sets become the format, picture data gets length prefixes.
    func sampleBuffer(for accessUnit: Data) -> CMSampleBuffer? {
        var sps = parameters?.sps, pps = parameters?.pps
        var picture = Data()
        for unit in H264.units(of: accessUnit) {
            guard let header = unit.first else { continue }
            switch header & 0x1F {
            case 7: sps = Data(unit)
            case 8: pps = Data(unit)
            case 1, 5:
                var size = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &size) { picture.append(contentsOf: $0) }
                picture.append(unit)
            default: break
            }
        }
        if let sps, let pps, parameters?.sps != sps || parameters?.pps != pps || format == nil {
            parameters = (sps, pps)
            format = sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    var made: CMVideoFormatDescription?
                    let sets = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: sets,
                                                                        parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                                                                        formatDescriptionOut: &made)
                    return made
                }
            }
        }
        guard let format, !picture.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: picture.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: picture.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = picture.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: picture.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = picture.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // A call shows each picture as it arrives; there is no timeline to wait on.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// A view that shows a Core Animation layer (the remote video, or the
/// camera preview) at its own size.
struct LayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        layer.frame = view.bounds
    }
}
