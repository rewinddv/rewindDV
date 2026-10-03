#!/bin/zsh
set -euo pipefail

# Package/sign only. Never launch, install, activate, reboot, or operate a deck.
[[ $# == 2 || $# == 3 ]] || {
  print -u2 'Usage: package-b172-app-only.zsh qualified-B172.app built-RewindDV.app [candidate-label]'
  exit 2
}

qualified_app=$1
built_app=$2
candidate_label=${3:-Accessibility RevC}
alpha_version=$(tr -d '\n\r' < Foundation/Config/AlphaVersion.txt)
[[ "$alpha_version" =~ '^0\.0\.[0-9]+$' ]] || { print -u2 'Invalid alpha version'; exit 2; }
[[ -n "$candidate_label" && "$candidate_label" != *[^A-Za-z0-9\ -]* ]] || {
  print -u2 'Candidate label must contain only letters, numbers, spaces and hyphens.'
  exit 2
}
candidate_slug=${candidate_label// /-}
dext_relative=Contents/Library/SystemExtensions/net.rewinddigital.RewindDV.Driver.dext
dext_binary=net.rewinddigital.RewindDV.Driver
signing_identity=${REWINDDV_SIGNING_IDENTITY:?Supply the separately approved packaging identity}

for app in "$qualified_app" "$built_app"; do
  [[ -d "$app" ]]
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == net.rewinddigital.RewindDV ]]
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == 172 ]]
done
[[ -f "$qualified_app/Contents/embedded.provisionprofile" ]]
[[ -f "$qualified_app/$dext_relative/embedded.provisionprofile" ]]
codesign --verify --deep --strict "$qualified_app"

source_dext_hash=$(shasum -a 256 "$qualified_app/$dext_relative/$dext_binary" | awk '{print $1}')
candidate_root=$(mktemp -d "${TMPDIR:-/tmp}/rewinddv-b172-${candidate_slug}.XXXXXX")
candidate_app="$candidate_root/rewindDV LAB Alpha ${alpha_version}.app"
ditto "$qualified_app" "$candidate_app"

# The qualified DEXT, its profile, and every non-host resource remain byte-for-byte
# identical except the host executable and compiled app icon assets below.
cp "$built_app/Contents/MacOS/RewindDV" "$candidate_app/Contents/MacOS/RewindDV"
for icon_resource in AppIcon.icns Assets.car; do
  [[ -f "$built_app/Contents/Resources/$icon_resource" ]]
  cp "$built_app/Contents/Resources/$icon_resource" "$candidate_app/Contents/Resources/$icon_resource"
done
chmod 755 "$candidate_app/Contents/MacOS/RewindDV"
/usr/libexec/PlistBuddy -c 'Delete :RewindDVCandidateRevision' "$candidate_app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :RewindDVCandidateRevision string $candidate_label" "$candidate_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :RewindDVAlphaVersion' "$candidate_app/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :RewindDVAlphaVersion string $alpha_version" "$candidate_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $alpha_version" "$candidate_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName rewindDV' "$candidate_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName rewindDV' "$candidate_app/Contents/Info.plist"
[[ $(shasum -a 256 "$candidate_app/$dext_relative/$dext_binary" | awk '{print $1}') == "$source_dext_hash" ]]

codesign --force --sign "$signing_identity" \
  --entitlements Foundation/Config/App.entitlements "$candidate_app"
codesign --verify --deep --strict --verbose=4 "$candidate_app"

[[ $(shasum -a 256 "$candidate_app/$dext_relative/$dext_binary" | awk '{print $1}') == "$source_dext_hash" ]]
lipo -archs "$candidate_app/Contents/MacOS/RewindDV"
lipo -archs "$candidate_app/$dext_relative/$dext_binary"
shasum -a 256 "$candidate_app/Contents/MacOS/RewindDV" "$candidate_app/$dext_relative/$dext_binary"
print "QUALIFIED_DEXT_SHA256=$source_dext_hash"
print "CANDIDATE_APP=$candidate_app"
print 'Packaged only. Exact qualified Build172 DEXT retained; no activation or reboot is required.'
