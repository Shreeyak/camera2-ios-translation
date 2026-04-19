import Foundation

/// Still-image capture facade per D-05: direct Metal-blit readback to a CPU-readable
/// `CVPixelBuffer`, encoded as 8-bit TIFF via `CGImageDestination`. EXIF non-standard
/// fields are serialized as JSON under the `"CamPlugin/v1"` key in
/// `kCGImagePropertyExifUserComment` (D-09). Concurrency guard (domain Invariant 7) is
/// an atomic compare-and-swap in the C++ pipeline; the Swift facade simply observes the
/// result.
public struct StillCaptureOutput: Sendable, Hashable {
    public let filePath: String
    public let widthPx: Int
    public let heightPx: Int
    public init(filePath: String, widthPx: Int, heightPx: Int) {
        self.filePath = filePath
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

public enum StillCaptureError: Error, Sendable {
    case alreadyInFlight
    case notStreaming
    case destinationCreateFailed
    case encodingFailed
    case ioFailed(underlyingMessage: String)
}
