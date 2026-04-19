import Foundation

/// Partial-update settings object per `domain-revised/10-api-contract.md §CameraSettings`.
/// Every field is optional; null = "do not change." Merge rules + ISO/exposure coupling
/// live in `07-settings.md`.
public struct CameraSettings: Sendable, Hashable {
    public var isoMode: CameraMode?
    public var iso: Int?
    public var exposureMode: CameraMode?
    public var exposureTimeNs: Int64?
    public var focusMode: CameraMode?
    public var focusDistance: Double?
    public var wbMode: WhiteBalanceMode?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?
    public var zoomRatio: Double?
    public var evCompensation: Int?

    public init(
        isoMode: CameraMode? = nil,
        iso: Int? = nil,
        exposureMode: CameraMode? = nil,
        exposureTimeNs: Int64? = nil,
        focusMode: CameraMode? = nil,
        focusDistance: Double? = nil,
        wbMode: WhiteBalanceMode? = nil,
        wbGainR: Double? = nil,
        wbGainG: Double? = nil,
        wbGainB: Double? = nil,
        zoomRatio: Double? = nil,
        evCompensation: Int? = nil
    ) {
        self.isoMode = isoMode
        self.iso = iso
        self.exposureMode = exposureMode
        self.exposureTimeNs = exposureTimeNs
        self.focusMode = focusMode
        self.focusDistance = focusDistance
        self.wbMode = wbMode
        self.wbGainR = wbGainR
        self.wbGainG = wbGainG
        self.wbGainB = wbGainB
        self.zoomRatio = zoomRatio
        self.evCompensation = evCompensation
    }
}

public enum CameraMode: String, Sendable, Hashable {
    case auto
    case manual
}

public enum WhiteBalanceMode: String, Sendable, Hashable {
    case auto
    case locked
    case manual
}

/// GPU color-processing shader parameters per `domain-revised/10-api-contract.md`
/// §ProcessingParameters. All fields required.
public struct ProcessingParameters: Sendable, Hashable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var blackR: Double
    public var blackG: Double
    public var blackB: Double
    public var gamma: Double

    public init(
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 0.0,
        blackR: Double = 0.0,
        blackG: Double = 0.0,
        blackB: Double = 0.0,
        gamma: Double = 1.0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.blackR = blackR
        self.blackG = blackG
        self.blackB = blackB
        self.gamma = gamma
    }

    public static let identity = ProcessingParameters()
}

/// Sensor metadata delivered at `constants.md#FRAME_RESULT_HEARTBEAT_HZ`.
public struct FrameResult: Sendable, Hashable {
    public var iso: Int?
    public var exposureTimeNs: Int64?
    public var focusDistance: Double?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?

    public init(
        iso: Int? = nil,
        exposureTimeNs: Int64? = nil,
        focusDistance: Double? = nil,
        wbGainR: Double? = nil,
        wbGainG: Double? = nil,
        wbGainB: Double? = nil
    ) {
        self.iso = iso
        self.exposureTimeNs = exposureTimeNs
        self.focusDistance = focusDistance
        self.wbGainR = wbGainR
        self.wbGainG = wbGainG
        self.wbGainB = wbGainB
    }
}

/// Result of a `sampleCenterPatch()` call; each channel in [0.0, 1.0].
public struct RgbSample: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}
