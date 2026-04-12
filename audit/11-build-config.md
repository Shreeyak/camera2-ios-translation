# 11 — Build Configuration

## Android SDK Versions

| Setting | Value | File |
|---------|-------|------|
| `compileSdk` | 35 | `packages/cambrian_camera/android/build.gradle.kts` |
| `targetSdk` | 36 | `android/app/build.gradle.kts` |
| `minSdk` | 33 (Android 13) | Both |
| NDK version | `27.0.12077973` | `packages/cambrian_camera/android/build.gradle.kts` |

minSdk 33 eliminates all API version guards for `WRITE_EXTERNAL_STORAGE`, `MediaStore.IS_PENDING`, `ExifInterface` JPEG+PNG support, and `CONTROL_ZOOM_RATIO` (API 30+, already above minSdk).

## Gradle (Plugin Module)

`packages/cambrian_camera/android/build.gradle.kts`:

```kotlin
android {
    compileSdk = 35
    ndkVersion = "27.0.12077973"
    defaultConfig {
        minSdk = 33
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_ABI=arm64-v8a",
                    "-DANDROID_STL=c++_shared",
                    "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
                )
            }
        }
        ndk { abiFilters += listOf("arm64-v8a") }
    }
    externalNativeBuild {
        cmake {
            path = "src/main/cpp/CMakeLists.txt"
            version = "3.22.1"
        }
    }
}

dependencies {
    compileOnly("androidx.lifecycle:lifecycle-common:2.7.0")
    implementation("androidx.lifecycle:lifecycle-process:2.7.0")
}
```

`lifecycle-common` is `compileOnly` because the app provides it; `lifecycle-process` is `implementation` for `ProcessLifecycleOwner`.

## CMakeLists.txt

`packages/cambrian_camera/android/src/main/cpp/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.22.1)
project(cambrian_camera VERSION 1.0 LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)

add_library(cambrian_camera SHARED
    CameraBridge.cpp
    src/GpuRenderer.cpp
    src/ImagePipeline.cpp
    fpng.cpp
)

target_link_libraries(cambrian_camera
    android log GLESv3 EGL turbojpeg_static
)
```

Note: No OpenCV or `libopencv_*` in link libraries. OpenCV was removed in commit `7e77250`.

## libjpeg-turbo

Version: 3.0.3. Built from source via CMake `ExternalProject_Add`. Not a prebuilt.

```cmake
ExternalProject_Add(libjpeg-turbo
    URL "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.0.3.tar.gz"
    CMAKE_ARGS
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DANDROID_ABI=${ANDROID_ABI}
        -DENABLE_SHARED=OFF
        -DENABLE_STATIC=ON
    INSTALL_COMMAND ""
)
```

The result is `turbojpeg_static` linked into `cambrian_camera.so`.

## C++ Standard and ABI

- C++17 (`set(CMAKE_CXX_STANDARD 17)`)
- `c++_shared` STL (shared `libc++_shared.so`)
- `arm64-v8a` only — no 32-bit support

## Android Manifest

`packages/cambrian_camera/android/src/main/AndroidManifest.xml`:

Permissions:
```xml
<uses-permission android:name="android.permission.CAMERA" />
```
No `WRITE_EXTERNAL_STORAGE` or `MANAGE_MEDIA` — not needed at minSdk 33.

Receivers:
```xml
<receiver
    android:name=".LogLevelReceiver"
    android:exported="true">
    <intent-filter>
        <action android:name="com.cambrian.camera.SET_LOG_LEVEL" />
    </intent-filter>
</receiver>
```

`LogLevelReceiver` is `exported="true"` in the main manifest but has a runtime guard:
```kotlin
if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
    Log.w(TAG, "SET_LOG_LEVEL broadcast ignored in release build")
    return
}
```

`VideoRecordingReceiver` is in `src/debug/AndroidManifest.xml` only — merged only in debug builds.

## Dart / Flutter

`pubspec.yaml`:
```yaml
sdk: flutter
environment:
  sdk: ^3.9.2
dependencies:
  permission_handler: ^12.0.1
  material_symbols_icons: ^4.2906.0
  google_fonts: ^8.0.2
```

No `camera` or `camera2` pub.dev packages — the app uses only the custom `cambrian_camera` plugin.

## Host Tests (CMake)

The CMakeLists.txt includes a host-build configuration (non-Android) for unit tests:
```cmake
if(NOT ANDROID)
    find_package(GTest REQUIRED)
    add_executable(cambrian_tests
        tests/TrackerDimTest.cpp
        tests/SinkRoutingTest.cpp
    )
    target_link_libraries(cambrian_tests GTest::GTest GTest::Main cambrian_camera_static)
endif()
```

Tests cover:
- `TrackerDimTest`: validates tracker width formula `((w * kTrackerHeight / h) + 1) & ~1`
- `SinkRoutingTest`: validates `ImagePipeline` consumer dispatch and role routing

## Pigeon Codegen

`scripts/regenerate_pigeon.sh`:
- Runs `dart run pigeon --input pigeons/camera_api.dart`
- Patches generated `Messages.g.kt` and `messages.g.dart` to fix a recurring type-cast bug in Pigeon ≤ v26.3.3
- See `docs/plans/04-06-2026-fix-pigeon-codegen-type-casts.md` for full context

Never run `dart run pigeon` directly.

## OpenCV Note

`CLAUDE.md` documents that the NDK version (`27.0.12077973`) was originally chosen to match OpenCV
prebuilts. OpenCV was subsequently stripped from the pipeline in commit `7e77250` but the NDK version
was retained. The symlink `packages/cambrian_camera/android/opencv` is git-ignored; the CMakeLists.txt
no longer references it. The note in `CLAUDE.md` about the symlink requirement is a historical artifact.
