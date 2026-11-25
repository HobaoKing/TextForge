#!/bin/bash
set -euo pipefail

# 在 iOS 模拟器上运行 Swift Package 的单元测试。参数为已启动模拟器的 UDID，或 booted 表示任选一台已启动的模拟器。
if [[ $# != 1 ]]; then
    echo "Usage: bash scripts/test-ios.sh <booted-simulator-udid|booted>" >&2
    exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device="$1"
if [[ "$device" == booted ]]; then
    device="$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p' | head -n 1)"
    if [[ -z "$device" ]]; then
        echo "No booted simulator found." >&2
        exit 1
    fi
fi
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/textforge-test.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT

cd "$repo_dir"
xcodebuild test -scheme TextForge -destination "platform=iOS Simulator,id=$device" -derivedDataPath "$derived_data"
