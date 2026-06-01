# iOS 分发打包（XCFramework / CocoaPods / SwiftPM）

当前仓库已实现 Android AAR 的导出流程，但尚未内建 iOS 的打包目标。
下面这份脚本用于按同一源码生成 iOS 发布产物：

- `${PRODUCT_NAME}.xcframework`
- `${PRODUCT_NAME}.podspec`
- `Package.swift`

> 默认输出目录：`dist/apple`

## 1. 直接生成产物

```bash
./tools/apple/package_apple_distribution.sh
```

脚本会基于 `iOS` 与 `iOS Simulator` 双端静态库合并为 `xcframework`，并生成 `Podspec` 与 `Package.swift`。

## 2. 可调参数

```bash
EJS_APPLE_PRODUCT_NAME    # 默认 EJS
EJS_APPLE_PRODUCT_VERSION # 默认 0.1.0
EJS_APPLE_IOS_DEPLOYMENT_TARGET # 默认 12.0
EJS_APPLE_BUILD_CONFIGURATION    # 默认 Release
EJS_APPLE_DIST_DIR        # 默认 dist/apple
EJS_APPLE_BUILD_DIR       # 默认 <dist>/.
EJS_ENGINE                # 默认 quickjs-ng
EJS_RUNTIME_LOOP          # 默认 libuv
EJS_APPLE_PODSPEC_SOURCE_URL   # 默认空，生成本地 :path => '.'
EJS_APPLE_PODSPEC_HOMEPAGE     # 默认 https://example.com/your-repo
EJS_APPLE_PODSPEC_AUTHOR       # 默认 ejs
EJS_APPLE_PODSPEC_AUTHOR_EMAIL # 默认 dev@example.com
```

## 3. 接入示例

### CocoaPods

1. 拷贝 `dist/apple/EJS.xcframework` 和 `dist/apple/EJS.podspec` 到你的仓库。
2. Podspec 已包含 `vendored_frameworks = 'EJS.xcframework'`。

### Swift Package Manager

`dist/apple/Package.swift` 是本地二进制包清单，适合先在本地验证：

- `name: EJS`
- `binaryTarget` 指向本目录下 `EJS.xcframework`

## 4. 后续建议

- 如果要发布到远程仓库，建议将 `Package.swift` 与 `Podspec` 中的占位字段替换为你的远程地址/版本。
- 当前脚本不会验证框架 API 导入可用性；建议在产物接入后跑一次最小的 Objective-C/Swift 侧 smoke。
