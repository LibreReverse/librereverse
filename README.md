# LibreReverse

LibreReverse is a local macOS screen-history and meeting recorder. It captures
selected windows, indexes screen text, and provides a timeline for finding and
replaying moments. Meeting audio is transcribed locally using bundled whisper.cpp.
Optional AI profiles answer questions and summarize meetings; optional Google Drive or S3-compatible archiving restores recordings on demand.

Build, signing, notarization, and release verification are described in
[Building and releasing](docs/RELEASING.md).

## Requirements and development

- An Apple Silicon Mac with macOS 26 and Xcode 26 or newer, including command-line tools.
- SQLCipher with its pkg-config metadata (`brew install sqlcipher pkg-config`).
- Python 3.9 or newer for build verification and test utilities.
- CMake for preparing the native transcription runtime (`brew install cmake`).

```sh
scripts/test.sh unit
scripts/prepare_whisper_cpp_runtime.sh
python3 scripts/prepare_speech_runtime.py
scripts/build_app.sh
open dist/LibreReverse.app
```

`scripts/test.sh` defaults to `unit`: Python script tests and Swift tests excluding
the explicitly separated media integration cases. This tier does not require
downloaded speech runtimes or models. Runtime preparation is needed to build the
app and exercise the native speech integration tests.

Google Drive requires explicit OAuth client configuration when building; saved
authorization alone is insufficient. See [building and releasing](docs/RELEASING.md)
for the build variables, signing, and optional update configuration.

The app build requires the pinned native speech runtime and models. It never
selects a Python installation or an unverified model from the host. Release
configuration, signing, and dependency verification are described in
[RELEASING](docs/RELEASING.md). Tests using codecs, Metal, or local network
listeners require a normal macOS test host. Product tests use temporary synthetic
libraries.

## Permissions and privacy

Screen Recording permits capture. Accessibility supplies window/browser context
and global interaction. Microphone and Calendar access are used only by their
meeting features. Review capture exclusions before starting recording.

Private-window exclusion defaults on for every language. Recognized browsers
whose privacy cannot be determined are omitted; other applications must be
excluded explicitly. Browser changes and unsupported surfaces can limit privacy
detection. Exclusions apply to future capture, not previously saved material.

The library database is encrypted with SQLCipher. The local key is stored in a
private file beside the library; media files and transcription intermediates are
not independently encrypted. Protect the Mac and its backups accordingly.

The default AI profile runs on the Mac. Remote profiles send relevant text to
the selected provider for questions and automatic meeting summaries. API keys
are stored in the encrypted database. Optional Drive or S3 archiving uploads media
and encrypted database shards to the selected provider; uploaded media is not
client-side encrypted. Disconnecting does not delete remote copies.

## Library storage

The app uses the `local.librereverse` bundle identity and stores its current
library under `~/Library/Application Support/LibreReverse`. Keep the database,
matching key, and media together when making backups. Do not edit database tables
or move individual shards while the app runs.

LibreReverse opens its native schema directly. Importing another application's
data is not part of the app. Moment links use `librereverse`.

Setup opens automatically when Screen Recording or Accessibility access is
missing. Its checklist updates while you configure macOS permissions, and
recording starts as soon as both required permissions are available. Microphone
access is optional for including your voice in meetings. Setup stays open until
you dismiss it; you can return through Settings → General or the menu's
“Finish Recording Setup…” action when access is missing. If macOS asks you to quit and reopen LibreReverse after granting Screen
Recording, use “Restart LibreReverse” in setup. This restarts only the app;
you do not need to restart your Mac.

Review [library maintenance and recovery](docs/MIGRATING.md) for backup guidance.

See [ARCHITECTURE](ARCHITECTURE.md), [CONTRIBUTING](CONTRIBUTING.md),
[SECURITY](SECURITY.md), and [third-party notices](THIRD_PARTY_NOTICES.md).

See [Cloud archive storage](docs/ARCHIVE_STORAGE.md) for provider setup and switching.

See [features and settings](docs/FEATURES.md) and the [UI review checklist](docs/UI_CHECKLIST.md) when changing app surfaces.
