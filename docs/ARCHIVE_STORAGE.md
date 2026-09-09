# Cloud archive storage

Storage settings supports Google Drive and S3-compatible storage. Select a
provider, configure it, and connect. Browsing the provider picker does not change
the active archive. A successful connection switches upload, download, backup
status, and local retention controls together.

## Google Drive

Connect with Google authorization. Switching to S3 preserves the saved Drive
connection, so **Use Google Drive** can switch back without a new authorization
when the saved connection remains valid. Disconnecting Drive revokes its saved
authorization. Remote files are not deleted when switching or disconnecting.

## S3-compatible storage

Enter an HTTPS service endpoint, bucket name, signing region, access key, and
secret key. Temporary credentials can also include a session token. The endpoint
is the service URL; LibreReverse appends the bucket and object path. The default
region is `us-east-1`; use the region required by your service.

**Test & Connect S3** uploads a small probe, downloads and verifies it, then
removes it before activating the destination. Credentials are stored in the
encrypted library rather than macOS preferences. Secret fields remain blank when
reopening Settings; their placeholders explain when a saved value can be reused.

A launcher can supply `S3_URL`, `S3_BUCKET`, `S3_KEY`, and `S3_SECRET` to prefill
setup. Optional variables are `S3_REGION` and `S3_SESSION_TOKEN`. LibreReverse
reads its process environment; it does not source shell configuration files.
Never put credentials in source control or diagnostic reports.

The backend uses path-style S3 requests signed with AWS Signature Version 4.
Objects are isolated under `librereverse/libraries/<library-id>/`. Bucket
permissions must allow uploads, reads, and deletion in this namespace; deleting
the complete archive also requires listing that prefix. Large files use S3
multipart upload, including shards larger than 5 GB. Uploads normally use one
64 MiB part at a time, with larger parts for very large objects. Accepted parts
and the upload ID are saved so an interrupted transfer can resume after restart.
The backend supports objects up to 5 TiB, subject to the service's own limits.
Small uploads use a single PUT and restart from zero if interrupted.

The service assembles uploaded parts into a single object. Hydration streams
that object to a temporary file, verifies its full SHA-256, and installs it only
after verification; it does not allocate the entire shard in RAM or concatenate
separate downloaded part files. A provider's full SHA-256 checksum is verified
when available; composite multipart checksums are not treated as full-file
checksums. Otherwise LibreReverse downloads and hashes the object before
allowing local eviction. Multipart operations require permission to create,
upload, complete, and abort multipart uploads in the library namespace.
Deleting an archive also lists and aborts its unfinished multipart uploads;
normal provider switching retains them for resumption.

An isolated live integration test can exercise upload, interruption, restart,
and hydration with synthetic data. Set `LIBREREVERSE_TEST_S3_LIVE=1` and the S3
connection variables, then run `swift test --filter S3ArchiveLiveTests`.
Set `LIBREREVERSE_TEST_S3_MIB=5121` for a real file larger than 5 GiB; the default
is 9 MiB. This transfers the full fixture several times for integrity checks
and removes the test object afterward. For the isolated local memory regression,
run `LIBREREVERSE_TEST_LARGE_HASH=1 swift test --filter
ArchiveIntegrityEngineTests/testLargeFileHashUsesBoundedMemory` (as one shell
command). It hashes a sparse 5,121 MiB file and checks that peak memory growth
stays below 128 MiB. File-read buffers are released after each block, including
Foundation's autoreleased buffers on macOS.

Bucket versioning, retention, and object-lock policies remain controlled by your
S3 service. Removing an archive does not purge retained historical versions.

## Archive and complete backups

Cloud archiving moves eligible recordings and historical database shards to the
selected provider. It does not replace a complete installation backup: retain
the local catalog and matching database key as well. See [library maintenance
and recovery](MIGRATING.md) before moving or restoring an installation.

## Switching providers and local copies

Each provider retains its own upload checkpoints, verified objects, and local
retention policy. Switching waits for the previous provider's transfers and
restores to stop before activating the new one. A verification from Drive cannot
authorize deletion of a local file on behalf of S3, or vice versa.

A new S3 destination initially keeps all history on this Mac. You can choose a
shorter local retention period after checking your setup. Switching back to Drive
restores Drive's existing retention policy and uploads eligible local recordings.

Switching does not copy remote-only history between providers. History that is
only on an inactive provider becomes available again when you switch back.
Restore it locally first if you want the new provider to archive it too. Changing
the endpoint or bucket of an existing provider requires its archived content to
be local before replacing that destination's remote metadata.
