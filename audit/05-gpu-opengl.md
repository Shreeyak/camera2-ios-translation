# 05 — GPU / OpenGL ES

## EGL Setup

`GpuRenderer::init()` creates:
- `EGLDisplay` from `eglGetDisplay(EGL_DEFAULT_DISPLAY)`
- `EGLConfig` with `EGL_OPENGL_ES3_BIT`, RGBA8, depth 0, stencil 0
- `EGLContext` with `EGL_CONTEXT_CLIENT_VERSION=3`
- `EGLSurface` (pbuffer, 1×1) as the off-screen surface for GL setup and teardown

Per-session surfaces created after `init()`:
- `eglPreviewSurface_` — window surface from `SurfaceProducer.getSurface()` (Flutter preview texture)
- `eglEncoderSurface_` — window surface from `VideoRecorder.inputSurface` (MediaCodec encoder input)
- `eglRawSurface_` — window surface from `rawSurfaceProducer.getSurface()` (optional raw texture)

## Shaders (inline C++ string literals in `GpuRenderer.cpp`)

All shader sources are `static const char*` constants. No `.glsl` files exist in the codebase.

### Vertex Shader (`kVertSrc`) — shared by all passes
```glsl
#version 300 es
in vec2 aPos;
out vec2 vTexCoord;
void main() {
    // ... UV rotation 90° CW applied via mat2 uniform ...
    gl_Position = vec4(aPos, 0.0, 1.0);
    vTexCoord = uUvTransform * aPos * 0.5 + 0.5;
}
```
Uniform `uUvTransform`: 2×2 matrix set per frame from `GpuPipeline`'s 90° CW rotation matrix for landscape-right normalization.

### Processed Fragment Shader (`kFragSrc`)
```glsl
#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
uniform samplerExternalOES uTex;
```
Color transform pipeline (applied in order):
1. **Black balance**: `color = max(color - blackOffset, vec3(0.0))` where `blackOffset = vec3(blackR, blackG, blackB)`; scales result back to [0,1].
2. **Brightness**: positive branch: `color = 1 - pow(1-color, vec3(2.7^brightness))`; negative branch: `color = color * (1 + brightness*0.75)`.
3. **Contrast**: piecewise sigmoid. Below 0.5: `color * (0.5 + contrast*0.5)`; above 0.5: scaled reciprocal. Multiplied by 0.5 factor.
4. **Saturation**: `luma = dot(color, vec3(0.2126, 0.7152, 0.0722))` (Rec.709); `color = mix(luma, color, 1.0 + saturation)`, clamped to [0,1].
5. **Gamma**: `color = pow(color, vec3(1.0 / max(gamma, 0.001)))`.

### Raw Fragment Shader (`kRawFragSrc`)
Passthrough: samples `samplerExternalOES uTex` without any color adjustments.

## GL Objects

| Object | Type | Purpose |
|--------|------|---------|
| `program_` | `GLuint` | Linked shader program (kVertSrc + kFragSrc) |
| `rawProgram_` | `GLuint` | Linked shader program (kVertSrc + kRawFragSrc) |
| `vbo_` | `GLuint` | Full-screen quad vertices (2 triangles, NDC coordinates) |
| `oesTexture_` | `GLuint` | `GL_TEXTURE_EXTERNAL_OES` — camera frame from SurfaceTexture |
| `fboIds_[2]` | `GLuint[2]` | Framebuffer objects (ping-pong, processed RGBA) |
| `fboTextures_[2]` | `GLuint[2]` | RGBA8 color attachments for `fboIds_` |
| `pboIds_[2]` | `GLuint[2]` | Pixel Buffer Objects — async GPU readback targets |
| `pboFences_[2]` | `GLsync[2]` | Sync fence objects for each PBO submission |
| `rawFboId_` | `GLuint` | FBO for raw (unprocessed) stream |
| `rawFboTexture_` | `GLuint` | RGBA8 color attachment for `rawFboId_` |
| `trackerFboId_` | `GLuint` | FBO for downscaled tracker stream |
| `trackerFboTexture_` | `GLuint` | RGBA8 color attachment for `trackerFboId_` |

## Uniform Locations

| Uniform Name | Type | Purpose |
|-------------|------|---------|
| `uTex` | `samplerExternalOES` | OES texture unit 0 |
| `uUvTransform` | `mat2` | 90° CW UV rotation for landscape normalization |
| `uBrightness` | `float` | brightness value [-1.0, 1.0] |
| `uContrast` | `float` | contrast value [0.0, 2.0] |
| `uSaturation` | `float` | saturation value [-1.0, 1.0] |
| `uBlackR`, `uBlackG`, `uBlackB` | `float` | per-channel black offset |
| `uGamma` | `float` | gamma exponent |

Uniform values are guarded by `uniformMu_` (C++ mutex). `setAdjustments()` writes under the mutex; `drawAndReadback()` reads under the mutex when calling `glUniform*`.

## PBO Readback Protocol

Per-frame sequence (indices alternate: `current = frameCount % 2`, `prev = 1 - current`):

```
Frame N:
  1. glBindFramebuffer(fboIds_[current])
  2. glDrawArrays → renders OES → RGBA into fboTextures_[current]
  3. eglSwapBuffers(eglPreviewSurface_)     -- preview display
  4. [if recording] eglSwapBuffers(eglEncoderSurface_)
  5. glBindBuffer(GL_PIXEL_PACK_BUFFER, pboIds_[current])
  6. glReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,0)  -- async (PBO bound)
  7. glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE)  → pboFences_[current]
  8. [map prev PBO]  glClientWaitSync(pboFences_[prev], 0, 0)
     if TIMEOUT_EXPIRED: glClientWaitSync(pboFences_[prev], 0, 8ms)
     if still expired:   glFinish() + log error
  9. ptr = glMapBufferRange(pboIds_[prev], GL_MAP_READ_BIT)
  10. memcpy(ptr → SharedFrame->data)
  11. glUnmapBuffer(pboIds_[prev])
  12. ImagePipeline::deliverFullResRgba(SharedFrame)
```

## GL Extension Check

`GpuRenderer` checks for `GL_EXT_disjoint_timer_query` during `initGl()`:
```cpp
const char* exts = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
hasTimerQuery_ = exts && strstr(exts, "GL_EXT_disjoint_timer_query");
```
`glBeginQuery` / `glEndQuery` / `glGenQueries` / `glDeleteQueries` are only called when `hasTimerQuery_ == true`.

## Preview Surface Rebind

`eglSwapBuffers()` failures to `eglPreviewSurface_` are counted (`swapFailureCount_`).
When `swapFailureCount_ >= kSwapFailureThreshold (3)`:
- `onPreviewRebindNeeded` callback fires (Kotlin).
- `CameraController` calls `surfaceProducer.getSurface()` and passes it to `GpuPipeline.rebindPreviewSurface()`.
- `GpuPipeline` posts to GL thread: destroys old `eglPreviewSurface_`, creates new one from the provided `Surface`.

## Teardown Safety

`GpuRenderer::release()` binds the pbuffer context before calling `releaseGl()`. This handles the
case where the destructor runs off the GL thread (e.g., called from `GpuPipeline::stop()` on the
background thread). Without binding the pbuffer first, `glDelete*` calls would operate on no context.

## sampleCenterPatch

`GpuRenderer::sampleCenterPatch()`:
- Patch size: 96×96 pixels.
- Reads from the center of `fboTextures_[current]` via `glReadPixels`.
- Uses histogram trimmed mean (discards top/bottom 10% of intensity distribution) to compute R, G, B means.
- Returns `FloatArray(3)` via callback.
