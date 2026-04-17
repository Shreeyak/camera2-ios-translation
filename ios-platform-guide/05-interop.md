# 05 — Swift ↔ C++ Interop

Direct interop rules, exception discipline, reference-type import, and the async
consumer dispatch mechanism that sits on top.

---

## ADR-11: Direct Swift ↔ C++ interop; no Objective-C++

With Swift 6.2+ and `.interoperabilityMode(.Cxx)` plus `cxxLanguageStandard: .cxx20`,
the Clang module importer handles POD, `std::span`, and `enum class` cleanly. **Do
not add an Objective-C++ bridging layer.**

`.mm` files were the Swift 5-era workaround. They are unnecessary under Swift 6
C++ interop for the common cases. A project should contain zero `.mm` files.

### Rule: keep problematic headers out of Swift's view

Complex C++ headers (OpenCV, Eigen, anything with heavy templates, macros, or
exceptions in public headers) pain Swift's Clang importer. The fix is architectural:
**never let Swift import them.**

- **Public C++ headers** (exposed to Swift via the module map) contain only:
  - POD structs
  - `enum class` declarations
  - C-ABI callback typedefs (`using F = void (*)(void*, T)`)
  - `SWIFT_SHARED_REFERENCE`-annotated reference types
- **Private implementation** (`.cpp` files) may `#include` anything. Swift never
  sees these.
- In practice: one `Foo.hpp` in `include/` (Swift-safe), one `Foo.cpp` in `src/`
  (includes OpenCV, Eigen, etc.).

Build the C++ target as a pure-C++ SPM library target with no Apple-framework
dependencies in its public headers. This keeps it independently testable via
`swift test` on the macOS host without standing up a camera, Metal, or AVFoundation.

---

## Importing C++ reference types: SWIFT_SHARED_REFERENCE

