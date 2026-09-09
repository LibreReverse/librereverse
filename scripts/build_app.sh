#!/bin/zsh
# Build inputs are explicit; never inherit configuration or files from dist.
set -euo pipefail
workspace_dir="${0:A:h:h}"
cd "$workspace_dir"
build_configuration=release
bundle_name=LibreReverse.app
if [[ "${1:-}" == "--validation" && $# == 1 ]]; then
  build_configuration=debug
  bundle_name=LibreReverse-Validation.app
elif (( $# != 0 )); then
  print -u2 'Usage: scripts/build_app.sh [--validation]'; exit 2
fi
if [[ "$build_configuration" == debug && -n "${SIGNING_IDENTITY:-}" ]]; then
  print -u2 'Validation fixtures require an ad-hoc debug bundle; signed production builds must use release configuration'; exit 2
fi
: "${LIBREREVERSE_WHISPER_CPP_RUNTIME:=$workspace_dir/.artifacts/whisper.cpp}"
: "${LIBREREVERSE_GOOGLE_CLIENT_ID:=}"
: "${LIBREREVERSE_GOOGLE_CLIENT_SECRET:=}"
: "${LIBREREVERSE_UPDATE_MANIFEST_URL:=}"
: "${LIBREREVERSE_UPDATE_PUBLIC_KEY:=}"
: "${SIGNING_IDENTITY:=}"
export LIBREREVERSE_GOOGLE_CLIENT_ID LIBREREVERSE_GOOGLE_CLIENT_SECRET
export LIBREREVERSE_UPDATE_MANIFEST_URL LIBREREVERSE_UPDATE_PUBLIC_KEY
export LIBREREVERSE_VERSION LIBREREVERSE_BUILD_NUMBER SIGNING_IDENTITY

if [[ -n "$SIGNING_IDENTITY" ]]; then
  [[ "$SIGNING_IDENTITY" != "-" ]] || { print -u2 'Use an empty SIGNING_IDENTITY for an ad-hoc developer build'; exit 1; }
  : "${LIBREREVERSE_VERSION:?Release requires LIBREREVERSE_VERSION}"
  : "${LIBREREVERSE_BUILD_NUMBER:?Release requires LIBREREVERSE_BUILD_NUMBER}"
  : "${LIBREREVERSE_GOOGLE_CLIENT_ID:?Release requires explicit Google OAuth client ID}"
  : "${LIBREREVERSE_UPDATE_MANIFEST_URL:?Release requires explicit update manifest URL}"
  : "${LIBREREVERSE_UPDATE_PUBLIC_KEY:?Release requires explicit update verification key}"
  : "${LIBREREVERSE_THIRD_PARTY_NOTICES:?Release requires reviewed third-party notices file}"
fi
if [[ -n "${LIBREREVERSE_THIRD_PARTY_NOTICES:-}" ]]; then
  [[ -f "$LIBREREVERSE_THIRD_PARTY_NOTICES" && -s "$LIBREREVERSE_THIRD_PARTY_NOTICES" ]] || {
    print -u2 'Third-party notices must be a nonempty regular file'; exit 1
  }
fi
speech_runtime="$workspace_dir/.artifacts/speech"
python3 - "$speech_runtime" <<'PYVERIFY'
import pathlib, sys
sys.path.insert(0, 'scripts')
from check_bundle import verify_speech_runtime
verify_speech_runtime(pathlib.Path(sys.argv[1]))
PYVERIFY
runtime="$LIBREREVERSE_WHISPER_CPP_RUNTIME"
[[ -x "$runtime/bin/whisper-cli" && -f "$runtime/LICENSE" ]] || {
  print -u2 'Required native whisper.cpp runtime missing; run scripts/prepare_whisper_cpp_runtime.sh'; exit 1
}
# Verify the large payloads before spending time compiling or copying them.
python3 - "$runtime" <<'PY'
import pathlib, sys
sys.path.insert(0, 'scripts')
from check_bundle import verify_runtime
verify_runtime(pathlib.Path(sys.argv[1]), pathlib.Path('scripts/patches/whisper-cli-vad-token-clock.patch'))
PY

if [[ -n "$SIGNING_IDENTITY" ]]; then
  python3 scripts/verify_release_inputs.py --runtime "$runtime"
fi
swift build -c "$build_configuration" --product librereverse
binary_dir="$(swift build -c "$build_configuration" --show-bin-path)"
staging_root="$(mktemp -d "${TMPDIR:-/private/tmp}/librereverse-build.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
app="$staging_root/$bundle_name"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Frameworks" "$contents/Resources/Transcription/Models"
ditto "$speech_runtime/libLibreReverseSpeech.dylib" "$contents/Frameworks/libLibreReverseSpeech.dylib"
ditto "$speech_runtime/licenses" "$contents/Resources/Speech"
ditto "$speech_runtime/runtime-build.json" "$contents/Resources/Speech/runtime-build.json"
ditto App/Info.plist "$contents/Info.plist"
ditto App/PkgInfo "$contents/PkgInfo"
truncate -s 8 "$contents/PkgInfo"
ditto "$binary_dir/librereverse" "$contents/MacOS/LibreReverse"
ditto "$runtime/bin/whisper-cli" "$contents/Resources/Transcription/whisper-cli"
chmod 755 "$contents/MacOS/LibreReverse" "$contents/Resources/Transcription/whisper-cli"
for model in ggml-large-v3-turbo.bin ggml-silero-v6.2.0.bin; do
  ditto "$runtime/Models/$model" "$contents/Resources/Transcription/Models/$model"
done
ditto "$runtime/LICENSE" "$contents/Resources/Transcription/WHISPER_CPP_LICENSE.txt"
# The statically linked encoder license ships in every bundle, including
# developer/validation builds without a reviewed aggregate notices document.
ditto Sources/CFPNG/vendor/UNLICENSE "$contents/Resources/FPNG_LICENSE.txt"
mkdir -p "$contents/Resources/Licenses"
for license_file in "$workspace_dir/licenses/"*.{txt,md}(N.); do
  ditto "$license_file" "$contents/Resources/Licenses/${license_file:t}"
done
ditto "$runtime/runtime-build.json" "$contents/Resources/Transcription/runtime-build.json"
if [[ -n "${LIBREREVERSE_THIRD_PARTY_NOTICES:-}" ]]; then
  ditto "$LIBREREVERSE_THIRD_PARTY_NOTICES" "$contents/Resources/THIRD_PARTY_NOTICES.txt"
fi
python3 - "$contents/Info.plist" "$build_configuration" <<'PY'
import base64, os, pathlib, plistlib, sys
from urllib.parse import urlparse
path = pathlib.Path(sys.argv[1])
with path.open('rb') as source:
    info = plistlib.load(source)
info['LibreReverseBuildConfiguration'] = sys.argv[2]
info.pop('LibreReverseDevelopmentValidationBundle', None)
if sys.argv[2] == 'debug':
    info['LibreReverseDevelopmentValidationBundle'] = True
    info['CFBundleIdentifier'] = 'local.librereverse.validation'
    info['CFBundleName'] = 'LibreReverse Validation'
    info['CFBundleDisplayName'] = 'LibreReverse Validation'
# Remove source-template values too; every injected value has an explicit input.
keys = {
    'LibreReverseGoogleOAuthClientID': 'LIBREREVERSE_GOOGLE_CLIENT_ID',
    'LibreReverseGoogleOAuthClientSecret': 'LIBREREVERSE_GOOGLE_CLIENT_SECRET',
    'LibreReverseUpdateManifestURL': 'LIBREREVERSE_UPDATE_MANIFEST_URL',
    'LibreReverseUpdatePublicKey': 'LIBREREVERSE_UPDATE_PUBLIC_KEY',
}
for key, variable in keys.items():
    info.pop(key, None)
    if os.environ.get(variable):
        info[key] = os.environ[variable]
url = os.environ.get('LIBREREVERSE_UPDATE_MANIFEST_URL', '')
key = os.environ.get('LIBREREVERSE_UPDATE_PUBLIC_KEY', '')
if bool(url) != bool(key):
    raise SystemExit('Set update manifest URL and public key together')
if url and (urlparse(url).scheme != 'https' or not urlparse(url).hostname):
    raise SystemExit('Update manifest URL must be HTTPS')
if key and len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit('Update key must be a base64 encoded 32-byte Ed25519 public key')
for variable, key in [('LIBREREVERSE_VERSION', 'CFBundleShortVersionString'),
                      ('LIBREREVERSE_BUILD_NUMBER', 'CFBundleVersion')]:
    if os.environ.get(variable):
        info[key] = os.environ[variable]
if info.get('CFBundleExecutable') != 'LibreReverse':
    raise SystemExit('Update App/Info.plist executable to LibreReverse before building')
with path.open('wb') as destination:
    plistlib.dump(info, destination, sort_keys=True)
PY
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$contents/Info.plist")"
xcrun actool --compile "$contents/Resources" --platform macosx \
  --minimum-deployment-target "$minimum_os" --app-icon AppIcon \
  --output-partial-info-plist "$staging_root/asset-info.plist" App/AppIcon.icon
python3 scripts/check_bundle.py "$app" --bundle-from "$binary_dir/librereverse" "$runtime/bin/whisper-cli"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  python3 scripts/verify_release_inputs.py --runtime "$runtime" --bundle "$app"
  ditto release/release-inputs.json "$contents/Resources/release-inputs.json"
fi

sign_args=(--force --sign "${SIGNING_IDENTITY:--}")
if [[ -n "$SIGNING_IDENTITY" ]]; then
  sign_args+=(--options runtime --timestamp)
fi
for dylib in "$contents/Frameworks/"*(N.); do
  codesign "${sign_args[@]}" "$dylib"
done
codesign "${sign_args[@]}" "$contents/Resources/Transcription/whisper-cli"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  # Preserve the development app's designated requirement across rebuilds;
  # the default ad-hoc CDHash requirement changes whenever code changes.
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents/Info.plist")"
  codesign "${sign_args[@]}" --identifier "$bundle_id" \
    --requirements "=designated => identifier \"$bundle_id\"" "$app"
else
  codesign "${sign_args[@]}" "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
# Publish only a fully checked staging bundle. Replacing dist is intentional;
# no previous bundle contents become part of this build.
mkdir -p dist
rm -rf "dist/$bundle_name"
ditto "$app" "dist/$bundle_name"
print "$workspace_dir/dist/$bundle_name"
