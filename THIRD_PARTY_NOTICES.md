# Third-party materials

The project MIT license covers contributor-authored project code; it does not
replace dependency licenses. Release packaging must include the licenses for
the exact artifacts it distributes.

| Material | Use | Release requirement |
| --- | --- | --- |
| SQLCipher | Encrypted SQLite storage | [BSD notice](licenses/SQLCipher.txt); exact native inputs are recorded in `release/release-inputs.json`. |
| OpenSSL | SQLCipher cryptographic dependency | [Apache 2.0 license](licenses/OpenSSL.txt); exact native inputs are recorded in the release lock. |
| whisper.cpp | Local speech inference | Pinned source commit; include upstream LICENSE. |
| Whisper model weights | Speech model | [MIT license](licenses/Whisper-model.txt); verify the configured model SHA-256. |
| Silero VAD model | Speech segmentation | [MIT license](licenses/Silero-VAD.txt); verify the configured model SHA-256. |
| App artwork | Product icon | Generated with GPT, as reported by the project owner; included under the repository MIT license. |
| Apple system frameworks | Capture, playback, OCR, local AI | Supplied by supported macOS; not redistributed. |

The icon generation model/version and original prompt were not retained in this
repository. Dependency notices remain separate from the project MIT license.
When updating dependencies, review their notices along with their pinned inputs.

## FPNG recovery-image encoder

LibreReverse vendors FPNG 1.0.6 by Richard Geldreich, Jr., from
https://github.com/richgel999/fpng at commit
`925796543b9d26b8edfcdcecd94c1dac280f29fc`.
The upstream files are public-domain software distributed under the Unlicense;
the app bundles `Sources/CFPNG/vendor/UNLICENSE` as
`Contents/Resources/FPNG_LICENSE.txt` in every build.
Source hashes and wrapper/build distinctions are recorded in
`Sources/CFPNG/vendor/PROVENANCE.md`. FPNG is statically compiled into the app;
it does not require libdeflate or a Homebrew runtime dependency.

### FPNG Unlicense

This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <http://unlicense.org/>

Richard Geldreich, Jr.
12/30/2021

## WebRTC microphone processing

The app bundles standalone webrtc-audio-processing 2.1 from the
[freedesktop release mirror](https://gstreamer.freedesktop.org/src/mirror/webrtc-audio-processing/),
with Abseil 20240722.0. WebRTC and the extraction use BSD licenses; Abseil uses
Apache 2.0. `scripts/prepare_speech_runtime.py` verifies the source archive;
the upstream Meson wrap pins and verifies Abseil and its build definitions.
The narrow project-authored C ABI statically links these into
`libLibreReverseSpeech.dylib`. Every app bundle includes the upstream notices,
WebRTC patent grant, Abseil license, and build provenance in
`Contents/Resources/Speech`. Neither WebRTC networking nor audio-device control
is used by this integration.

## XID identifiers

The XID implementation derives from an adaptation of the algorithm identified
in the original development notes as `uatuko/swift-xid`. The upstream project
is MIT-licensed, copyright 2022 Uditha Atukorala; its full notice is preserved in
[licenses/Swift-XID.txt](licenses/Swift-XID.txt). LibreReverse uses its own API and
C atomic-counter wrapper; this is not an unmodified upstream source copy.

## Development provenance

LibreReverse began with a study of Rewind's behavior. Early implementations
used behavioral observations and binary analysis to reconstruct compatibility
contracts. A fresh public Git history does not change that development origin.
The repository MIT license covers contributor-authored code and does not replace
third-party licenses. Dependency and artwork provenance is recorded above and
in [licenses/README.md](licenses/README.md).
