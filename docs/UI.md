# UI behavior and native review

LibreReverse’s main surface is a full-desktop view into recorded history. The timeline floats over the video and keeps its geometry stable across zoom levels. Replaying a moment should preserve the spatial continuity of the captured desktop.

## Visual and interaction contract

- Use native dark appearance and glass over the recorded content, with the system accessibility fallback. Keep titles, form fields, sidebars and readers visually consistent.
- Keep date/time, vertical zoom controls, the time belt, and vertical Search/menu controls in fixed regions. White guide dots span the belt; app activity uses subtly taller colored marks on the same baseline. Meeting audio uses vertical waveform samples and boundary markers. Stars point to individual saved moments.
- The cursor and app identity remain stable while scrolling and changing scale. Distinguish recorded history from the live edge and uncaptured future without resizing the control surface.
- Search is centered. Editing owns its keys; retained results remain stationary during debounce. One activation selects its exact moment. Stale searches and media work cannot reopen dismissed UI or replace a newer selection.
- Keep outgoing media visible until its replacement has drawable pixels. Meeting readers remain hidden during scrolling and settle afterward. They can be moved; a pinned reader is independent of the viewer.
- Opening Settings, Ask, Recap or setup must not restore the timeline. Only explicit history actions open it. App deactivation dismisses the transient viewer and cancels its work.
- The menu icon retains the app’s reverse-loop identity, with a clear arrowhead gap. Capture is white with a play center, pause is gray with pause bars, and meetings use integrated vertical audio bars. Avoid colored status badges.
- Show one selected archive provider in a dropdown. Keep local retention, archive size, estimated monthly storage and last backup understandable. Removing a backed-up local copy leaves its archived recording available.

## Reviewing native UI

Run `scripts/test.sh` and `scripts/test.sh integration` on a supported Mac. Use
[the surface checklist](UI_CHECKLIST.md) to review the actual app with a temporary
synthetic library. Check connected, disconnected, empty, loading and error states,
not just the default screen. Keep captures and profiles in ignored `.artifacts/`.

For tests that need a synthetic meeting, `scripts/make_meeting_av_fixture.sh
OUTPUT.mp4 8 30` creates eight seconds of generated video and audio (requires
ffmpeg). Never use personal recordings as committed fixtures.

## Acceptance and performance

Complete [all surface groups](UI_CHECKLIST.md), plus rapid typing/replacement, one-click selection, scroll through meeting boundaries, close during loading, reopen, and Settings after viewer dismissal. Regression suites cover search request ownership, player readiness, hidden-window cancellation, waveform column stability and timeline layout.

Measure quiet recording, visible idle, active scrolling and post-dismissal separately. Record elapsed time and cumulative CPU, memory, window visibility and input rate. Invalidate phases when the user changes the state. CPU percentages measure one core’s usage; WindowServer serves the whole desktop, and neither metric is a total-power estimate. Keep raw profiles and generated review assets in `.artifacts/` rather than committing them.
