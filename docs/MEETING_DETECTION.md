# Meeting provider recognition

The detector recognizes native app names and bundle IDs, along with browser
host and path rules. The provider catalog includes FaceTime, Discord, Signal,
WhatsApp, Telegram, Skype, Around, Whereby,
Tuple, Pop, Tandem, Riverside, Gather, Butter, RingCentral, BlueJeans, GoTo
Meeting, Dialpad, Lifesize, Vonage, 8x8, Jitsi, Chime, Cal Video, Daily,
Livestorm, and Ping, alongside Zoom, Teams, Slack, Webex, and Google Meet.

App names are matched exactly, ignoring case; browser rules compare host boundaries and path
components. Merely opening an identified app, a landing page, or a calendar link
does not activate recording: an active-call control is required. Capture
privacy exclusions, start policies, and lifecycle handling still apply.

Control IDs include Teams `hangup-button`, Webex `callControl`, and WhatsApp
`Calling_Window`; they are scoped to their provider and reduced to a boolean
marker before leaving the Accessibility reader. Native app names and bundle
identifiers are matched independently.
Windows executable names are not used by this macOS app.

Catalog tests cover every identifier and negative admission cases. Recognition
is not a live-call certification for every client version: an app must expose
its call controls through macOS Accessibility. In particular, opaque Signal
windows may not provide sufficient evidence. Browser recognition also depends
on the browser exposing the page URL and call controls through Accessibility.

## Call evidence and lifecycle

The Accessibility reader checks live controls for every recognized browser
provider, including Zoom, Teams, and Slack. A meeting URL or
microphone use on a pre-join page does not establish a call. URL-less Meet pop-outs
retain their existing exact-title and same-process microphone checks.

Explicit leave/hang-up/end-call controls can establish a call even when muted.
An ambiguous Disconnect control additionally requires a microphone/deafen control
or an exact Discord connection status. Supporting controls alone are insufficient.
Control text must come from interactive Accessibility roles; chat text does not
count. Only canonical evidence labels leave the reader.

Native Teams and Zoom accept these explicit controls without needing a special
window title or active microphone. Existing observation confirmation, ending
grace, reentry checks, and privacy exclusions continue to govern recording.
There is deliberately no microphone-only admission for opaque messaging clients:
a voice note must not become a meeting automatically.
