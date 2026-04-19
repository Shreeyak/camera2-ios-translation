# Constants

All load-bearing numeric values for the iOS architecture. Concern files cite `constants.md#<name>`
rather than inlining a value. Every cell in every row is populated (M7).

Values marked `Cite: measurements/` are platform measurements; see
`domain-revised/02-frame-delivery.md` §Memory and `domain-revised/07-performance-budgets.md` for the
formulas. Acquiring concrete numbers is a Phase-1a empirical task; the name is load-bearing, the
reference value is a working assumption.

| Name | Value | Cite | Owning concern | Rationale |
|---|---|---|---|---|
| FRAME_RATE_TARGET_FPS | 30 | domain 02-frame-delivery §Frame Rate Target | 03-camera-session | Capture repeating-request frame-rate lock in preview mode. |
| FRAME_RATE_RECORDING_MIN_FPS | 15 | domain 02-frame-delivery §Frame Rate Target | 03-camera-session | Recording mode allows AE to halve frame rate in low-light; lower bound of `(fps, fps/2)` range. |
| FRAME_LATENCY_BUDGET_MS | 33 | guide 03-metal §Profiling strategy | 04-metal-pipeline | Per-frame wall-clock budget at 30fps; capture callback → commit must fit inside. |
| FRAME_LATENCY_DEGRADED_MS | 15 | guide 03-metal §Profiling strategy | 04-metal-pipeline | Acceptable latency upper bound; above this is "degraded" for diagnostics. |
| FRAME_LATENCY_FAILING_MS | 25 | guide 03-metal §Profiling strategy | 04-metal-pipeline | Fail-fast latency threshold; above this, back-pressure starts dropping frames. |
| WORKING_PIXEL_FORMAT | rgba16Float | guide 03-metal ADR-05 | 04-metal-pipeline | Working texture format through the color-transform chain; half-float avoids 8-bit banding. |
| CAPTURE_PIXEL_FORMAT | 420YpCbCr8BiPlanarFullRange (lossless preferred) | guide 03-metal ADR-05 | 03-camera-session | 8-bit biplanar YUV from AVCaptureVideoDataOutput; half-float and 10-bit are not supported on `AVCaptureVideoDataOutput` (G-17). |
| ENCODER_PIXEL_FORMAT | 420YpCbCr8BiPlanarVideoRange (NV12) | guide 03-metal ADR-06 | 06-capture-and-recording | Native VideoToolbox encoder input; compute pass converts RGBA16F → NV12. |
| CAPTURE_DEFAULT_WIDTH_PX | 4160 | domain 01-system-purpose §Success Criteria, 02-frame-delivery §Capture Format | 03-camera-session | Default capture resolution width on A16 test hardware; largest 4:3 format. |
| CAPTURE_DEFAULT_HEIGHT_PX | 3120 | domain 01-system-purpose §Success Criteria, 02-frame-delivery §Capture Format | 03-camera-session | Default capture resolution height paired with 4160 width. |
| CAPTURE_FALLBACK_WIDTH_PX | 1280 | domain 03-camera-control §Resolution Selection | 03-camera-session | 4:3 fallback width when device reports no 4:3 format. |
| CAPTURE_FALLBACK_HEIGHT_PX | 960 | domain 03-camera-control §Resolution Selection | 03-camera-session | 4:3 fallback height paired with 1280 width. |
| CROP_DEFAULT_WIDTH_PX | 1600 | domain 02-frame-delivery §Capture Format and Crop | 04-metal-pipeline | Default center-crop width; drives natural/processed/encoder stream resolution. |
| CROP_DEFAULT_HEIGHT_PX | 1200 | domain 02-frame-delivery §Capture Format and Crop | 04-metal-pipeline | Default center-crop height paired with 1600 width (4:3). |
| TRACKER_HEIGHT_PX | 480 | domain 02-frame-delivery §Parallel Stream Outputs, U-15 resolved | 04-metal-pipeline | Fixed downsample height for tracker stream; width aspect-preserved, even-pixel-rounded. |
| BPP_RGBA16F | 8 | domain 02-frame-delivery §Memory | 04-metal-pipeline | Bytes per pixel for the working format (4 channels × 2 bytes). |
| READBACK_DOUBLE_BUFFER_DEPTH | 2 | domain 02-frame-delivery §GPU Processing Pipeline | 04-metal-pipeline | Alternate-buffer readback depth: one written while the other is mapped. |
| POOL_MIN_BUFFER_COUNT | 3 | guide 05-interop ADR-19 | 05-consumers | CVPixelBufferPool minimum: 1 current mailbox ref + 1 GPU write slot + 1 slack. |
| POOL_MAX_BUFFER_AGE_SECONDS | 1.0 | guide 05-interop ADR-19 | 05-consumers | CF-managed age-out for unused pool buffers after one second of disuse. |
| POOL_CAP_RULE | N_active_lanes + 1 | guide 05-interop ADR-19 | 05-consumers | Steady-state upper bound for each pool's outstanding buffers; +1 is the always-empty GPU write slot. |
| MAILBOX_DEPTH_SLOTS | 1 | guide 05-interop ADR-13 | 05-consumers | 1-slot newest-wins mailbox per lane; drop-on-busy semantics. |
| STATE_STREAM_BUFFER_SIZE | 64 | guide 02-concurrency ADR-22 | 02-concurrency | `.bufferingOldest(64)` for state-change `AsyncStream`s; every transition must be delivered. |
| CENTER_PATCH_SIZE_PX | 96 | domain 02-frame-delivery §Center-Patch Sampling | 04-metal-pipeline | Square region at center of processedTex read by `sampleCenterPatch()`. |
| CENTER_PATCH_TRIM_PERCENT | 10 | domain 02-frame-delivery §Center-Patch Sampling | 04-metal-pipeline | Discard top/bottom 10% of intensity values for the trimmed mean. |
| STALL_GPU_THRESHOLD_MS | 3000 | domain 06-error-and-recovery §Frame Stall Detection | 09-errors-and-recovery | GPU-level watchdog fires after 3s without a frame arrival; notify-only. |
| STALL_CAPTURE_THRESHOLD_MS | 5000 | domain 06-error-and-recovery §Frame Stall Detection | 09-errors-and-recovery | Capture-result watchdog fires after 5s without a capture-result; triggers recovery. |
| AE_CONVERGENCE_TIMEOUT_MS | 5000 | domain 06-error-and-recovery §AE Convergence Notification | 09-errors-and-recovery | Emit `AE_CONVERGENCE_TIMEOUT` if AE remains searching past this window. |
| FPS_DEGRADED_THRESHOLD_FPS | 15.0 | domain 06-error-and-recovery §FPS Degradation Notification | 09-errors-and-recovery | Frame-rate floor for the degradation notification. |
| FPS_DEGRADED_STREAK_COUNT | 3 | domain 06-error-and-recovery §FPS Degradation Notification | 09-errors-and-recovery | Consecutive below-threshold measurements required before notifying. |
| FPS_MEASUREMENT_WINDOW_FRAMES | 30 | domain 06-error-and-recovery §FPS Degradation Notification | 09-errors-and-recovery | Measurement cadence: one FPS measurement per window. |
| FRAME_RESULT_HEARTBEAT_HZ | 3 | domain 02-frame-delivery §Frame Result Heartbeat | 07-settings | Approximate delivery rate for `onFrameResult`; every 10th frame at 30fps. |
| FRAME_RESULT_HEARTBEAT_INTERVAL_FRAMES | 10 | domain 02-frame-delivery §Frame Result Heartbeat | 07-settings | Frame-counted emission cadence implementing the 3Hz target. |
| HW_ERROR_THRESHOLD_CONSECUTIVE | 5 | domain 06-error-and-recovery §Hardware Error Threshold | 09-errors-and-recovery | Non-fatal recovery triggers only after this many consecutive HW failures. |
| RECOVERY_MAX_RETRIES | 5 | domain 06-error-and-recovery §Exponential Backoff | 09-errors-and-recovery | After this many failed retries, transition to fatal `MAX_RETRIES_EXCEEDED`. |
| RECOVERY_BACKOFF_1_MS | 500 | domain 06-error-and-recovery §Exponential Backoff | 09-errors-and-recovery | Retry delay after attempt 1. |
| RECOVERY_BACKOFF_2_MS | 1000 | domain 06-error-and-recovery §Exponential Backoff | 09-errors-and-recovery | Retry delay after attempt 2. |
| RECOVERY_BACKOFF_3_MS | 2000 | domain 06-error-and-recovery §Exponential Backoff | 09-errors-and-recovery | Retry delay after attempt 3. |
| RECOVERY_BACKOFF_4_MS | 4000 | domain 06-error-and-recovery §Exponential Backoff | 09-errors-and-recovery | Retry delay after attempt 4. |
| RECOVERY_BACKOFF_5_PLUS_MS | 8000 | domain 06-error-and-recovery §Exponential Backoff | 09-errors-and-recovery | Retry delay after attempt 5 and later (clamped). |
| DRAIN_TIMEOUT_SECONDS | 5 | domain 08-capture-and-recording §Stop Recording Flow | 06-capture-and-recording | Recording EOS drain budget; on timeout emit `RECORDING_TRUNCATED` and return URI. |
| RECORDING_FINISH_TIMEOUT_SECONDS | 5 | guide 03-metal ADR-16 | 06-capture-and-recording | Deadline for `AVAssetWriter.finishWriting`; past this, cancel to avoid corrupt MP4. |
| RESOLUTION_RESIZE_TIMEOUT_SECONDS | 5 | domain 05-resource-lifecycle §GPU Pipeline Resource Initialization | 03-camera-session | Session-only teardown + GPU resize budget; on timeout, revert to previous resolution. |
| SESSION_LIFECYCLE_TIMEOUT_SECONDS | 2 | guide 04-avfoundation ADR-30 | 03-camera-session | Deadline for `startRunning()` / `stopRunning()` awaited from `@MainActor` via continuation. |
| PREVIEW_SURFACE_FAILURE_THRESHOLD | 3 | domain 05-resource-lifecycle §Preview Surface Rebind | 08-ui | Consecutive swap failures before triggering a preview-surface rebind. |
| CAPTURE_ORIENTATION_ANGLE_DEG | 90 | guide 04-avfoundation ADR-17 | 03-camera-session | Landscape-right rotation angle applied to `AVCaptureConnection.videoRotationAngle`. |
| COLOR_LUMA_WEIGHT_R | 0.2126 | guide 03-metal §Channel-order discipline | 04-metal-pipeline | Rec.709 luma coefficient for red in RGBA channel order. |
| COLOR_LUMA_WEIGHT_G | 0.7152 | guide 03-metal §Channel-order discipline | 04-metal-pipeline | Rec.709 luma coefficient for green. |
| COLOR_LUMA_WEIGHT_B | 0.0722 | guide 03-metal §Channel-order discipline | 04-metal-pipeline | Rec.709 luma coefficient for blue. |
| CPP_POOL_THREAD_COUNT | min(4, hardware_concurrency) | guide 05-interop ADR-13 | 05-consumers | PixelSink thread-pool cap in the C++ imaging core (Mechanism A). |
| TARGET_BITRATE_MBPS | measurements/ | domain 07-performance-budgets | 06-capture-and-recording | Default video bitrate; concrete value is a platform measurement, not a domain contract. |
| FENCE_BUDGET_MS | measurements/ | domain 02-frame-delivery §Asynchronous Readback Synchronization | 04-metal-pipeline | Per-frame fence-wait budget; concrete value is a platform measurement. |
