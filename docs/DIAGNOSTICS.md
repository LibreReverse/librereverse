# Diagnostics

Release builds ignore UI-fixture and developer-probe environment variables.
They cannot redirect the library through `LIBREREVERSE_SETTINGS_FIXTURE_ROOT`,
skip permission startup through `LIBREREVERSE_UI_TEST`, or bypass normal shutdown
through a fixture flag. Debug builds retain explicit fixture support for tests.
The supported microphone-device, speech language/model/device, and archive
no-eviction configuration overrides remain available.

Timeline diagnostics require an explicit output directory and one or both flags:

```sh
export LIBREREVERSE_DIAGNOSTICS_DIRECTORY="$HOME/Library/Logs/LibreReverse"
export LIBREREVERSE_TIMELINE_TRACE=1
export LIBREREVERSE_BOUNDARY_TRACE=1
```

Supply these variables to the app process at launch. There are no temporary-file
sentinels. Diagnostics produce `timeline.log` and `boundary.log` in the selected
directory; each file is replaced at launch and capped at 1 MiB. Files use private
permissions and symlink destinations are rejected.

These logs contain allowlisted event categories and elapsed timing only. Search
queries, meeting titles, recorded dates, paths, URLs, and free-form errors are
not written. Disable the flags and relaunch to stop tracing.
