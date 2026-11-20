#!/bin/bash
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "Usage: bash scripts/verify-ios.sh <booted-simulator-udid|booted>" >&2
    exit 2
fi

device="$1"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/textforge-check.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
target="$(uname -m)-apple-ios15.0-simulator"
xcrun simctl getenv "$device" SIMULATOR_UDID >/dev/null

xcrun swift build --package-path "$repo_dir" --scratch-path "$scratch_dir/spm" \
    --triple "$target" --sdk "$sdk" --build-system swiftbuild

products_dir="$scratch_dir/spm/out/Products/Debug-iphonesimulator"
module_maps="$scratch_dir/spm/out/Intermediates.noindex/GeneratedModuleMaps-iphonesimulator"
library="$products_dir/libTextForge.a"
test -f "$library"
test -f "$module_maps/TextForge.modulemap"

# 为两种语言各自生成独立的示例 App，两者链接同一份 SwiftPM 产物。
prepare_app() {
    local variant="$1" app_dir="$scratch_dir/$1.app"
    mkdir -p "$app_dir"
    cp "$repo_dir/Examples/Info.plist" "$app_dir/Info.plist"
    plutil -replace CFBundleIdentifier -string "dev.textforge.verification.$variant" "$app_dir/Info.plist"
    plutil -replace CFBundleExecutable -string "$variant" "$app_dir/Info.plist"
    plutil -replace CFBundleName -string "TextForge $variant" "$app_dir/Info.plist"
    plutil -insert MinimumOSVersion -string 15.0 "$app_dir/Info.plist"
    plutil -insert UIDeviceFamily -json '[1,2]' "$app_dir/Info.plist"
    plutil -lint "$app_dir/Info.plist" >/dev/null
}

prepare_app Swift
prepare_app ObjectiveC
xcrun --sdk iphonesimulator swiftc -target "$target" -sdk "$sdk" -parse-as-library -I "$products_dir" \
    "$repo_dir/Examples/Swift/Example.swift" "$library" -o "$scratch_dir/Swift.app/Swift"
xcrun --sdk iphonesimulator clang -target "$target" -fmodules -fobjc-arc \
    -fmodule-map-file="$module_maps/TextForge.modulemap" \
    -c "$repo_dir/Examples/ObjectiveC/main.m" -o "$scratch_dir/ObjectiveC.o"
xcrun --sdk iphonesimulator swiftc -target "$target" -sdk "$sdk" -framework UIKit -framework Foundation \
    "$scratch_dir/ObjectiveC.o" "$library" -o "$scratch_dir/ObjectiveC.app/ObjectiveC"

# 运行独立样例，读取应用沙盒内的断言结果，避免误把进程启动当作交互验收。
verify_app() {
    local variant="$1" bundle_id="dev.textforge.verification.$1"
    local container result attempt
    xcrun simctl install "$device" "$scratch_dir/$variant.app"
    container="$(xcrun simctl get_app_container "$device" "$bundle_id" data)"
    result="$container/Documents/result.txt"
    rm -f "$result"
    xcrun simctl launch --terminate-running-process "$device" "$bundle_id" --verify
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ ! -f "$result" ]] || break
        sleep 0.25
    done
    if [[ ! -f "$result" ]]; then
        echo "$variant example did not report a result." >&2
        return 1
    fi
    if [[ "$(cat "$result")" != PASS ]]; then
        echo "$variant example failed:" >&2
        cat "$result" >&2
        return 1
    fi
    echo "$variant example: PASS"
}

verify_app Swift
verify_app ObjectiveC
