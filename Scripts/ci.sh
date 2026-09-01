#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/HowMuch.xcodeproj"
SCHEME="HowMuch"
CI_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/howmuch-ci.XXXXXX")"

cleanup() {
  rm -rf "$CI_TEMP"
}
trap cleanup EXIT

XCODE_VERSION="$(/usr/bin/xcodebuild -version | /usr/bin/awk 'NR == 1 { print $2 }')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
if (( XCODE_MAJOR < 26 )); then
  echo "HowMuch requires Xcode 26 or newer; selected Xcode is $XCODE_VERSION." >&2
  exit 1
fi

echo "Using Xcode $XCODE_VERSION"
/usr/bin/xcodebuild -project "$PROJECT" -list
"$ROOT/Scripts/check-entitlements.sh" source

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$CI_TEMP/mac-unit" \
  -only-testing:HowMuchTests \
  CODE_SIGNING_ALLOWED=NO \
  test

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$CI_TEMP/ios-simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$CI_TEMP/mac-release" \
  CODE_SIGNING_ALLOWED=NO \
  build

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$CI_TEMP/mac-ui-build" \
  -only-testing:HowMuchUITests \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$CI_TEMP/ios-ui-build" \
  -only-testing:HowMuchUITests \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

if [[ "${HOWMUCH_RUN_UI_TESTS:-0}" != "1" ]]; then
  echo "UI tests built but not run. Set HOWMUCH_RUN_UI_TESTS=1 to execute them."
  exit 0
fi

select_simulator() {
  local family="$1"
  /usr/bin/xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json
import re
import sys

family = sys.argv[1]
payload = json.load(sys.stdin)
candidates = []
for runtime, devices in payload.get("devices", {}).items():
    if "SimRuntime.iOS-" not in runtime:
        continue
    version = tuple(int(value) for value in re.findall(r"\d+", runtime))
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        device_type = device.get("deviceTypeIdentifier", "")
        if family not in device_type:
            continue
        candidates.append((version, device.get("name", ""), device.get("udid", "")))

if candidates:
    print(sorted(candidates, reverse=True)[0][2])
' "$family"
}

IPHONE_UDID="$(select_simulator iPhone)"
IPAD_UDID="$(select_simulator iPad)"
if [[ -z "$IPHONE_UDID" || -z "$IPAD_UDID" ]]; then
  echo "HOWMUCH_RUN_UI_TESTS=1 requires available iPhone and iPad simulators." >&2
  /usr/bin/xcrun simctl list devices available >&2
  exit 1
fi

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$CI_TEMP/mac-ui-test" \
  -only-testing:HowMuchUITests/HowMuchUITests/testSampleDataSmoke \
  test

for destination in "$IPHONE_UDID" "$IPAD_UDID"; do
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$destination" \
    -derivedDataPath "$CI_TEMP/ios-ui-$destination" \
    -only-testing:HowMuchUITests \
    test
done
