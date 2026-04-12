# 06 — C++ Sinks

## Public Consumer API

Header: `packages/cambrian_camera/android/src/main/cpp/include/cambrian_camera_native.h`

### FrameMetadata
```cpp
struct FrameMetadata {
    int64_t sensorTimestampNs;
    int64_t exposureTimeNs;
    int64_t frameDurationNs;
    int64_t iso;
    float   focusDistanceDiopters;
    int32_t aeState;
    int32_t afState;
    int32_t awbState;
    int32_t flashState;
};
```
Values come from the `long[5]` + `int[4]` flat arrays passed via JNI from `CameraController`'s `repeatingCaptureCallback`.

### PixelFormat
```cpp
enum class PixelFormat { RGBA8888 };
```
All frames delivered as RGBA8888.

### SinkRole
```cpp
enum class SinkRole {
    FULL_RES,   // Full GPU-processed frame at stream resolution
    TRACKER,    // Downscaled processed frame (480px height)
    RAW,        // Full-res unprocessed (no shader adjustments)
};
```

### SinkConfig
```cpp
struct SinkConfig {
    SinkRole    role;
    SinkCallback callback;
    // optional: ProcessingStage hook (set via setFrameHook)
};
```

### SinkCallback
```cpp
using SinkCallback = std::function<void(const SinkFrame&)>;

struct SinkFrame {
    int64_t       frameId;
    FrameMetadata meta;
    const uint8_t* data;     // RGBA8888 pixels
    size_t         dataLen;
    int            width;
    int            height;
    int            stride;   // bytes per row
    PixelFormat    format;
};
```
`data` points into the `SharedFrame`'s `std::vector<uint8_t>`. Valid only for the duration of the callback. Consumer must copy if it needs to retain the data.

### FrameHookFn
```cpp
using FrameHookFn = std::function<void(SharedFrame&)>;
```
Optional per-role pre-dispatch hook. Can modify the frame in place before it is sent to consumers.

### IImagePipeline (abstract)
```cpp
class IImagePipeline {
public:
    virtual ~IImagePipeline() = default;
    virtual void deliverFullResRgba(SharedFrame frame) = 0;
    virtual void deliverTrackerRgba(SharedFrame frame) = 0;
    virtual void deliverRawRgba(SharedFrame frame) = 0;
    virtual void captureToFile(const std::string& path, int jpegQuality) = 0;
    virtual void captureToFd(int fd, bool isJpeg, int jpegQuality) = 0;
    virtual void setFrameHook(SinkRole role, FrameHookFn hook) = 0;
    virtual void addSink(const SinkConfig& config) = 0;
    virtual void removeSink(SinkRole role) = 0;
};
```

## ImagePipeline (implementation)

File: `src/ImagePipeline.cpp` / `ImagePipeline.h`

### Internal Data Structures

```cpp
struct Consumer {
    SinkConfig     config;
    std::mutex     mu;
};

struct ProcessingStage {
    FrameHookFn       hook;
    std::atomic<bool> hookActive;
    SharedFrame       pending;    // 1-slot mailbox
    std::mutex        mu;
    std::condition_variable cv;
    std::thread       thread;
    std::atomic<bool> running;
};
```

`SharedFrame = std::shared_ptr<Frame>` where:
```cpp
struct Frame {
    int64_t           id;
    FrameMetadata     meta;
    std::vector<uint8_t> data;
    int               width;
    int               height;
    int               stride;
    PixelFormat       format;
};
```

### Delivery Path

`deliverFullResRgba(frame)`:
1. Check `captureRequested_` atomic flag (fast path: skip all work if no capture pending and no sinks registered).
2. Acquire `fullResConsumersMu_` (shared lock).
3. For each registered `FULL_RES` consumer:
   a. Acquire `consumer.mu`.
   b. If `ProcessingStage` exists for this role: place frame into `pending` (overwrites unprocessed frame if busy — drop-on-busy semantics), signal `cv`.
   c. If no `ProcessingStage`: invoke `consumer.config.callback(SinkFrame{...})` directly.

Same pattern for `deliverTrackerRgba` and `deliverRawRgba` with their respective consumer maps.

### ProcessingStage Thread Loop
```
while (running) {
    wait on cv (predicate: pending != nullptr)
    frame = steal pending
    if (hookActive) hook(frame)
    for each consumer in this role: callback(SinkFrame{frame})
}
```

### Lock Ordering
```
fullResConsumersMu_ > ProcessingStage::mu > Consumer::mu
```
Must always acquire in this order to prevent deadlock.

### Capture-to-File

`captureRequested_` is an `std::atomic<bool>`:
- Zero-overhead fast path: `deliverFullResRgba` exits early when `captureRequested_ == false` and no sinks.
- `captureToFile(path, quality)` sets `captureRequested_ = true`; the next `deliverFullResRgba` call encodes the frame (JPEG via libjpeg-turbo, PNG via fpng) and writes to disk.
- `captureToFd(fd, isJpeg, quality)` same but writes to an open file descriptor (used by the MediaStore path in Kotlin).

### JPEG and PNG Encoding

- **JPEG**: `libjpeg-turbo 3.0.3` (`turbojpeg_static`). Quality: `JPEG_QUALITY = 90` (constant in `CameraController.kt`).
- **PNG**: `fpng` (bundled `fpng.cpp` / `fpng.h`).
- Format detected from file extension in `captureImage()` on the Kotlin side; `isJpeg` flag passed to `nativeCaptureImageToFd`.

## Sink Registration

External consumers (not the preview) obtain a handle via `getNativePipelineHandle()` (Pigeon method), then call `IImagePipeline::addSink()` directly via the opaque pointer. This is the intended integration path for e.g. a tracker module.

Sinks are removed by calling `removeSink(role)`. All sink operations are thread-safe via `fullResConsumersMu_`.
