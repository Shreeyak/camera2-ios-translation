import Foundation
import CoreVideo

/// C-ABI-shaped callback struct per ADR-31 and D-03. The C++ `PixelSink` pool invokes
/// these function pointers; the Swift side registers a struct whose closures forward to
/// an `Unmanaged`-retained Swift object.
///
/// Function pointers are declared `@convention(c)` so they satisfy the C-ABI contract
/// without `@Sendable` gymnastics. Sendable is not an issue here — these are plain C
/// function pointers with known stack discipline.
public struct PixelSinkCallbacks {
    public typealias OnFrame = @convention(c) (
        _ context: UnsafeMutableRawPointer?,
        _ stream: UInt32,
        _ frameNumber: UInt64,
        _ presentationTimeNs: Int64,
        _ surface: UnsafeMutableRawPointer?
    ) -> Void

    public typealias OnOverwrite = @convention(c) (
        _ context: UnsafeMutableRawPointer?,
        _ stream: UInt32
    ) -> Void

    public typealias OnError = @convention(c) (
        _ context: UnsafeMutableRawPointer?,
        _ code: Int32
    ) -> Void

    public let onFrame: OnFrame
    public let onOverwrite: OnOverwrite
    public let onError: OnError
    public let context: UnsafeMutableRawPointer?

    public init(
        onFrame: OnFrame,
        onOverwrite: OnOverwrite,
        onError: OnError,
        context: UnsafeMutableRawPointer?
    ) {
        self.onFrame = onFrame
        self.onOverwrite = onOverwrite
        self.onError = onError
        self.context = context
    }
}

/// Swift facade over the C++ `PixelSink` pool + the Swift-side bridge stream for callers
/// that prefer `AsyncStream<FrameSet>` to a callback struct. D-01 specifies the Swift
/// bridge path; C-ABI is the default integration shape for external C++ consumers
/// (D-03). Both lanes are served by the same underlying consumer registry.
public actor ConsumerRegistry {
    public init() {}

    /// Subscribe a Swift consumer; returns an `AsyncStream` whose buffering policy is
    /// `.bufferingNewest(1)` per ADR-22. Termination of the stream unsubscribes.
    public func subscribe(stream: StreamId) -> AsyncStream<FrameSet> {
        fatalError("Stage 08")
    }

    /// Register a C-ABI consumer (e.g. a C++ CV pipeline) per D-03. The returned token
    /// is held by the caller; releasing it unsubscribes the callback. The callback
    /// receives an IOSurface-backed texture reference; consumers must copy before the
    /// callback returns.
    public func registerCallback(
        stream: StreamId,
        callbacks: PixelSinkCallbacks
    ) throws -> ConsumerToken {
        fatalError("Stage 08")
    }

    public func unregister(token: ConsumerToken) {
        fatalError("Stage 08")
    }

    /// Current delivery statistics per D-11; consume on `@MainActor` for debug UI.
    public func deliveryStats() -> AsyncStream<FrameDeliveryStats> {
        fatalError("Stage 08")
    }
}

public struct ConsumerToken: Sendable, Hashable {
    public let id: UInt64
    public let stream: StreamId
    public init(id: UInt64, stream: StreamId) {
        self.id = id
        self.stream = stream
    }
}
