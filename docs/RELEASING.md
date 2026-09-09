# Building and releasing LibreReverse

The production bundle is `dist/LibreReverse.app`. It contains the optimized Swift
executable, the native whisper.cpp helper, both verified models, and the complete
non-system dynamic-library dependency graph. The statically linked FPNG encoder
license is included as `Contents/Resources/FPNG_LICENSE.txt` in every build.
Builds start in an empty temporary
bundle and replace `dist/LibreReverse.app` only after validation and signing.
Previous bundle configuration is never read.

## Prerequisites and supported baseline

Use macOS 26, Xcode with the macOS 26 SDK, SQLCipher development files discoverable
by `pkg-config`, Python 3.9 or newer, and CMake for preparing whisper.cpp. The
package and `App/Info.plist` define the supported minimum OS. The bundle checker
rejects a native dependency that requires a newer OS or lacks an architecture in
the main executable. The build currently produces the host architecture; it does
not claim a universal binary.

Prepare the native transcription and microphone-processing runtimes with:

```sh
scripts/prepare_whisper_cpp_runtime.sh
python3 scripts/prepare_speech_runtime.py
```

That preparation script pins whisper.cpp to commit
`978113305b2ead22249b881deafa131dc8884911`, applies the checked-in VAD token-clock
patch, and verifies both model hashes. Preparation rejects source edits beyond that
patch, disables host-specific CPU instructions, and records the helper hash,
source revision, patch hash, CPU baseline, compiler, and SDK in
`runtime-build.json`. The app builder verifies this manifest before packaging;
stale native-optimized helpers must be rebuilt. It performs network downloads
and a native build. The app build itself does neither and fails if the runtime is missing.
Set `LIBREREVERSE_WHISPER_CPP_RUNTIME` when packaging a runtime outside
`.artifacts/whisper.cpp`. There is no Python transcription fallback in packaging.

Microphone processing uses standalone WebRTC audio processing 2.1 and Abseil
20240722.0. Its preparation script creates a local Meson/Ninja environment, verifies
pinned source archives, and builds `.artifacts/speech/libLibreReverseSpeech.dylib`.
The builder verifies the library and wrapper hashes and bundles all upstream
licenses and the build manifest. It adds no Homebrew or Python runtime dependency.

The model SHA-256 values are:

