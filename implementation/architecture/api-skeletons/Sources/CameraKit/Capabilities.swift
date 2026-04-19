import Foundation
import CoreGraphics

/// `domain-revised/10-api-contract.md §SessionCapabilities`.
public struct SessionCapabilities: Sendable, Hashable {
    public let supportedSizes: [Size]
    public let previewTextureId: Int
    public let naturalTextureId: Int
    public let activeCaptureResolution: Size
    public let activeCropRegion: Rect
    public let streamPixelFormat: String

    public init(
        supportedSizes: [Size],
        previewTextureId: Int,
        naturalTextureId: Int,
        activeCaptureResolution: Size,
        activeCropRegion: Rect,
        streamPixelFormat: String
    ) {
        self.supportedSizes = supportedSizes
        self.previewTextureId = previewTextureId
        self.naturalTextureId = naturalTextureId
        self.activeCaptureResolution = activeCaptureResolution
        self.activeCropRegion = activeCropRegion
        self.streamPixelFormat = streamPixelFormat
    }
}

public struct Size: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Startup arguments for `CameraEngine.open(...)`.
public struct OpenConfiguration: Sendable, Hashable {
    public var cameraId: String?
    public var captureResolution: Size?
    public var cropRegion: Rect?

    public init(
        cameraId: String? = nil,
        captureResolution: Size? = nil,
        cropRegion: Rect? = nil
    ) {
        self.cameraId = cameraId
        self.captureResolution = captureResolution
        self.cropRegion = cropRegion
    }
}
