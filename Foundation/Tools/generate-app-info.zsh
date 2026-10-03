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
