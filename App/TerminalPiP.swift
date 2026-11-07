#if canImport(UIKit)
import AVFoundation
import AVKit
import UIKit

/// Picture in Picture for the agent in front: backgrounding the app with an agent's
/// terminal open floats a live copy of it. PiP only plays video, so the terminal is drawn
/// into frames for a sample-buffer layer that sits under it, twice a second while PiP is
/// up. iOS starts PiP on its own when the app leaves with that layer in a window, and the
/// app keeps running meanwhile, so the pane's stream keeps feeding the copy.
@MainActor
final class TerminalPiP: NSObject, ObservableObject {
    static let shared = TerminalPiP()

    /// PiP is up: the open pane keeps its stream and its width claim while it is.
    @Published private(set) var isActive = false

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    /// The terminal's container, which holds `displayLayer`, and the terminal drawn from it.
    private weak var host: UIView?
    private weak var content: UIView?
    private var timer: Timer?

    private override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        NotificationCenter.default.addObserver(
            self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    private static var supported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported() && !ProcessInfo.processInfo.isiOSAppOnMac
    }

    /// The pane in front: its terminal is what PiP shows if the app is backgrounded now.
    func attach(host: UIView, content: UIView) {
        guard Self.supported, self.host !== host else { return }
        self.host = host
        self.content = content
        host.layer.insertSublayer(displayLayer, at: 0)
        if controller == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = true
            controller.delegate = self
            self.controller = controller
        }
        activateAudioSession()
        renderFrame()
    }

    /// The pane left the front or went away: nothing to show any more.
    func detach(host: UIView) {
        guard self.host === host else { return }
        if isActive { controller?.stopPictureInPicture() }
        self.host = nil
        content = nil
        displayLayer.removeFromSuperlayer()
    }

    /// PiP needs a playback session to start; mixing leaves the owner's music alone.
    /// Re-asserted on the way out, since dictation sets its own category and ends it.
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try? session.setActive(true)
    }

    @objc private func willResignActive() {
        guard host != nil else { return }
        activateAudioSession()
        // The frame PiP opens on: the screen as the owner left it.
        renderFrame()
    }

    /// The bottom of the terminal, at most as tall as it is wide: the agent's prompt and its
    /// latest output, at a size the small window can show.
    private func renderFrame() {
        guard let host, let content, content.bounds.width > 1, content.bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = host.bounds
        CATransaction.commit()

        let size = content.bounds.size
        let crop = CGSize(width: size.width, height: min(size.height, size.width))
        let scale: CGFloat = 2
        let width = Int(crop.width * scale), height = Int(crop.height * scale)
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
                == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        if let context {
            // UIKit's top-left origin, shifted so the crop's top is the context's top.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: 0, y: -(size.height - crop.height))
            // Draw what the stream wrote since the last pass, even with no screen to show it on.
            content.layer.displayIfNeeded()
            content.layer.render(in: context)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard context != nil else { return }

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    private func started() {
        isActive = true
        timer?.invalidate()
        // ponytail: two frames a second, redrawn whole; draw only on stream output if it costs battery.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { TerminalPiP.shared.renderFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopped() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }
}

extension TerminalPiP: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { started() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { stopped() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { stopped() }
    }

    /// Tapping the window back into the app: the pane is still there underneath.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

/// A live stream with no timeline: always playing, nothing to seek.
extension TerminalPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
#endif