C++ classes with identity (own state, can't be copied) import as Swift reference
types via explicit retain/release function pairs:

```cpp
// Foo.hpp — public
class SWIFT_SHARED_REFERENCE(foo_retain, foo_release) Foo {
public:
    Foo();
    ~Foo();
    void doThing();
private:
    struct Impl;
    Impl* impl_;  // pimpl; OpenCV stays in Foo.cpp
};

extern "C" {
    void foo_retain(Foo* f);
    void foo_release(Foo* f);
}
```

Swift imports `Foo` as an ARC-managed class. No ObjC++ bridging, no
`@unchecked Sendable` raw-pointer wrappers.

Alternatives to avoid:

- **Importing as value type** (default) — wrong for classes with identity; causes
  copy of mutable state.
- **`@unchecked Sendable` Swift wrapper holding a raw pointer** — manual lifetime
  management, easy to leak or use-after-free.

---

## ADR-12: C++ exception discipline

**Every public C++ method is `noexcept`. Every internal call is wrapped in try/catch
at the facade. Exceptions are translated to error-code return values.**

Uncaught C++ exceptions crossing into Swift abort the process. Swift 6's C++ `throws`
importer is not yet production-ready for complex exception hierarchies (e.g.
`cv::Exception`).

Pattern:

```cpp
ErrorCode Foo::doThing() noexcept {
    try {
        impl_->doThing();
        return ErrorCode::Ok;
    } catch (const cv::Exception&) {
        return ErrorCode::OpenCVFailure;
    } catch (const std::exception&) {
        return ErrorCode::InternalFailure;
    } catch (...) {
        return ErrorCode::InternalFailure;
    }
}
```

The `noexcept` specifier asserts the contract in the type system. Enforce with a
"poison" test that feeds malformed input to every public method and asserts the
return is an `ErrorCode`, not a crash. Runs via `swift test` on host.

---

## std::span across the boundary

Prefer `std::span<T>` over raw pointer + length pairs for buffer arguments. Under
`.interoperabilityMode(.Cxx)`, `std::span` imports as Swift `Span<T>` without heap
allocation.

- Non-escapable: enforces "valid only for duration of this call" at the type level.
- Bounds-checked.
- No manual length-mismatch bugs.

The raw pointer + length pattern is still valid C; use `std::span` for new code.

---

## ADR-13: Async consumer dispatch (drop-on-busy)

Consumers of camera frames (anything downstream that might be slow — CV, ML, custom
analysis) are **always async**. Preview smoothness is inviolable — a slow consumer
must drop frames, not block the GPU pipeline. Synchronous dispatch inside the capture
delegate is not acceptable.

### Two viable mechanisms

**Mechanism A — C++ thread pool inside the imaging core.**

- Fixed-size thread pool (`std::min(4, std::thread::hardware_concurrency())`).
- Per-consumer 1-slot mailbox (newest frame overwrites pending; drop-on-busy).
- Consumers subscribe to a C++ `PixelSink` and run on pool threads.
- Best when: multiple consumers, may run in parallel, the imaging core is
  independently testable via `swift test`.

**Mechanism B — per-consumer `AsyncStream.bufferingNewest(1)` in Swift.**

- One stream per consumer; engine yields `sending Frame` on frame completion.
- Consumer `for await`s in a `Task` on its own queue / actor.
- Best when: one or two consumers, all-Swift product.

For multi-consumer products with a C++ analysis core, Mechanism A. For a single
Swift-side consumer, Mechanism B. Both satisfy drop-on-busy.

### 1-slot mailbox, not 4-frame queue

A 1-slot "newest wins" mailbox is preferred over a 4-frame bounded queue:

- Consumer always sees the newest frame, never stale.
- No accumulating latency under sustained overload.
- Simpler liveness guarantees.

A 4-frame queue is appropriate only when downstream needs sequential continuity
(e.g. optical flow requires frames in order) — not for the drop-tolerant case.

### What never crosses the consumer boundary

| Forbidden | Reason |
|---|---|
| Raw `CVPixelBuffer` into a consumer that retains past the callback | Capture session recycles the buffer |
| `MTLTexture` not backed by IOSurface | Metal texture identity isn't portable across command buffers |
| Anything non-Sendable on the return path | Crosses back to the engine and eventually `@MainActor` |

Consumer receives an IOSurface ref (retained for callback duration) and returns a
Sendable result struct. That's the entire contract.

### C-ABI callback pattern for C++ → Swift returns

C++ consumers return results to Swift via plain C function pointers, not via C++
std::function or virtual methods:

```cpp
// In the public C++ header
using EdgeResultCallback = void (*)(
    void* context,
    uint64_t presentationTimeNs,
    const uint8_t* edges,
    int32_t width,
    int32_t height,
    int32_t bytesPerRow
);

void setResultCallback(EdgeResultCallback cb, void* context);
```

Swift side:

```swift
// Retain the context box to keep `self` alive while the C++ pool holds the pointer
let box = Unmanaged.passRetained(self)
detector.setResultCallback({ ctx, pts, edges, w, h, stride in
    let engine = Unmanaged<CameraEngine>.fromOpaque(ctx!).takeUnretainedValue()
    // copy `edges` bytes to a Sendable Data here — buffer is valid only for this call
    let data = Data(bytes: edges!, count: Int(h) * Int(stride))
    Task { @MainActor in engine.viewModel.edgeResult = EdgeResult(...) }
}, box.toOpaque())
```

- C-ABI callbacks are trivially bridgeable; C++ virtual methods are not.
- `context: void*` is the opaque Swift self reference (`Unmanaged.toOpaque()`).
- Balance `passRetained` with a matching `release` or `takeRetainedValue` when the
  C++ side drops the callback (typically on unsubscribe).
- The buffer pointer is valid only for the duration of the callback. Copy what you
  need before returning.

### Keep `.interoperabilityMode(.Cxx)` contained

Enable C++ interop only on the Swift module(s) that actually touch C++ — typically
a thin "interop facade" module plus the C++ target. Every other Swift module should
be pure Swift (no C++ interop mode).

Reasons:

- C++ interop mode slows Swift compilation significantly (Clang module imports of
  C++ headers are slow).
- Pure-Swift modules get clean Sendable inference; interop modules need
  `@unchecked Sendable` on C++ wrappers and the analysis becomes manual.
- The facade is where you translate non-Sendable C++ return types into Sendable
  Swift result structs. Keeping the facade thin keeps that translation auditable.

### Back-pressure doesn't hop back

The engine never slows the camera hardware in response to a slow consumer. Drop-on-busy
absorbs the gap. If a consumer is consistently slow (e.g. Canny on full-resolution
instead of 480p), the fix is to change the input — downscale, strip channels — not
to introduce a backpressure mechanism.
