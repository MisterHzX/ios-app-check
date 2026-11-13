#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export IPHONEOS_DEPLOYMENT_TARGET=17.0
export SDKROOT
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
cargo build --locked --manifest-path backend/Cargo.toml --release --target aarch64-apple-ios

product="$PWD/build/Payload/AppCheck.app"
mkdir -p "$product"
cp App/Info.plist "$product/Info.plist"
icon_plist="$PWD/build/app-icon-info.plist"
xcrun --sdk iphoneos actool --compile "$product" --platform iphoneos \
  --minimum-deployment-target "$IPHONEOS_DEPLOYMENT_TARGET" --target-device iphone \
  --app-icon AppIcon --output-partial-info-plist "$icon_plist" App/Assets.xcassets
/usr/libexec/PlistBuddy -c "Merge $icon_plist" "$product/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon" "$product/Info.plist"
test -s "$product/Assets.car"
xcrun --sdk iphoneos swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-ios17.0 -sdk "$SDKROOT" \
  -import-objc-header App/Bridge.h App/AppCheck.swift \
  -L "$PWD/backend/target/aarch64-apple-ios/release" -lappcheck \
  -framework Security -framework SystemConfiguration -framework CoreFoundation \
  -o "$product/AppCheck"
plutil -lint "$product/Info.plist"
cd build
rm -f iOS-App-Check.ipa
/usr/bin/zip -qr iOS-App-Check.ipa Payload
unzip -tq iOS-App-Check.ipa
