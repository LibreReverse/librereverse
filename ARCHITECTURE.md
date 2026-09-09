# Architecture

## Product boundaries

- `Sources/LibreReverseApp`: AppKit composition, permissions, capture scheduling,
  timeline UI, pinned transcript UI, settings, and background-service ownership.
- `Sources/LibreReverseCore`: canonical storage, capture/writer,
  transcription, archive transfers, timeline/search models, and pure policies.
- `Sources/CSQLCipher`: system-library bridge. All SQL remains in the core.
- `Sources/CXID`: compact identifier bridge used by persisted media.
- `Sources/CSpeech`: bridge to the packaged native microphone-processing runtime.
- `Sources/CFPNG`: native recovery-image encoder with vendored FPNG and its license.
- `Tests`: temporary synthetic libraries, pure contracts, and macOS integrations.
- `scripts`: product build, speech-runtime preparation, and validation tools.

## Capture and text processing

Window selection applies privacy exclusions before capture. ScreenCaptureKit
produces native SDR sRGB BGRA buffers, retained immutably through their consumers.
Metal compares native surfaces directly; image-only inputs use reusable conversion
surfaces, and a CPU implementation remains available when Metal is unavailable.
The video writer accepts native buffers and uses a pixel-buffer pool for image
inputs. Screenshot admission is serialized and drained before shutdown.

Accepted frames are written to recovery PNGs before database admission. A
session-owned encoder reuses native storage for eligible opaque BGRA capture
buffers; ImageIO handles other image formats and semantics. Completed staging
files are renamed into place before admission proceeds. Video and OCR completion
jointly determine when a source image can be deleted.

Vision performs full-resolution OCR on a serial utility queue. Standard mode uses
fast recognition; Additional Language Support uses accurate recognition and its
broader language set. Temporary objects drain after each queued item and each
recovered frame. Timeout and completion share a winner gate.

## Storage and ownership

A library consists of a private SQLCipher key, an always-local catalog, a
writable interval, immutable historical shards, and media. The app opens its
current schema directly. `LibraryDatabase` and `LibraryDatabaseSession` read that
native library for timeline, search, and meeting views. Recorder and OCR owners
reuse keyed write sessions, validate the key for each operation, and close their
connections before primary replacement or shutdown.
FTS ranking and exact text offsets serve different contracts; they are not
interchangeable duplicate indexes.

A media lease is acquired only for a present recording. Restoration owns no
reader lease; after installation a caller acquires and validates its protected
path before reading. Eviction stages only unleased recordings and prevents new
leases until it finishes. Durable journals reconcile interrupted publication,
archive transfer, deletion, and shard rollover. Queue compound mutations use
both canonical-path in-process serialization and a cross-process lock.

## Timeline and background work

Database navigation uses date intervals and covered-time coordinates. Display
geometry has its own frame-density axis; input maps visual distance through that
axis into dates before asking storage for a window. Missing archived timing
preserves the existing display basis instead of silently switching units.
Decorations such as stars update without resetting the cursor or geometry.
Live extension is bounded and retains a predecessor needed for stable spacing.

Media transactions carry a generation and exact item identity. Superseded
results cannot publish into a newer selection. Cached items own one video output;
readiness handles initial failure, cancellation, and timeout. A pinned transcript
retains ownership of pending audio work when the timeline is hidden.

Summary scheduling has a single task owner with an awaited shutdown boundary.
Retries are persisted in an additive product table, back off to one hour, and
are selected by eligibility time. Cancellation does not turn a job into a
provider failure. Expensive search counts use a separate connection from
interactive playback queries.

## Compatibility and changes

The app owns a LibreReverse bundle identity, support directory, preferences,
archive metadata, and export format. It acquires its installation lock before
opening the library. Database initialization runs off the main actor; cold-start
moment links and reopen requests wait until initialization completes. Shutdown
waits for active startup or recording work before releasing the lock.

Moment links use `librereverse`. Durable recovery journals protect interrupted
recording, publication, archive transfer, and library mutation. Future format
changes must define their upgrade policy and include interruption/reopen tests.

## Archive providers

`ArchiveBackend` defines upload, independent verification, download, and deletion
for both Google Drive and S3-compatible storage. Destination rows keep separate
remote identities, checkpoints, and policies; only one destination is active.
The app drains previous provider workers and retires their resolvers before
switching. Local residency remains shared truth about files on this Mac.
S3 configuration is stored in the encrypted library, and S3 requests are scoped
to that library's namespace within the configured bucket.

## Meeting microphone processing

ScreenCaptureKit keeps its native video/audio recorder. When microphone capture
is enabled, a second pair of audio-only PCM writers retains the original microphone
and system samples with their capture timestamps. These optional writers never
wait for backpressure; failure leaves the native recording usable.

Once the native movie is finalized and validated, the app releases capture
ownership so ordinary screen history can resume while audio enhancement and
publication continue. No DSP runs on the capture or UI queue.

After capture ends, the standalone WebRTC processor applies moderate noise
suppression, a high-pass filter, and digital AGC2 to 10 ms microphone frames on a
utility worker. Hardware gain, audio routing, playback volume, and ducking are
untouched. AEC3 receives the timestamp-aligned stereo system track as its echo
reference and estimates the remaining acoustic delay. A 100 ms offline reference
lookahead accommodates capture-device timestamp offsets without adding that delay
to the saved audio. Decoders retain one packet and fixed 10 ms buffers; silence
fills timestamp gaps. AEC and the extra reference decode pass are skipped when the recorded
system track is known to be silent or system audio was disabled. The processed
microphone and original system audio are mixed once to
AAC with conservative peak headroom, then muxed with the original video packets
using passthrough. A validated replacement is atomic. Completed sidecars support
idempotent recovery; interrupted capture still has the native recording as its
fallback. Waveform metadata and transcription are derived from the resulting mix.

At 48 kHz float PCM, temporary source audio uses roughly 2.1 GB/hour for mono mic
plus stereo system audio, with another 0.7 GB/hour during processing. Video muxing
briefly requires an additional movie-sized file. The entire staging directory is
removed after publication. Processing adds no background work outside meetings,
and existing archived recordings are not reprocessed.

Audio regression tests exercise reverberant echo, overlapping independent voices,
headphones, silent playback, opposite-polarity stereo, positive/negative timestamp
offsets, exact partial-frame duration, cancellation, and idempotent finalization.
Run `swift test --filter 'MeetingEchoCancellationTests|MeetingSpeechProcessingTests'`
after preparing the native speech runtime. Completion logs and staging metadata
record whether AEC ran and how long enhancement took. DSP timing is a CPU-cost
measurement, not a claim about measured battery energy.
