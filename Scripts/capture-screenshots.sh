#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS="${HOWMUCH_SCREENSHOT_DIR:-$ROOT/docs/screenshots}"
DERIVED="${HOWMUCH_SCREENSHOT_DERIVED:-${TMPDIR:-/tmp}/howmuch-screenshot-derived}"
mkdir -p "$SHOTS" "$DERIVED"

export HOWMUCH_SCREENSHOT_DIR="$SHOTS"

pick_simulator() {
  local name="$1"
  xcrun simctl list devices available \
    | /usr/bin/awk -v name="$name" '
        index($0, name) && $0 ~ /\([A-F0-9-]{36}\)/ {
          if (match($0, /[A-F0-9-]{36}/)) {
            print substr($0, RSTART, RLENGTH)
            exit
          }
        }
      '
}

boot_and_style() {
  local udid="$1"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl ui "$udid" appearance light >/dev/null
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --batteryState charged \
    --batteryLevel 100 \
    --operatorName "" >/dev/null || true
}

run_ui_test() {
  local destination="$1"
  local bundle="$2"
  rm -rf "$bundle"
  xcodebuild \
    -project "$ROOT/HowMuch.xcodeproj" \
    -scheme HowMuch \
    -destination "$destination" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$bundle" \
    -only-testing:HowMuchUITests/READMEScreenshotTests/testCaptureREADMEScreenshots \
    test
}

copy_attachments() {
  local bundle="$1"
  local raw="$DERIVED/exported-$(basename "$bundle" .xcresult)"
  rm -rf "$raw"
  mkdir -p "$raw" "$SHOTS"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$raw"
  /usr/bin/python3 - "$raw" "$SHOTS" <<'PY'
import json
import shutil
import sys
from pathlib import Path

raw = Path(sys.argv[1])
dest = Path(sys.argv[2])
payload = json.loads((raw / "manifest.json").read_text())
copied = 0
for item in payload:
    for attachment in item.get("attachments", []):
        exported = attachment.get("exportedFileName")
        suggested = attachment.get("suggestedHumanReadableName") or ""
        name = suggested.split("_0_")[0] if suggested else ""
        source = raw / exported if exported else None
        if not name or source is None or not source.exists():
            continue
        dest_name = name if name.endswith(".png") else f"{name}.png"
        shutil.copy2(source, dest / dest_name)
        copied += 1
        print(dest_name)
print(f"copied {copied} pngs from {raw}")
PY
}

IPHONE_UDID="$(pick_simulator "iPhone 17 Pro (")"
if [[ -z "$IPHONE_UDID" ]]; then
  IPHONE_UDID="$(pick_simulator "iPhone 16 Pro (")"
fi
if [[ -z "$IPHONE_UDID" ]]; then
  IPHONE_UDID="$(pick_simulator "iPhone 17")"
fi
if [[ -z "$IPHONE_UDID" ]]; then
  IPHONE_UDID="$(pick_simulator "iPhone")"
fi
IPAD_UDID="$(pick_simulator "iPad Pro 13-inch (M5)")"
if [[ -z "$IPAD_UDID" ]]; then
  IPAD_UDID="$(pick_simulator "iPad Pro 13-inch")"
fi
if [[ -z "$IPAD_UDID" ]]; then
  IPAD_UDID="$(pick_simulator "iPad Pro")"
fi
if [[ -z "$IPAD_UDID" ]]; then
  IPAD_UDID="$(pick_simulator "iPad")"
fi

if [[ -z "$IPHONE_UDID" || -z "$IPAD_UDID" ]]; then
  echo "Could not find iPhone and iPad simulators." >&2
  xcrun simctl list devices available >&2
  exit 1
fi

boot_and_style "$IPHONE_UDID"
run_ui_test "platform=iOS Simulator,id=$IPHONE_UDID" "$DERIVED/iphone.xcresult"
copy_attachments "$DERIVED/iphone.xcresult"

boot_and_style "$IPAD_UDID"
run_ui_test "platform=iOS Simulator,id=$IPAD_UDID" "$DERIVED/ipad.xcresult"
copy_attachments "$DERIVED/ipad.xcresult"

run_ui_test "platform=macOS,arch=arm64" "$DERIVED/macos.xcresult"
copy_attachments "$DERIVED/macos.xcresult"

resize_png() {
  local file="$1"
  local width="$2"
  if [[ -f "$file" ]]; then
    /usr/bin/sips --resampleWidth "$width" "$file" >/dev/null
  fi
}

resize_png "$SHOTS/iphone-activity.png" 780
resize_png "$SHOTS/iphone-insights.png" 780
resize_png "$SHOTS/iphone-ledgers.png" 780
resize_png "$SHOTS/iphone-expense.png" 780
resize_png "$SHOTS/ipad-split.png" 1280
resize_png "$SHOTS/macos-main.png" 1280
resize_png "$SHOTS/macos-expense.png" 900

echo "Wrote screenshots to $SHOTS"
ls -l "$SHOTS"
