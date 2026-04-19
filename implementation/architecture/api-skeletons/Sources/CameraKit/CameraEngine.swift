import Foundation

/// The single heavy isolation domain per ADR-02. Owns every stateful resource —
/// `AVCaptureSession` (driven through the dedicated `sessionQueue` per ADR-07, never
/// directly), `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`, pool manager,
/// consumer registry, recording coordinator, still-capture state. Session state
/// transitions emit on `stateStream`; errors on `errorStream`; periodic sensor
/// metadata on `frameResultStream`; recording-state transitions on
/// `recordingStateStream`. All four streams are `.bufferingOldest(64)` state-change
/// streams per ADR-22.
///
/// Completion-handler re-entrancy guard (D-10) is applied on every GPU command
/// buffer — the handler captures `sessionState` at commit and no-ops if it diverges.
public actor CameraEngine {
    public init(
        device: any CaptureDeviceProviding,
        consumers: ConsumerRegistry
    ) {
        fatalError("Stage 01")
    }

    /// Open the capture pipeline. Resolves with the capabilities the UI needs to bind
    /// preview textures. Idempotency: calling while already open throws
    /// `EngineError.alreadyOpen` — callers must `close()` first.
    public func open(
        configuration: OpenConfiguration
    ) async throws -> SessionCapabilities {
        fatalError("Stage 01")
    }

    /// Orderly teardown; stops recording first if active, then releases all resources
    /// per `05-resource-lifecycle.md` §Full teardown order.
    public func close() async {
        fatalError("Stage 01")
    }

    /// Session-only teardown: capture session + GPU pipeline torn down, camera device
    /// retained. Used by the host on user-initiated pause.
    public func pause() async {
        fatalError("Stage 05")
    }

    /// Restart the capture session after `pause()`.
    public func resume() async throws {
        fatalError("Stage 05")
    }

    /// Observe-only: host informs the engine it is backgrounded. No resource teardown;
    /// the system interruption signal drives `AVCaptureSession` dormancy. Pending
    /// recovery retries are cancelled.
    public func backgroundSuspend() async {
        fatalError("Stage 09")
    }

    /// Host signals return to foreground. The engine awaits the platform's
    /// `interruptionEnded` signal; calling this before that signal arrives is harmless.
    public func backgroundResume() async {
        fatalError("Stage 09")
    }

    /// Merges non-nil fields onto persisted settings and applies. Rejects internally
    /// inconsistent combinations with `EngineError.settingsConflict`.
    public func updateSettings(_ settings: CameraSettings) async throws {
        fatalError("Stage 03")
    }

    /// Updates all GPU shader uniforms immediately; takes effect on next rendered
    /// frame. No coupling to hardware settings.
    public func setProcessingParameters(_ params: ProcessingParameters) async {
        fatalError("Stage 04")
    }

    /// Returns the most recently persisted processing parameters, or nil if never
    /// saved. Usable without an active session.
    public nonisolated func getPersistedProcessingParameters() async -> ProcessingParameters? {
        fatalError("Stage 07")
    }

    /// Samples a `constants.md#CENTER_PATCH_SIZE_PX` patch from `processedTex`
    /// center. Computes R, G, B trimmed means per `constants.md#CENTER_PATCH_TRIM_PERCENT`.
    public func sampleCenterPatch() async throws -> RgbSample {
        fatalError("Stage 04")
    }

    /// Encodes the most recent processed frame as 8-bit TIFF (D-05); concurrency guard
    /// (domain Invariant 7) rejects a second call while a first is in flight.
    public func captureImage(outputPath: String?) async throws -> StillCaptureOutput {
        fatalError("Stage 06")
    }

    public func startRecording(options: RecordingOptions) async throws -> RecordingStart {
        fatalError("Stage 06")
    }

    public func stopRecording() async throws -> String {
        fatalError("Stage 06")
    }

    public func setResolution(size: Size) async throws {
        fatalError("Stage 03")
    }

    public func setCropRegion(_ rect: Rect) async throws {
        fatalError("Stage 04")
    }

    public func getNativePipelineHandle() async -> UInt64? {
        fatalError("Stage 08")
    }

    // MARK: - Event streams (state-change, `.bufferingOldest(64)` per ADR-22)

    public func stateStream() -> AsyncStream<SessionState> {
        fatalError("Stage 01")
    }

    public func errorStream() -> AsyncStream<CameraError> {
        fatalError("Stage 09")
    }

    public func frameResultStream() -> AsyncStream<FrameResult> {
        fatalError("Stage 04")
    }

    public func recordingStateStream() -> AsyncStream<RecordingState> {
        fatalError("Stage 06")
    }
}
