# Local semantic retrieval evaluation

Decision: evaluation completed; **do not enable this experiment in production**.
There are measurable synthetic recall gains, but quality and interactive latency
are not sufficient evidence for adoption. The helper lives only in test support.
Ask has no embedding path, new model download, persistent index, or external
embedding service as a result of this experiment.

## Method

The already-installed Apple NaturalLanguage English sentence embedding was
available on the evaluation Mac: revision 1, 512 dimensions, macOS 26.6.2 on
Apple Silicon. Accessing the model inside a restricted process returned nil;
access outside that sandbox succeeded. The experiment never calls a download API.
Availability on this machine does not establish availability in every app sandbox
or on every supported installation.

The corpus is 18 invented meeting excerpts and 12 fixed questions: five
paraphrases, two exact names, two near-identical budget numbers, one cross-meeting
question requiring two sources, one causal/negation question, and one invoice
question. All data is public synthetic text in the evaluation harness and tests.

The lexical baseline is an **exact-token OR, newest-first proxy**, not an execution
of SQLite FTS or the complete Ask pipeline. Fixture order determines recency.
It omits stemming, SQLite tokenization, time filters, query expansion, and model
answer generation. These figures must not be presented as measured production
retrieval improvements. Semantic discovery sees all 18 documents; a reranker
restricted to the lexical result set cannot discover a missing paraphrase source.

Each candidate contributes the maximum cosine similarity of up to four
1,000-character chunks from its first 4,000 characters. The question is bounded
to 1,000 characters. Reciprocal rank fusion adds `1/(60 + rank)` from each
available lexical/semantic ranking. Exact text is not modified; result IDs map
back to original evidence. Vector failures return nil for caller fallback, never
silently remove a lexical source. Duplicate IDs and more than 100 candidates
are rejected. The only retained model is the local embedding object; candidate
text/vectors are not indexed or cached between requests.

## Measured results

One standalone, unoptimized `swiftc` executable run, excluding compilation:

| Method | Mean recall@3 over 12 questions | Paraphrases recovered in top 3 | Cross-meeting supporting sources in top 3 |
| --- | ---: | ---: | ---: |
| Lexical proxy | 58.3% | 0/5 | 2/2 |
| Semantic only | 79.2% | 3/5 | 1/2 |
| Rank fusion | 83.3% | 3/5 | 2/2 |

Recall is the fraction of labeled supporting documents present in the first
three results, averaged per question. This measures source retrieval, not answer
correctness or whether a model actually cites the supporting passage.

The names Sofia/Sonia were ranked correctly first by fusion. The question about
48172 dollars still ranked the wrong 48127-dollar source first. Both number
questions had their supporting source in the first three results; this is a
precision weakness, **not a measured recall regression against this baseline**.
The privacy paraphrase and hiring/backlog paraphrase failed. One delayed-release
question ranked a different successful release above the relevant delayed one.
A similarity score is not evidence that a statement supports the answer.

- Local model acquisition probe: approximately 52 ms (not a guaranteed cold load).
- Twelve 18-document query evaluations: 1.27 s total, about 95–171 ms per query.
- Process peak resident memory after those queries: 44,990,464 bytes.
- Worst configured text workload, 100 candidates × 4,000 characters: 19.54 s.
- Process peak resident memory after that workload: 67,158,016 bytes.

Peak RSS covers the entire process and model, not incremental vector allocation.
The bounds workload repeats synthetic text to exercise all chunks; it is a
throughput probe, not an independent quality corpus. These are single-run local
measurements, not latency percentiles or device-wide guarantees. Compilation,
application startup, database access, archive hydration, and answer generation
are excluded. No hard timing assertion is used in tests.

## Reproduction and tests

`SemanticRerankerTests` runs deterministic injected-vector tests by default:
fusion/identity preservation, missing and invalid vector fallback, candidate and
character limits, duplicate IDs, and cancellation. The local-model evaluation
is opt-in; absent assets cause a skip rather than a download:

```sh
LIBREREVERSE_RUN_SEMANTIC_EVALUATION=1 swift test --filter SemanticRerankerTests
```

The standalone harness reproduces the per-question ranks, memory figures, and
100-candidate workload:

```sh
swiftc Tests/LibreReverseAppTests/Support/LibreReverseSemanticReranker.swift \
  docs/evaluations/semantic-evaluation.swift -o /tmp/librereverse-semantic-evaluation
/tmp/librereverse-semantic-evaluation
```

Raw results for the reported run are in `evaluations/semantic-results.txt`.
The test helper is experimental code and has no production callers.

## Requirements before reconsideration

Use a larger, independently authored corpus with predeclared relevance labels;
compare to the actual filtered lexical pipeline and its query expansion, include
multilingual text, long transcript tails, absent evidence, and confusing names,
numbers, dates, and negation. Measure recall and precision at the evidence budget,
citation support, and latency across representative supported hardware. Establish
an interactive latency budget before tuning; 19.54 seconds is not acceptable for
this bounded stage. Candidate discovery must preserve time/source restrictions
and avoid claiming that a 4,000-character preview covers an entire meeting.
Any persistent semantic index would separately require encryption, deletion,
versioning, and archive hydration rules; this experiment does not implement one.