| Model | SHA-256 |
| --- | --- |
| `ggml-large-v3-turbo.bin` | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |
| `ggml-silero-v6.2.0.bin` | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` |

Signed releases enforce the reviewed [release input lock](../release/release-inputs.json)
before compiling and again against the packaged dependency closure before
signing. Developer builds remain flexible. The current lock records:

| Input | Required release value |
| --- | --- |
| Architecture / minimum OS | arm64 / macOS 26.0 |
| Xcode | 26.6, build 17F113 |
| Swift | 6.3.3 (`swiftlang-6.3.3.1.3`) |
| SDK | 26.5, build 25F70 |
| SQLCipher | 4.18.0, arm64 Tahoe bottle |
| OpenSSL | 4.0.1, arm64 Tahoe bottle rebuild 1 |
| Homebrew prefix | `/opt/homebrew` |

The lock contains immutable bottle URLs and SHA-256 values, source archive URLs
and checksums, OpenSSL source patches, installed library/header/formula hashes,
and exact pkg-config output. It was derived from the installed receipts and
cached OCI bottle manifests; no later Homebrew API version is substituted.
The verifier also checks the speech helper's compiler/SDK and rejects custom
compiler or linker overrides outside the selected SDK.

To provision a dedicated release host:

1. Install/select the locked Xcode version on an Apple Silicon Mac with macOS 26.
2. Retrieve the two exact bottle archives from the lock's immutable registry URLs
   using your artifact client, or copy an already verified bottle cache. Verify
   them **before** installation:

   ```sh
   python3 scripts/verify_release_inputs.py --bottles /path/to/bottles --bottles-only
   ```

3. Install those local bottles into `/opt/homebrew`, OpenSSL first and then
   SQLCipher, and pin both formulae on that dedicated host. Avoid automatic
   dependency upgrades. Source builds or relocated prefixes require a reviewed
   lock update because installed library hashes may differ.
4. Prepare the native speech runtime and verify the complete environment:

   ```sh
   scripts/prepare_whisper_cpp_runtime.sh
   python3 scripts/prepare_speech_runtime.py
   python3 scripts/verify_release_inputs.py --runtime .artifacts/whisper.cpp
   ```

Retain the verified bottle archives with release evidence. Updating a dependency
or toolchain means reviewing and committing an explicit lock change, including
new provenance and hashes, then repeating tests and clean-machine checks. The
builder has no release bypass flag and does not install or upgrade dependencies.
CI's ordinary Homebrew installation is only a flexible developer test setup.
Signing and notarization add timestamps; byte-identical signed output is not
promised.

## Developer build

```sh
scripts/build_app.sh
```

With no `SIGNING_IDENTITY`, the script uses an ad-hoc signature with the stable
bundle-identifier designated requirement used by development builds. Moving to
a Developer ID signature can still require permission reauthorization; a stable
bundle ID does not certify TCC continuity. Optional configuration is supplied
directly through these environment variables:

- `LIBREREVERSE_GOOGLE_CLIENT_ID` and `LIBREREVERSE_GOOGLE_CLIENT_SECRET`.
- `LIBREREVERSE_UPDATE_MANIFEST_URL` and `LIBREREVERSE_UPDATE_PUBLIC_KEY`, together.
- `LIBREREVERSE_VERSION` and `LIBREREVERSE_BUILD_NUMBER`.
- `LIBREREVERSE_THIRD_PARTY_NOTICES`, a reviewed UTF-8 notices file to include.

The update URL must use HTTPS and the public key must be a base64-encoded
32-byte Ed25519 public key. Google OAuth desktop client configuration is embedded
in the distributed bundle; never treat that client secret as confidential.
Signing credentials and the update **private** key must never enter the bundle.
The bundle uses `LibreReverseGoogleOAuthClientID/Secret` and
`LibreReverseUpdateManifestURL/PublicKey` configuration keys. Build scripts never
inherit these values from a previous bundle. Without Google client configuration,
a developer build cannot connect to Drive or resume Drive transfers. Reuse the
same client ID when rebuilding for an existing authorized installation: saved
authorization is scoped to that ID. S3 does not require Google configuration.

## Developer ID build and notarization

Set `SIGNING_IDENTITY` to your Developer ID Application identity. Release builds
require explicit version/build numbers, Google client ID, both update settings,
and `LIBREREVERSE_THIRD_PARTY_NOTICES`. Supply a Google client secret if your
configured desktop OAuth client requires one.

```sh
export SIGNING_IDENTITY='Developer ID Application: Your Organization (TEAMID)'
export LIBREREVERSE_VERSION='0.1.0'
export LIBREREVERSE_BUILD_NUMBER='1'
# Set the OAuth, update, and notices variables described above.
scripts/build_app.sh
export NOTARY_KEYCHAIN_PROFILE='LibreReverse-notary'
scripts/notarize_app.sh
```

Create the notarytool keychain profile separately using your Apple Developer
credentials. The notarization script requires a Developer ID signature with the
hardened runtime, submits a ZIP, staples the accepted ticket, and runs stapler
and Gatekeeper validation. A successful signed build alone is not production
release acceptance.

Dynamic dependencies are copied recursively from the main executable and native
helper, including SQLCipher's cryptographic library. Imports are rewritten to
bundle-relative paths. The checker rejects missing dependencies, basename
collisions, non-system frameworks that need explicit resource packaging, and
external runtime search paths. `native-dependencies.json` records the copied
libraries' unsigned source hashes. Do not use `codesign --deep` to repair nested
signatures: the builder signs individual native libraries and the helper before
signing the app, then uses `--deep` only for verification.

## Tests and release acceptance

```sh
python3 scripts/check_source_tree.py
scripts/test.sh unit
scripts/test.sh integration
# Or run script tests and every Swift test together:
scripts/test.sh all
python3 scripts/check_bundle.py dist/LibreReverse.app
```

The default suite includes product policy, search, queue, archive, database,
publication, and script tests. `scripts/test.sh` documents the explicit
codec/GPU/readback cases assigned to the integration tier. Real user-library and
real-model checks retain their own explicit opt-in controls. CI runs unit tests;
a manually dispatched workflow can also prepare the native microphone-processing
runtime and run synthetic media integration tests. Neither CI tier downloads the
whisper.cpp models or opts into real-model tests. For local DSP integration
coverage, run `python3 scripts/prepare_speech_runtime.py` first; missing runtimes
cause those cases to skip.
A passing unit run is not evidence that the excluded integration cases passed.

Before distributing a release candidate:

1. Complete licensing and provenance review, including SQLCipher, its linked
   cryptographic library, whisper.cpp and its static dependencies, both models,
   and artwork. Include the approved notices file.
2. Run both test tiers and record failures/skips rather than suppressing them.
3. Build with the documented pinned release inputs, sign, notarize, and staple.
4. Test the exact app on a clean supported Mac without Homebrew, with recording,
   microphone, calendar, and accessibility permissions denied and then granted.
5. Exercise recording, timeline playback, archive restore/eviction, meeting
   transcription, upgrade/data migration, and update installation. Confirm no
   development directory or unbundled runtime is needed.
6. Package the stapled app, hash the final distribution artifact, generate its
   signed update manifest, and verify download/tamper/interruption behavior.

Retain the app hash, native dependency manifest, toolchain records, test results,
notary submission result, and clean-machine evidence with the release.

`check_source_tree.py` rejects generated output, personal machine paths and common
credential formats in tracked and nonignored untracked files. It is a lightweight CI check, not a complete
secret scanner. Review new dependencies, assets and any imported history before
publication.

## Optional local speech smoke test

`SilentMeetingPipelineTests` accepts an explicit 21-second synthetic MP4 and
native runtime. Its spoken fixture must mention Alex and a Friday deadline.
Generate speech with `say -o` (file output only), combine it with a 640×360,
30 fps synthetic video and pad audio to 21 seconds using ffmpeg. Verify the
speech file has nonzero duration before running the test: restricted hosts can
return an empty speech file even when synthesis exits successfully.

```sh
LIBREREVERSE_SILENT_MEETING_FIXTURE=/absolute/path/to/synthetic-meeting.mp4 \
LIBREREVERSE_TEST_WHISPER_RUNTIME=/absolute/path/to/whisper.cpp \
swift test --filter SilentMeetingPipelineTests
```

This test transcribes, persists, summarizes with the on-device system model,
and reads the result back. It neither plays nor captures audio. It requires
Apple Intelligence to be enabled and ready. The ordinary suite skips it when
these explicit test inputs are absent.

## Development capture and detection fixtures

Build fixture-enabled code explicitly with `scripts/build_app.sh --validation`.
This compiles the debug configuration into `dist/LibreReverse-Validation.app`,
marks its Info.plist as a development validation bundle, and uses the separate
`local.librereverse.validation` bundle identity. Building does not launch it or
request capture permissions. The default build remains optimized release code
with fixture environment switches disabled; signed validation builds are rejected.

Validation bundles are for explicitly invoked development fixtures and use a
separate identity. They do not establish behavior of a signed release; test the
exact release artifact before distributing it.
