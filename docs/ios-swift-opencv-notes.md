# iOS Swift + OpenCV Integration Notes

## Key Question: Can C++ run natively in iOS?

Yes. iOS fully supports C++ code.

## Options for C++ in iOS

| Method | Description |
|--------|-------------|
| Objective-C++ (`.mm`) | Mix C++ and Objective-C directly |
| C bridge (`extern "C"`) | Wrap C++ for Swift via bridging header |
| Swift/C++ Interop (Xcode 14.3+) | Direct interop, still maturing |
| Static/dynamic library | Compile C++ as `.a` or `.framework` |

## Recommended Approach for Swift + OpenCV

Use the **Objective-C++ wrapper pattern**:

```
Swift  →  Objective-C++ wrapper (.mm)  →  C++/OpenCV
```

### Why not Swift/C++ direct interop?
OpenCV headers are complex (templates, macros, nested includes) and the Swift↔C++ interop layer chokes on them in practice. The Obj-C++ wrapper is cleaner and widely used in production.

## Setup Steps

1. **Add OpenCV** via CocoaPods (`pod 'OpenCV'`) or manually add `opencv2.framework`
2. **Create a wrapper pair:**
   - `OpenCVWrapper.h` — plain Objective-C header (no C++ types exposed)
   - `OpenCVWrapper.mm` — Objective-C++ implementation (C++/OpenCV code lives here)
3. **Bridging header** — import `OpenCVWrapper.h` here so Swift can see it
4. **Call from Swift** as a normal class

## Minimal Example

```objc
// OpenCVWrapper.h
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface OpenCVWrapper : NSObject
- (UIImage *)processImage:(UIImage *)image;
@end
```

```objc
// OpenCVWrapper.mm
#import "OpenCVWrapper.h"
#import <opencv2/opencv.hpp>

@implementation OpenCVWrapper
- (UIImage *)processImage:(UIImage *)image {
    cv::Mat mat;
    // your OpenCV logic here
    return image;
}
@end
```

```objc
// YourApp-Bridging-Header.h
#import "OpenCVWrapper.h"
```

```swift
// Swift usage
let wrapper = OpenCVWrapper()
let result = wrapper.processImage(inputImage)
```

## Other Notes

- Use `libc++` (default on Apple platforms) — full C++ stdlib works fine
- UI code must go through UIKit/SwiftUI; C++ handles logic/compute
- Exceptions and RTTI are supported but can be disabled for performance
