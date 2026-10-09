#!/bin/zsh
# Source identity is checked read-only; only the declared derived plist is written.
set -euo pipefail
[[ $# == 1 ]] || { print -u2 'Usage: generate-app-info.zsh derived-output.plist'; exit 2; }
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 "${0:A:h}/product_identity.py" --app-plist "$1"
