# Library maintenance and recovery

LibreReverse uses the `local.librereverse` bundle identity and stores its
installation under `~/Library/Application Support/LibreReverse`. Product startup
acquires this installation's lock and opens the current database schema.

macOS permissions belong to the LibreReverse app identity. Copying preferences
does not grant Screen Recording, Accessibility, Microphone, or Calendar access.
Review the permissions required by enabled features in Settings. Enable launch
at login in Settings if desired.

## External data

The app does not import another application's library or accept its URL schemes.
Any separately developed conversion tool must preserve the matching database
key, media relationships, and shard catalog. No such converter is included or
supported by this repository.

Moment links use `librereverse`; meeting JSON uses
`librereverse.meeting-transcript`.

## Recovery

Keep backups of the database, matching `Secrets/library-db-key`, and media
together. Never substitute a newly generated key for an existing encrypted
database. Quit the app before restoring a complete backup, and do not move or
edit individual shards while recording or archive work is active.

The app retains durable recovery for interrupted recordings, publication,
archive transfers, and library mutations. If recovery reports missing files,
corrupt data, or a mismatched key, retain the affected files and restore the
matching backup. Deleting a database or journal merely to clear an error can
lose the information needed to recover it.

Review [RELEASING.md](RELEASING.md) for build and release checks. Developer builds
and local test results do not establish signed production acceptance.
