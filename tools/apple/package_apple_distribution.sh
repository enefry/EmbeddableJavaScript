#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

PRODUCT_NAME="${EJS_APPLE_PRODUCT_NAME:-EJS}"
PRODUCT_VERSION="${EJS_APPLE_PRODUCT_VERSION:-0.1.0}"
BUILD_CONFIGURATION="${EJS_APPLE_BUILD_CONFIGURATION:-Release}"
IOS_DEPLOYMENT_TARGET="${EJS_APPLE_IOS_DEPLOYMENT_TARGET:-12.0}"
PODSPEC_SOURCE_URL="${EJS_APPLE_PODSPEC_SOURCE_URL:-}"
PODSPEC_HOMEPAGE="${EJS_APPLE_PODSPEC_HOMEPAGE:-https://example.com/your-repo}"
PODSPEC_AUTHOR="${EJS_APPLE_PODSPEC_AUTHOR:-ejs}"
PODSPEC_AUTHOR_EMAIL="${EJS_APPLE_PODSPEC_AUTHOR_EMAIL:-dev@example.com}"
EJS_ENGINE="${EJS_ENGINE:-quickjs-ng}"
EJS_RUNTIME_LOOP="${EJS_RUNTIME_LOOP:-libuv}"
DIST_DIR="${EJS_APPLE_DIST_DIR:-$REPO_ROOT/dist/apple}"
BUILD_DIR="${EJS_APPLE_BUILD_DIR:-$DIST_DIR/.build}"

APPLE_TARGETS=(
  ejs_core
  ejs_apple_platform
  ejs_wintertc_apple
  ejs_fs_apple
  ejs_system_apple
  ejs_fswatch_apple
  ejs_path_apple
  ejs_buffer_apple
  ejs_kv_apple
  ejs_sqlite_apple
  ejs_net_apple
  ejs_xhr_apple
  ejs_ws_apple
  ejs_worker_apple
  ejs_package_apple
  ejs_hashing_apple
  ejs_uuid_apple
  ejs_ipaddr_apple
)

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake not found" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found" >&2
  exit 1
fi

if ! command -v libtool >/dev/null 2>&1; then
  echo "libtool not found" >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
mkdir -p "$BUILD_DIR"

build_targeted_apple_libs() {
  local build_path=$1
  local sysroot=$2
  local architectures=$3
  local variant=$4
  local cmake_log build_log

  cmake_log="$BUILD_DIR/.cmake-${variant}.log"
  build_log="$BUILD_DIR/.build-${variant}.log"
  mkdir -p "$build_path"

  echo "Configuring $variant build at $build_path" >&2
  cmake -S "$REPO_ROOT" -B "$build_path" \
    -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$architectures" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DBUILD_TESTING=OFF \
    -DEJS_ENGINE="$EJS_ENGINE" \
    -DEJS_RUNTIME_LOOP="$EJS_RUNTIME_LOOP" \
    > "$cmake_log" 2>&1 \
  || {
    echo "CMake configure failed for $variant; see $cmake_log" >&2
    tail -n 60 "$cmake_log" >&2
    exit 1
  }

  echo "Building $variant targets: ${APPLE_TARGETS[*]}" >&2
  cmake --build "$build_path" --config "$BUILD_CONFIGURATION" --target "${APPLE_TARGETS[@]}" \
    > "$build_log" 2>&1 \
  || {
    echo "Build failed for $variant; see $build_log" >&2
    tail -n 60 "$build_log" >&2
    exit 1
  }
}

build_apple_lib_paths() {
  local build_path=$1
  local target
  local paths=()
  local match
  for target in "${APPLE_TARGETS[@]}"; do
    match="$(find "$build_path" -type f -name "lib${target}.a" | sort | head -n 1)"
    if [[ -z "$match" ]]; then
      echo "Unable to locate built library for $target under $build_path" >&2
      echo "Check build log: $BUILD_DIR/.build-*.log" >&2
      echo "Check configure log: $BUILD_DIR/.cmake-*.log" >&2
      exit 1
    fi
    paths+=("$match")
  done
  printf '%s\n' "${paths[@]}"
}

read_array_or_exit() {
  local out_array_name=$1
  local build_path=$2
  local output
  local line

  output="$(build_apple_lib_paths "$build_path")"

  eval "$out_array_name=()"
  while IFS= read -r line; do
    eval "$out_array_name+=(\"$line\")"
  done <<< "$output"
}

build_iphoneos_dir="$BUILD_DIR/iphoneos"
build_sim_dir="$BUILD_DIR/iphonesimulator"

build_targeted_apple_libs "$build_iphoneos_dir" iphoneos arm64 iphoneos
build_targeted_apple_libs "$build_sim_dir" iphonesimulator "x86_64;arm64" simulator

