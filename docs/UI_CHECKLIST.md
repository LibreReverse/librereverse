# UI review checklist

Use this checklist for every visual or interaction release. Record the tested build and evidence for each row in the pull request or local review notes. A screenshot verifies appearance only; separately exercise the relevant input, loading, cancellation and error paths. Never infer a missing feature from a missing screenshot.

Interaction expectations are in [UI.md](UI.md). This is a reusable checklist, not a claim that future builds have already passed.

| ID | Surface or state group | Required checks |
| --- | --- | --- |
| VIEW-01 | Settings shell | Sidebar selection, icon insets, shared window sizing |
| VIEW-02 | General | Login, pause reminder, Dock, permissions link |
| VIEW-03 | Screen | Excluded apps, process list, private windows, OCR and help |
| VIEW-04 | Meetings settings | Detection, manual recording, sources, device, language, calendar and help |
| VIEW-05 | AI — local | Only controls relevant to On this Mac |
| VIEW-06 | AI — remote | Profile, model, key, save/remove states and privacy help |
| VIEW-07 | AI — OpenRouter | Routing/fallback conditional controls |
| VIEW-08 | Storage — Drive disconnected | Provider chooser and connection |
| VIEW-09 | Storage — S3 disconnected/edit | All field colors, labels, secure fields, advanced session token |
| VIEW-10 | Storage — Drive connected | Backup status, last write, verified size, monthly estimate, retention |
| VIEW-11 | Storage — S3 connected | Same metrics and retention; edit connection |
| VIEW-12 | Storage — syncing/failure | Progress, retry, status contrast |
| VIEW-13 | Storage — help/confirmation | About archiving, disconnect, deletion confirmation; cancel only |
| VIEW-14 | Shortcuts | Capture, clear/reset, conflict and disabled states |
| VIEW-15 | Ask — setup | Connection hierarchy, API field, help, compact opening size |
| VIEW-16 | Ask — ready | Question, suggestions, profile context |
| VIEW-17 | Ask — answer | Response, citations, copy/new-question, narrow width |
| VIEW-18 | Ask — loading/error | Progress and actionable failure |
| VIEW-19 | Daily Recap — empty | Date navigation and empty message |
| VIEW-20 | Daily Recap — populated | Activity, meeting hierarchy, apps and websites |
| VIEW-21 | Daily Recap — agenda | Recorded/upcoming boundaries, useful actions |
| VIEW-22 | Daily Recap — calendar/menu | Anchored calendar and options |
| VIEW-23 | Meeting details — summary | Header, metadata, readable summary and actions |
| VIEW-24 | Meeting details — transcript | Tab/content hierarchy and text |
| VIEW-25 | Viewer transcript | Header, text, primary/menu actions, availability states |
| VIEW-26 | Viewer transcript — movement | Actual pointer drag, bounds clamp and resulting placement |
| VIEW-27 | Pinned transcript | Native standalone chrome, no nested card, resize |
| VIEW-28 | Meeting recording indicator | Title, elapsed time, rename and stop |
| VIEW-29 | Transcript — rename/context | Native dialogs, readable fields, cancel safely |
| VIEW-30 | Transcript — export/delete | Native save/confirmation presentation, cancel safely |
| VIEW-31 | Timeline — history | Glass, full guide, app annotations, cursor and ruler |
| VIEW-32 | Timeline — Now/future | Single centered Now marker, future-space treatment |
| VIEW-33 | Timeline — zoom | Fixed modules/selected time across close/middle/wide |
| VIEW-34 | Timeline — moving identities | Real slow-scroll sequence and segment boundary; no icon snapping |
| VIEW-35 | Timeline — stars | Exact time anchor, no collisions, click |
| VIEW-36 | Timeline — meetings | Measured waveform, quiet dots, boundaries and hover |
| VIEW-37 | Timeline — controls/menu | Both stacks, optical centering, native anchored actions |
| VIEW-38 | Timeline — calendar | Date and time picker, unavailable dates |
| VIEW-39 | Live Text | Aligned native affordance, selection and area selection |
| VIEW-40 | Archive viewer — ready | Remote-only explanation and Download action |
| VIEW-41 | Archive viewer — preparing | Loading, sizes/progress and spinner |
| VIEW-42 | Archive viewer — downloading recording | Recording download progress, ETA and narrow layout |
| VIEW-43 | Archive viewer — failure/retry | Missing-provider/retry messaging and narrow layout |
| VIEW-44 | Search — input/results | Centered composition, typography, useful match snippets |
| VIEW-45 | Search — Apps popover | Actual attachment, uniform icons, selected checks, filtering |
| VIEW-46 | Search — loading/empty/error | Readable status and actions |
| VIEW-47 | Search — result previews | OCR/meeting preview anchored to triggering result |
| VIEW-48 | Menu bar — recording/paused | Row icon and switch alignment, menu actions |
| VIEW-49 | Menu bar — meeting/disabled | Active recording and unavailable control states |
| VIEW-50 | Setup — waiting | Permission rows, actions, restrained guidance |
| VIEW-51 | Setup — ready | Completion state and all actions |
| VIEW-52 | Shared native dialogs | Application alerts/about/update errors: native controls, concise copy; safe cancellation |
| VIEW-53 | Review artifacts | Every app view assigned, current screenshots and explicit unresolved items |
