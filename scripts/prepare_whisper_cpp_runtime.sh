#!/bin/zsh
set -euo pipefail

workspace_dir="${0:A:h:h}"
runtime_dir="${LIBREREVERSE_WHISPER_CPP_RUNTIME:-$workspace_dir/.artifacts/whisper.cpp}"
source_dir="$runtime_dir/source"
build_dir="$source_dir/build-librereverse"
model_dir="$runtime_dir/Models"
revision="978113305b2ead22249b881deafa131dc8884911"
model_name="ggml-large-v3-turbo.bin"
# Full-precision multilingual turbo model from the upstream artifact manifest.
model_sha256="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$model_name"

mkdir -p "$runtime_dir" "$model_dir"
if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$source_dir"
  git -C "$source_dir" init
  git -C "$source_dir" remote add origin https://github.com/ggml-org/whisper.cpp.git
fi
if [[ "$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)" != "$revision" ]]; then
  git -C "$source_dir" fetch --depth 1 origin "$revision"
fi
git -C "$source_dir" checkout --detach "$revision"

# Upstream's full JSON writes raw compressed-VAD token times. Use its public
# original-media-clock getters until the pinned CLI includes this correction.
clock_patch="$workspace_dir/scripts/patches/whisper-cli-vad-token-clock.patch"
if git -C "$source_dir" apply --check "$clock_patch" 2>/dev/null; then
  git -C "$source_dir" apply "$clock_patch"
elif ! git -C "$source_dir" apply --reverse --check "$clock_patch" 2>/dev/null; then
  print -u2 "error: Whisper token-clock patch does not match the pinned source"
  exit 1
fi

# Compare the working source against exactly the pinned tree plus our patch,
# using an isolated index. Refuse additional local edits without discarding them.
validation_index="$(mktemp "${TMPDIR:-/private/tmp}/librereverse-whisper-index.XXXXXX")"
rm -f "$validation_index"
trap 'rm -f "$validation_index"' EXIT
GIT_INDEX_FILE="$validation_index" git -C "$source_dir" read-tree "$revision"
GIT_INDEX_FILE="$validation_index" git -C "$source_dir" apply --cached "$clock_patch"
if ! GIT_INDEX_FILE="$validation_index" git -C "$source_dir" diff --quiet --exit-code \
   || [[ -n "$(git -C "$source_dir" ls-files --others --exclude-standard)" ]]; then
  print -u2 'error: native source contains changes beyond the pinned VAD patch; use a clean runtime directory'
  exit 1
fi
rm -f "$validation_index"
trap - EXIT

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_CPU_ARM_ARCH=armv8-a \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DWHISPER_BUILD_SERVER=OFF
cmake --build "$build_dir" --config Release --target whisper-cli --parallel

model_path="$model_dir/$model_name"
if [[ ! -f "$model_path" ]] \
  || [[ "$(shasum -a 256 "$model_path" | awk '{print $1}')" != "$model_sha256" ]]; then
  partial="$model_path.partial"
  curl -L --fail --retry 5 --retry-all-errors --connect-timeout 20 --speed-limit 1024 --speed-time 45 --continue-at - --output "$partial" "$model_url"
  actual_sha256="$(shasum -a 256 "$partial" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$model_sha256" ]]; then
    print -u2 "error: Whisper model SHA-256 mismatch: $actual_sha256"
    exit 1
  fi
  mv "$partial" "$model_path"
fi

vad_name="ggml-silero-v6.2.0.bin"
vad_sha256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"
if [[ ! -f "$model_dir/$vad_name" ]] || [[ "$(shasum -a 256 "$model_dir/$vad_name" | awk '{print $1}')" != "$vad_sha256" ]]; then
  curl -L --fail --retry 5 --output "$model_dir/$vad_name.partial" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$vad_name"
  [[ "$(shasum -a 256 "$model_dir/$vad_name.partial" | awk '{print $1}')" == "$vad_sha256" ]] || { print -u2 "error: VAD model checksum mismatch"; exit 1; }
  mv "$model_dir/$vad_name.partial" "$model_dir/$vad_name"
fi

mkdir -p "$runtime_dir/bin"
ditto "$build_dir/bin/whisper-cli" "$runtime_dir/bin/whisper-cli"
chmod 755 "$runtime_dir/bin/whisper-cli"
ditto "$source_dir/LICENSE" "$runtime_dir/LICENSE"

# A self-contained runtime may use Apple system frameworks, but must not point
# back into Homebrew or this temporary build directory.
if otool -L "$runtime_dir/bin/whisper-cli" | tail -n +2 \
  | awk '{print $1}' | grep -E '/opt/homebrew|/usr/local|build-librereverse'; then
  print -u2 "error: whisper-cli has non-system dynamic dependencies"
  exit 1
fi

python3 - "$runtime_dir" "$revision" "$clock_patch" <<'PYMETA'
import hashlib, json, pathlib, subprocess, sys
runtime, revision, patch = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
manifest = {
    'sourceRevision': revision,
    'patchSHA256': sha(patch),
    'helperSHA256': sha(runtime / 'bin/whisper-cli'),
    'ggmlNative': False,
    'armArchitecture': 'armv8-a',
    'compiler': subprocess.check_output(['xcrun', 'clang', '--version'], text=True).strip(),
    'sdkVersion': subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
}
(runtime / 'runtime-build.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
PYMETA

print "$runtime_dir"
