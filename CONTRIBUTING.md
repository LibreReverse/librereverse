# Contributing

Use the prerequisites and build commands in README.md. Run `scripts/test.sh`
before submitting changes. Keep hardware, network, and personal-library tests
clearly separated; a skipped hardware test is not release validation.

Use small changes with a clear trigger, resulting behavior, and validation.
Keep SQL inside the core, UI work on the main actor, and background tasks under
an explicit owner. Test cancellation and replacement at feature boundaries.
Never weaken privacy defaults, recovery, or integrity checks to make a fixture
pass. Do not commit recordings, database keys, OAuth credentials, model binaries,
unlicensed assets, debug bundles, or personal library outputs.

Product tests must use synthetic data and must not read a developer's personal
library by default. Preserve source licenses when incorporating dependencies.

Contributions are provided under the project's MIT license. Document any
third-party material and its license in THIRD_PARTY_NOTICES.md.
