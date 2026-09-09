#!/bin/zsh
set -euo pipefail
workspace_dir="${0:A:h:h}"
app="${1:-$workspace_dir/dist/LibreReverse.app}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set the name of your notarytool keychain profile}"
python3 "$workspace_dir/scripts/check_bundle.py" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
# Gatekeeper verification occurs after stapling, not before first submission.
signing_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
[[ "$signing_details" == *'Authority=Developer ID Application:'* && "$signing_details" == *'(runtime)'* ]] || {
  print -u2 'Notarization requires a Developer ID Application signature with hardened runtime'; exit 1
}
staging_root="$(mktemp -d "${TMPDIR:-/private/tmp}/librereverse-notary.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
ditto -c -k --keepParent "$app" "$staging_root/LibreReverse.zip"
xcrun notarytool submit "$staging_root/LibreReverse.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
print "Notarized and stapled: $app"
