# Security and privacy

Do not include captured screen content, transcripts, keys, access tokens, or
personal database files in public reports. Prefer a minimal synthetic example,
error domain/code, app version, and macOS version. Report vulnerabilities privately through the GitHub repository’s **Security →
Report a vulnerability** action. If that action is unavailable, ask a maintainer
to enable private vulnerability reporting without posting vulnerability details
in a public issue.

The app is not a security boundary against software running as the same user.
SQLCipher protects database pages; a private local key file unlocks them. Media
and temporary transcription audio are ordinary local files. Remote AI and cloud archives
are optional and have distinct data flows described in README.md.

Recording exclusions depend on supported OS/browser behavior. Unknown recognized
browser privacy is excluded by default. Never assume that changing exclusions
removes old recordings or remote archives.

Release acceptance includes signed/notarized artifacts, verified dependency
closure, model hashes, update-manifest signatures, and tests on a clean Mac.
Development signatures do not establish production trust.
