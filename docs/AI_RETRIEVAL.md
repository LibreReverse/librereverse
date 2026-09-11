# Ask retrieval and context

Ask searches encrypted local history, gathers cited evidence, and calls the selected
AI profile. Search remains lexical. A bounded planning step can request more local
evidence; it cannot run commands, change recordings, download archives, or choose
another AI destination.

AI profiles and API keys are configured only in **Settings → AI**. Ask links to that
section when setup is needed and refreshes its configuration when it regains focus;
it has no separate key-entry or disconnect action.

## Conversations

The AI toggle in timeline search presents a scrollable conversation with a composer
at the bottom, inside the main viewer. Each answer
keeps its own references, coverage disclosure, and copy actions. **New chat** clears
conversation context. Completed conversations are saved in the encrypted primary
library catalog and can be reopened from **Saved chats**. Saved records contain
questions, answers, reference metadata and resolved search scope, never duplicate
full transcript documents. They survive primary catalog rollover. They are local
to this installation: recording shard uploads do not include chat records.

Follow-ups carry bounded prior questions and answers as conversational context,
never as cited evidence. At most six prior turns and 24 KB of conversation context
are supplied, reduced further for the selected model’s input capacity. Source content is retrieved separately under the current
profile's consent. The resolved time scope survives follow-ups; an explicit new
time range takes precedence. Explicit references to “this moment”, “on screen”,
“here”, or “around this time” use a ten-minute window centered on the viewed
timeline position for a new conversation; no screenshot is sent to the model. Formatting and copying do not change the original
answer used for context or its citation identities.

## Retrieval

- Time and source predicates apply in SQL **before** each result cap for both OCR
  and transcripts. Relevant local shards are searched without hydrating remote
  payloads. Meetings overlapping a time window are included even when they start
  before that window.
- Date-scoped questions include complete meeting documents. Questions explicitly
  about meetings, interviews, or spoken discussions use transcript evidence unless
  the question also asks about screen/document evidence. This prevents unrelated
  OCR matches from crowding a meeting answer. Unqualified “last meeting” uses the newest meeting's identity, including
  when other meetings overlap. Qualified questions such as “last meeting with Acme”
  use topic retrieval instead of silently choosing the newest unrelated meeting.
- OCR evidence is centered on matching terms, including matches in secondary text.
  Distinct passages are preserved even when their screen rectangles are identical.
  Repeated identical evidence passages within one segment share one reference.
  Screen evidence is ranked by query-term coverage and recency; explicitly requested
  follow-up sources receive priority.
- For meeting questions, open-ended questions, empty searches, and comparison/connection questions,
  supporting providers can request `listMeetings`, `search`, `read`, and `expand`.
  The planner sees redacted catalogue previews and actual results from reads.
  Authorized full transcripts remain available between rounds when they fit; partial
  observations are explicitly labeled. It can read a whole selected
  transcript or a timed word range, search another phrase, or expand up to 90 seconds
  around a source. All reads and searches retain the original date scope.
- Planning is limited to two rounds of four operations. IDs must refer to listed
  local sources, query length and time ranges are checked, repeated operations are
  suppressed, and cancellation is checked around every provider call and operation.
  The catalogue contains at most 40 meetings; each planning request shows at most
  16 source previews, further reduced when the provider budget requires it.
- Final context includes at most 100 meeting sources and 12 screen sources. Excess
  meeting context requires a narrower question. Other retrieval limits are disclosed
  instead of implying that every historical moment was searched.

## Coverage and references

Unavailable archive periods, queued/retrying transcription, and meetings without a
local transcript appear behind a collapsed **Search coverage** disclosure. They are
not prepended to the answer. A separate **Search activity** trail shows actual
retrieval actions while a request runs: finding meetings, reading transcripts,
searching follow-ups, and writing the answer. It does not display private model
reasoning or pretend to train the model between questions. Running requests show
total and current-step elapsed time with a Cancel action. OpenRouter streams
processing and answer-length counters, so incoming provider activity is visible
without exposing reasoning content. Frequent counters do not reset the step clock
or fill the activity log. An empty local search with
coverage gaps produces an actionable explanation, not an unqualified claim that
nothing happened. Coverage metadata does not prove that a remote transcript exists.
Download archived periods through the timeline's existing download workflow.

