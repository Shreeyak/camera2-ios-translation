import Foundation
import CoreVideo
import CoreMedia

/// Atomic unit of publication per ADR-18. One `FrameSet` carries all three consumer-visible
/// streams plus capture + processing metadata.
///
/// `@unchecked Sendable`: `CVPixelBuffer` is not yet `Sendable` on iOS 26 (G-13). The
/// contract is enforced by the pool machinery: each buffer is IOSurface-backed (ADR-18),
/// the GPU writes complete before `FrameSet` is constructed inside the completion handler
/// (ADR-10), and consumers hold buffer refs only for the duration of their `for await`
/// iteration. No consumer mutates buffer pixels — they are read-only surfaces.
public struct FrameSet: @unchecked Sendable, Hashable {
    public let frameNumber: UInt64
    public let captureTime: CMTime
    public let natural: CVPixelBuffer
    public let processed: CVPixelBuffer
    public let tracker: CVPixelBuffer
    public let capture: CaptureMetadata
    public let processing: ProcessingMetadata
    public let blurScore: Float
    public let trackerQuality: TrackerQuality

    public init(
        frameNumber: UInt64,
        captureTime: CMTime,
        natural: CVPixelBuffer,
        processed: CVPixelBuffer,
        tracker: CVPixelBuffer,
        capture: CaptureMetadata,
        processing: ProcessingMetadata,
        blurScore: Float,
        trackerQuality: TrackerQuality
    ) {
        self.frameNumber = frameNumber
        self.captureTime = captureTime
        self.natural = natural
        self.processed = processed
        self.tracker = tracker
        self.capture = capture
        self.processing = processing
        self.blurScore = blurScore
        self.trackerQuality = trackerQuality
    }

    public static func == (lhs: FrameSet, rhs: FrameSet) -> Bool {
        lhs.frameNumber == rhs.frameNumber && lhs.captureTime == rhs.captureTime
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(frameNumber)
        hasher.combine(captureTime.value)
    }
}

public enum TrackerQuality: String, Sendable, Hashable {
    case good
    case degraded
    case invalid
}

public struct CaptureMetadata: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let whiteBalanceGains: WhiteBalanceGains
    public let whiteBalanceModeActive: WhiteBalanceMode
    public let lensPosition: Float
    public let focusModeActive: CameraMode
    public let exposureModeActive: CameraMode
    public let zoomFactor: Double
    public let cameraPosition: CameraPosition

    public init(
        iso: Float,
        exposureDurationNs: Int64,
        whiteBalanceGains: WhiteBalanceGains,
        whiteBalanceModeActive: WhiteBalanceMode,
        lensPosition: Float,
        focusModeActive: CameraMode,
        exposureModeActive: CameraMode,
        zoomFactor: Double,
        cameraPosition: CameraPosition
    ) {
        self.iso = iso
        self.exposureDurationNs = exposureDurationNs
        self.whiteBalanceGains = whiteBalanceGains
        self.whiteBalanceModeActive = whiteBalanceModeActive
        self.lensPosition = lensPosition
        self.focusModeActive = focusModeActive
        self.exposureModeActive = exposureModeActive
        self.zoomFactor = zoomFactor
        self.cameraPosition = cameraPosition
    }
}

public struct ProcessingMetadata: Sendable, Hashable {
    public let cropRegion: Rect
    public let brightness: Float
    public let contrast: Float
    public let saturation: Float
    public let gamma: Float
    public let whiteBalanceGains: WhiteBalanceGains

    public init(
        cropRegion: Rect,
        brightness: Float,
        contrast: Float,
        saturation: Float,
        gamma: Float,
        whiteBalanceGains: WhiteBalanceGains
    ) {
        self.cropRegion = cropRegion
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.whiteBalanceGains = whiteBalanceGains
    }
}

public struct WhiteBalanceGains: Sendable, Hashable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum CameraPosition: String, Sendable, Hashable {
    case back
    case front
    case wide
}

/// Per-lane + global counters surfaced by the consumer registry per ADR-19 and D-11.
public struct FrameDeliveryStats: Sendable, Hashable {
    public let producedByLane: [StreamId: UInt64]
    public let deliveredByLane: [StreamId: UInt64]
    public let droppedByLane: [StreamId: UInt64]
    public let holdOverBudgetByLane: [StreamId: UInt64]
    public let poolExhaustion: UInt64
    public let cppOverwriteByLane: [StreamId: UInt64]

    public init(
        producedByLane: [StreamId: UInt64],
        deliveredByLane: [StreamId: UInt64],
        droppedByLane: [StreamId: UInt64],
        holdOverBudgetByLane: [StreamId: UInt64],
        poolExhaustion: UInt64,
        cppOverwriteByLane: [StreamId: UInt64]
    ) {
        self.producedByLane = producedByLane
        self.deliveredByLane = deliveredByLane
        self.droppedByLane = droppedByLane
        self.holdOverBudgetByLane = holdOverBudgetByLane
        self.poolExhaustion = poolExhaustion
        self.cppOverwriteByLane = cppOverwriteByLane
    }
}
