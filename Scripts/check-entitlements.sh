#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_BUDDY=/usr/libexec/PlistBuddy

fail() {
  echo "entitlement check failed: $*" >&2
  exit 1
}

value() {
  "$PLIST_BUDDY" -c "Print :$2" "$1" 2>/dev/null
}

require_value() {
  local file="$1" key="$2" expected="$3"
  local actual
  actual="$(value "$file" "$key")" || fail "$file is missing $key"
  [[ "$actual" == "$expected" ]] || fail "$file has $key=$actual, expected $expected"
}

require_array_value() {
  local file="$1" key="$2" expected="$3"
  local actual
  actual="$(value "$file" "$key")" || fail "$file is missing $key"
  [[ "$actual" == *"$expected"* ]] || fail "$file $key does not contain $expected"
}

require_absent() {
  local file="$1" key="$2"
  if value "$file" "$key" >/dev/null 2>&1; then
    fail "$file must not contain $key"
  fi
}

require_cloud_release() {
  local file="$1"
  require_value "$file" "aps-environment" "production"
  require_array_value "$file" "com.apple.developer.icloud-container-identifiers" "iCloud.com.howmuch.app"
  require_array_value "$file" "com.apple.developer.icloud-services" "CloudKit"
}

require_mac_sandbox() {
  local file="$1"
  require_value "$file" "com.apple.security.app-sandbox" "true"
  require_value "$file" "com.apple.security.files.user-selected.read-write" "true"
}

require_project_mapping() {
  local project="$1" configuration_id="$2" expected_line="$3"
  local block
  block="$(/usr/bin/awk -v identifier="$configuration_id" '
    index($0, identifier " /*") { active = 1 }
    active { print }
    active && /name = (Debug|Release);/ { exit }
  ' "$project")"
  [[ "$block" == *"$expected_line"* ]] \
    || fail "build configuration $configuration_id is missing: $expected_line"
}

check_source() {
  local ios_release="$ROOT/HowMuch/HowMuch-iOS-Release.entitlements"
  local mac_release="$ROOT/HowMuch/HowMuch-macOS.entitlements"
  local mac_local="$ROOT/HowMuch/HowMuch-macOS-local.entitlements"
  local project="$ROOT/HowMuch.xcodeproj/project.pbxproj"

  require_cloud_release "$ios_release"
  require_cloud_release "$mac_release"
  require_mac_sandbox "$mac_release"
  require_mac_sandbox "$mac_local"
  require_absent "$mac_local" "aps-environment"
  require_absent "$mac_local" "com.apple.developer.icloud-container-identifiers"
  require_absent "$mac_local" "com.apple.developer.icloud-services"

  require_project_mapping "$project" A10000000000000000000083 \
    '"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]" = "HowMuch/HowMuch-iOS-Release.entitlements";'
  require_project_mapping "$project" A10000000000000000000083 \
    '"CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]" = "HowMuch/HowMuch-iOS.entitlements";'
  require_project_mapping "$project" A10000000000000000000083 \
    '"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" = "HowMuch/HowMuch-macOS.entitlements";'
  require_project_mapping "$project" A10000000000000000000082 \
    '"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" = "HowMuch/HowMuch-macOS-local.entitlements";'

  echo "Source entitlements are release-ready."
}

check_archive() {
  local archive="${1:-}"
  [[ -n "$archive" ]] || fail "archive mode requires an .xcarchive path"
  [[ -d "$archive" ]] || fail "archive does not exist: $archive"

  local application_path app info entitlements
  application_path="$(value "$archive/Info.plist" "ApplicationProperties:ApplicationPath")" \
    || fail "archive has no application path"
  app="$archive/Products/$application_path"
  [[ -d "$app" ]] || fail "archived app does not exist: $app"

  if [[ -f "$app/Contents/Info.plist" ]]; then
    info="$app/Contents/Info.plist"
  else
    info="$app/Info.plist"
  fi

  entitlements="$(mktemp "${TMPDIR:-/tmp}/howmuch-entitlements.XXXXXX")"
  trap 'rm -f "$entitlements"' EXIT
  /usr/bin/codesign -d --entitlements :- "$app" >"$entitlements" 2>/dev/null \
    || fail "unable to read signed archive entitlements"
  /usr/bin/plutil -lint "$entitlements" >/dev/null \
    || fail "archive has no readable signed entitlements"

  require_cloud_release "$entitlements"
  local platform
  platform="$(value "$info" "CFBundleSupportedPlatforms:0")" || fail "app platform is missing"
  if [[ "$platform" == "MacOSX" ]]; then
    require_mac_sandbox "$entitlements"
  fi

  echo "Signed archive entitlements are valid for $platform."
}

case "${1:-source}" in
  source)
    check_source
    ;;
  archive)
    shift
    check_archive "${1:-}"
    ;;
  *)
    fail "usage: $0 [source | archive PATH.xcarchive]"
    ;;
esac