The sources list expands to show all supplied references. References keep short
previews for display and copying; authorized model context contains full redacted
transcripts. Transcript links seek near the matching passage when persisted word
timing is available, otherwise they open the meeting normally. No approximate
character-to-time conversion is used. Unknown numeric citation IDs, including grouped
or ranged citations, reject the response. Valid IDs establish source identity, not
proof that every generated claim is supported.

## Context and provider boundaries

Full cloud transcript access remains opt-in for the exact profile route. Changing
provider, model, preferred upstream providers, or fallback policy invalidates that
grant. Planning does not bypass it. Apple Intelligence processing stays local.

OpenRouter fetches only public model endpoint capacity metadata, with no API key,
question, or history in that request. The in-memory cache expires after one hour
(five minutes on lookup failure). Budgets use the minimum capacity across eligible
routes, reserve output and prompt space, and conservatively count UTF-8 bytes to
avoid assuming English token density for multilingual input. OpenAI uses a conservative
fallback envelope because this integration has no model-capacity discovery API;
local generation uses its own smaller envelope. Byte estimates are upper bounds,
not exact tokenizer counts, so reduction can happen earlier than strictly necessary.

Small evidence sets go directly to the model. Larger sets are processed in
source-specific chunks and reduced into question-relevant notes. Every chunk is
visited; processing is limited to four reduction rounds and 128 intermediate calls,
and must shrink each round or fail with a narrowing message. Extraction can lose
nuance, so this is not a guarantee of an exhaustive answer.

OpenRouter checks completion and retries output-limit responses once within the
model's output allowance. Public model capability metadata is also used to request
low (or minimal) reasoning effort only when the model explicitly supports it. This
leaves more of the output envelope for the answer; it is not a hard token allocation.
Unknown capabilities preserve provider defaults. Profile selection, routing and
transcript permission do not change. OpenAI rejects incomplete, errored, and refused responses.
Partial answers are not displayed as completed answers.

## Semantic retrieval evaluation

The [local semantic evaluation](AI_SEMANTIC_EVALUATION.md) is complete and reproducible.
Rank fusion improved recall on the small synthetic corpus, but exact-number precision
and worst-case latency did not justify automatic production adoption. The harness and
helper remain test-only. No embedding index, download, or new external service is
introduced. A future index must first pass a broader independent corpus and account
for encryption, archive hydration, retention, and index versioning.

## Verification checklist

- SQL-before-limit: hundreds of newer OCR matches cannot hide an older scoped result.
- Identity: different text in equal rectangles survives; local shard results merge.
- Coverage: remote-only periods and pending/failed/missing/empty-complete transcripts differ.
- Retrieval: follow-up search discovers a second source with different words, invalid
  requests are rejected, latest-meeting scope is precise, and cancellation stops planning.
- Context: multilingual tails survive bounded reduction, routed limits are respected,
  metadata requests contain no credentials, and incomplete responses fail clearly.
- Citations: full transcript redaction, short previews, expansion, ID validation,
  and persisted-word passage navigation have synthetic regression coverage.
- Quality: a meeting question with distracting OCR still receives the complete
  transcript including its tail. Question-list requests ask for all relevant questions
  and follow-ups, not a selective summary. Coverage stays out of answer text.
- Activity: live actions and collapsed coverage reset per answer; late callbacks
  cannot overwrite a completed or replaced request.

The original defect used a 420-character preview as the whole meeting context.
A larger model alone could not repair that retrieval loss.

## Research basis

[Anthropic's contextual retrieval research](https://www.anthropic.com/engineering/contextual-retrieval)
motivated measuring lexical/semantic fusion rather than assuming it improves this app.
[Context-engineering guidance](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
supports the bounded, on-demand source expansion design.
[OpenRouter's reasoning-token documentation](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)
explains why output reserves must accommodate reasoning as well as visible answers.
