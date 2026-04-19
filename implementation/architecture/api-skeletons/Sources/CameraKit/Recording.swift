import Foundation

/// Video recording facade. HEVC 8-bit in MP4 per D-04; GPU-to-encoder zero-copy via the
/// compute pass described in `04-metal-pipeline.md` §Encoder compute pass (ADR-06).
/// The finish path runs with `constants.md#RECORDING_FINISH_TIMEOUT_SECONDS` deadline;
/// on expiry the writer is cancelled (not finished) per ADR-16 to avoid a corrupt MP4.
public struct RecordingOptions: Sendable, Hashable {
    public var outputDirectory: String?
    public var fileName: String?
    public var bitrateBps: Int?
    public var fps: Int?

    public init(
        outputDirectory: String? = nil,
        fileName: String? = nil,
        bitrateBps: Int? = nil,
        fps: Int? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.fileName = fileName
        self.bitrateBps = bitrateBps
        self.fps = fps
    }
}

public struct RecordingStart: Sendable, Hashable {
    public let uri: String
    public let displayName: String
    public init(uri: String, displayName: String) {
        self.uri = uri
        self.displayName = displayName
    }
}