read_array_or_exit build_iphoneos_libs "$build_iphoneos_dir"
read_array_or_exit build_sim_libs "$build_sim_dir"

for lib in "${build_iphoneos_libs[@]}" "${build_sim_libs[@]}"; do
  if [[ ! -f "$lib" ]]; then
    echo "Missing expected static library: $lib" >&2
    echo "Check configure logs: $BUILD_DIR/.cmake-*.log" >&2
    echo "Check build logs: $BUILD_DIR/.build-*.log" >&2
    exit 1
  fi
done

IOS_HEADERS_DIR="$DIST_DIR/headers-ios"
SIM_HEADERS_DIR="$DIST_DIR/headers-sim"
rm -rf "$IOS_HEADERS_DIR" "$SIM_HEADERS_DIR"
mkdir -p "$IOS_HEADERS_DIR" "$SIM_HEADERS_DIR"

copy_headers() {
  local out=$1
  mkdir -p "$out"
  cp -R "$REPO_ROOT/core/include/." "$out/"
  cp -R "$REPO_ROOT/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/wintertc/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/fs/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/system/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/fswatch/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/worker/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/path/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/buffer/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/kv/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/sqlite/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/net/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/xhr/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/stdlib/hashing/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/stdlib/uuid/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/stdlib/ipaddr/platform/apple/include/." "$out/"
  cp -R "$REPO_ROOT/modules/package/platform/apple/include/." "$out/"
}

copy_headers "$IOS_HEADERS_DIR"
cp -R "$IOS_HEADERS_DIR/." "$SIM_HEADERS_DIR"

IOS_LIB="$DIST_DIR/lib${PRODUCT_NAME}_apple.a"
SIM_LIB="$DIST_DIR/lib${PRODUCT_NAME}_apple_sim.a"

libtool -static -o "$IOS_LIB" "${build_iphoneos_libs[@]}"
libtool -static -o "$SIM_LIB" "${build_sim_libs[@]}"

XCFRAMEWORK_PATH="$DIST_DIR/${PRODUCT_NAME}.xcframework"
rm -rf "$XCFRAMEWORK_PATH"

xcodebuild -create-xcframework \
  -library "$IOS_LIB" -headers "$IOS_HEADERS_DIR" \
  -library "$SIM_LIB" -headers "$SIM_HEADERS_DIR" \
  -output "$XCFRAMEWORK_PATH"

if [[ -n "$PODSPEC_SOURCE_URL" ]]; then
  PODSPEC_SOURCE="  s.source       = { :git => '${PODSPEC_SOURCE_URL}', :tag => '${PRODUCT_VERSION}' }"
else
  PODSPEC_SOURCE="  s.source       = { :path => '.' }"
fi

cat > "$DIST_DIR/${PRODUCT_NAME}.podspec" <<EOF
Pod::Spec.new do |s|
  s.name         = '${PRODUCT_NAME}'
  s.version      = '${PRODUCT_VERSION}'
  s.summary      = 'Embedded JavaScript runtime bindings for iOS.'
  s.homepage     = '${PODSPEC_HOMEPAGE}'
  s.license      = { :type => 'MIT' }
  s.author       = { '${PODSPEC_AUTHOR}' => '${PODSPEC_AUTHOR_EMAIL}' }
  s.platforms    = { :ios => '${IOS_DEPLOYMENT_TARGET}' }
${PODSPEC_SOURCE}
  s.requires_arc = true
  s.vendored_frameworks = '${PRODUCT_NAME}.xcframework'
  s.frameworks = 'Foundation', 'Security'
end
EOF

cat > "$DIST_DIR/Package.swift" <<EOF
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "${PRODUCT_NAME}",
  platforms: [
    .iOS("${IOS_DEPLOYMENT_TARGET}")
  ],
  products: [
    .library(
      name: "${PRODUCT_NAME}",
      targets: ["${PRODUCT_NAME}"]
    )
  ],
  targets: [
    .binaryTarget(
      name: "${PRODUCT_NAME}",
      path: "./${PRODUCT_NAME}.xcframework"
    )
  ]
)
EOF

cat > "$DIST_DIR/README.md" <<EOF
# ${PRODUCT_NAME} iOS Distribution Bundle

This directory contains the generated distribution artifacts for iOS:

- ${PRODUCT_NAME}.xcframework
- ${PRODUCT_NAME}.podspec
- Package.swift

Use this folder with either CocoaPods or SwiftPM.

## CocoaPods

In a consuming project, point to this directory or copy *.podspec and .xcframework
into your pod package.

## SwiftPM

For local package testing:

1. Set repository path to this directory.
2. Use ${PRODUCT_NAME} as the package dependency.

EOF

echo "Distribution output: $DIST_DIR"
