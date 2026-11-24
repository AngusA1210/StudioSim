// Makes a demo video's MP4 from what tools/video/record.gd saved: its frames (JPEGs, in order) and its sound (a WAV),
// as H.264 and AAC, with what a browser needs to start playing it before it has all arrived. With macOS's own
// AVFoundation, so that nothing need be installed. tools/video/record.sh runs it:
//   swift tools/video/encode.swift <frames folder> <fps> <sound.wav> <out.mp4> <video bits a second, or "auto">
// "auto": as much as keeps the file under 20 MB (the website's host takes files of up to 25), and at most 6 Mbit/s.
import AVFoundation
import Foundation
import ImageIO

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(("ENCODE FAILED: " + why + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 6, let fps = Int32(args[2]), args[5] == "auto" || Int(args[5]) != nil else {
    fail("usage: encode.swift <frames folder> <fps> <sound.wav> <out.mp4> <video bits a second, or auto>")
}
let framesDir = URL(fileURLWithPath: args[1])
let soundURL = URL(fileURLWithPath: args[3])
let outURL = URL(fileURLWithPath: args[4])

let names = ((try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
func image(_ name: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(framesDir.appendingPathComponent(name) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
guard let first = names.first, let firstImage = image(first) else { fail("no frames in " + framesDir.path) }
let width = firstImage.width, height = firstImage.height
let seconds = Double(names.count) / Double(fps)
let bitrate = Int(args[5]) ?? min(6_000_000, Int(20_000_000.0 * 8.0 * 0.97 / seconds) - 192_000)

try? FileManager.default.removeItem(at: outURL)
guard let writer = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else { fail("can't write " + outURL.path) }
writer.shouldOptimizeForNetworkUse = true  // (its index at the front, for a browser)

let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
        AVVideoExpectedSourceFrameRateKey: Int(fps),
    ],
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
])
video.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(video)

// The sound, read as 16-bit samples and made AAC by the writer (which marks its encoder's delay, so it stays in step).
let soundAsset = AVURLAsset(url: soundURL)
nonisolated(unsafe) var found: AVAssetTrack?
let looked = DispatchSemaphore(value: 0)
Task {
    found = try? await soundAsset.loadTracks(withMediaType: .audio).first
    looked.signal()
}
looked.wait()
guard let soundTrack = found, let reader = try? AVAssetReader(asset: soundAsset) else {
    fail("can't read " + soundURL.path)
}
let samples = AVAssetReaderTrackOutput(track: soundTrack, outputSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
])
reader.add(samples)
let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: 48000,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitRateKey: 192_000,
])
audio.expectsMediaDataInRealTime = false
writer.add(audio)

guard writer.startWriting(), reader.startReading() else { fail(writer.error?.localizedDescription ?? "can't start") }
writer.startSession(atSourceTime: .zero)

let group = DispatchGroup()
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var index = 0
group.enter()
video.requestMediaDataWhenReady(on: DispatchQueue(label: "video")) {
    while video.isReadyForMoreMediaData {
        if index >= names.count {
            video.markAsFinished()
            group.leave()
            return
        }
        autoreleasepool {
            guard let picture = image(names[index]), let pool = adaptor.pixelBufferPool else { fail("can't read frame " + names[index]) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixels = buffer else { fail("out of memory") }
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: space,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            if !adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) {
                fail(writer.error?.localizedDescription ?? "can't add frame " + names[index])
            }
        }
        index += 1
    }
}
group.enter()
audio.requestMediaDataWhenReady(on: DispatchQueue(label: "audio")) {
    while audio.isReadyForMoreMediaData {
        guard let buffer = samples.copyNextSampleBuffer() else {
            audio.markAsFinished()
            group.leave()
            return
        }
        audio.append(buffer)
    }
}
group.wait()
writer.endSession(atSourceTime: CMTime(value: Int64(names.count), timescale: fps))
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
guard writer.status == .completed else { fail(writer.error?.localizedDescription ?? "didn't finish") }
let bytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? Int) ?? 0
print(String(format: "ENCODED %@: %d frames, %.1f s, %.1f MB (video at %.1f Mbit/s)", outURL.lastPathComponent, names.count, seconds,
             Double(bytes) / 1_000_000, Double(bitrate) / 1_000_000))
