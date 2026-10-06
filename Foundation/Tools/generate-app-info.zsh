#!/bin/zsh
# Generate only derived build metadata, before Xcode processes/signs Info.plist.
# Config/AlphaVersion.txt remains the single alpha-version authority.
set -euo pipefail
[[ $# == 1 ]] || { print -u2 'Usage: generate-app-info.zsh derived-output.plist'; exit 2; }
alpha=$(< "${0:A:h}/../Config/AlphaVersion.txt")
[[ "$alpha" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid tracked alpha version'; exit 2; }
output=${1:A}
mkdir -p "${output:h}"
/usr/bin/plutil -create xml1 "$output"
/usr/bin/plutil -insert RewindDVAlphaVersion -string "$alpha" "$output"
/usr/bin/plutil -insert RewindDVCandidateRevision \
  -string "Native ${CONFIGURATION:-development} source candidate; hardware qualification pending" "$output"

# Required-driver metadata follows its independent canonical build, not the app counter.
driver_build=$(/usr/bin/sed -n 's/^REWINDDV_DRIVER_BUILD = \([0-9][0-9]*\)$/\1/p' "${0:A:h}/../Config/DriverBuild.xcconfig")
[[ "$driver_build" =~ '^[1-9][0-9]*$' && "$driver_build" -le 4294967295 ]] || { print -u2 'Invalid canonical driver build'; exit 2; }
/usr/bin/plutil -insert RewindDVRequiredDriverBuild -string "$driver_build" "$output"
