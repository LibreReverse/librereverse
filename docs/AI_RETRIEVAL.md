# Ask retrieval and context

Ask searches the local encrypted history, assembles cited evidence, then calls
one selected AI profile. It currently uses SQLite full-text search and calendar
rules; it is not an embedding search or an autonomous retrieval agent.

## Current behavior

- Calendar-scoped questions retrieve complete meeting transcript documents by
  interval overlap before sampling screen text. Recent OCR cannot displace those
  meetings, and the question need not repeat the meeting's spoken words.
- Topic searches still use lexical matching. Each meeting contributes one source,
  identified by segment ID, even when several search terms match it.
- A reference keeps a short preview for display and copying. Authorized model
  context contains the full redacted transcript. The sources list expands to show
  every supplied reference and retains its original citation number.
- Cloud access to full transcripts is opt-in for an exact profile route. Changing
  provider, model, preferred upstream providers, or fallback policy invalidates
  the grant. Local Apple Intelligence processing stays on the Mac.
- Small evidence sets go directly to the model. Larger sets are processed in
  source-specific chunks and reduced into question-relevant notes. Every chunk
  is visited; a reduction that cannot converge produces a narrowing error.
  Intermediate notes do not become new citations. Extraction can still lose
  nuance, so bounded processing is not a guarantee of an exhaustive answer.
- OpenRouter responses are checked for completion. An output-limit response gets
  one retry with a larger output allowance; an answer that is still incomplete
  produces an error instead of being displayed as complete.
- Budgets are conservative character limits, not exact model-specific token
  accounting. A question covering more than 100 meetings must be narrowed.

OpenRouter includes reasoning in the completion token allowance, which matters
when budgeting for reasoning models. [OpenRouter reasoning documentation](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens).

The original defect was a 420-character preview being used as the entire meeting
context. Enlarging a model's context window alone could not fix that cutoff.

## Review priorities

| Priority | Remaining improvement | Verification before shipping |
| --- | --- | --- |
| High | Apply time/source restrictions before the global lexical-search cap for screen evidence too. | Flood newer history with matching OCR; an older requested day's relevant document must remain retrievable. |
| High | Report unavailable archive shards and pending/failed transcription distinctly from a true absence of evidence. | A remote-only shard or untranscribed meeting must produce a coverage warning, not an unqualified negative answer. |
| High | Retrieve screen passages around the actual match and deduplicate by document/text identity. | A match late in a document must reach the model; two different texts in identical screen rectangles must both survive. |
| Medium | Add bounded retrieval tools: list meetings, read a whole transcript or time range, search phrases, expand neighboring passages. | Multi-step questions find a second relevant source without loading the entire library; cancellation and call limits remain enforced. |
| Medium | Evaluate local semantic embeddings combined with existing lexical search, rank fusion, and reranking. | Compare against the lexical baseline on paraphrases, exact names/numbers, cross-meeting questions, retrieval recall, latency, memory, and citation support. |
| Medium | Use provider/model token metadata and explicit output reserves. | Long multilingual evidence and long questions fit the selected model or give an actionable error. |
| Medium | Validate answer citation IDs and provide passage-level navigation. | Unknown citation numbers are caught; references seek the supporting passage rather than only the meeting start. |

A semantic index would need its own encryption, rebuild/versioning, retention,
and archive-hydration rules. It should earn that complexity in evaluations. No
new embedding service or external index is introduced by the current changes.

## Research basis

Contextual retrieval combines lexical and semantic search and can add reranking;
its published improvements are benchmark-specific, not promises for this app.
Evaluate those techniques against a representative recording corpus before
adopting them. [Anthropic: Contextual Retrieval](https://www.anthropic.com/engineering/contextual-retrieval).

A useful next architecture keeps lightweight source identifiers and lets a model
load more context when needed, with limits and clear coverage. This is the
progressive, on-demand retrieval approach described in
[Anthropic's context-engineering guidance](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
and its [newer guidance on progressive disclosure](https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models).

## Regression checks

`AskTests` checks full transcript tails, date-only discovery despite unrelated
question wording, repeated-term deduplication, redaction beyond the preview, and
preview-only behavior without consent. `LibraryDatabaseSessionTests` covers
transcript filtering before limits and interval boundaries. `AskEvidenceAnswererTests`
and `AskEvidenceAuthorizationTests` cover bounded reduction and destination-bound
grants. `AskReferencesTests` checks expansion, source numbering, scrolling,
collapse/reset, and copying all references. Test fixtures are synthetic.
