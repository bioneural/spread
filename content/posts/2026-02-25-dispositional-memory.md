---
title: "Dispositional memory"
date: 2026-02-25
description: "A memory system that retrieves by semantic similarity has a structural blind spot: values and preferences only surface when the query topic matches. Dispositional injection — always surfacing active preferences regardless of query — closes the gap. An evaluation suite with 21 fixtures confirms the mechanism (precision-recall metric F1 = 0.971). The cognitive science term for this is prospective memory."
---

**TL;DR** — Semantic similarity retrieval cannot serve dispositional knowledge. A preference like "simplicity matters more than performance" should inform every decision, not just queries that mention simplicity. The fix is blunt: a new entry type (`preference`) with a SQL query that always surfaces active preferences regardless of query topic. A five-reviewer panel identified three bugs in the evaluation fixtures; all were fixed before results. F1 = 0.971 across 21 test cases. The one failure is a reranker (a neural scoring model) discrimination limit, not an injection failure.

---

## The structural problem

A memory system for an AI agent stores typed entries — decisions, corrections, notes, errors — and retrieves them by matching the current prompt against stored content. Three retrieval channels operate in parallel: full-text search (keyword matching), vector similarity (embedding-based semantic proximity), and entity-graph lookup (SQL joins through an extracted triples table). Results from all channels merge via [reciprocal rank fusion](/posts/reciprocal-rank-fusion) and pass through a [cross-encoder reranker](/posts/cross-encoder-reranking).

This pipeline answers a specific question: *what stored knowledge is about the same topic as this prompt?*

For factual recall, the question is correct. "What database did we choose?" retrieves the SQLite decision. "What errors occurred with ollama?" retrieves connection timeout entries. Topic-matched retrieval works when the need is topical.

Values and preferences are not topical. When the operator says "prefer simplicity over cleverness," that preference should inform the agent's reasoning about nginx configuration, Python refactoring, database schema design, and commit message structure — topics with zero keyword or semantic overlap to the word "simplicity." The preference is dispositional: it colors all reasoning, not just reasoning about the preference's subject matter.

Similarity-based retrieval structurally cannot surface dispositional knowledge. A preference about simplicity will never appear in response to a query about nginx, because no retrieval channel finds a match. The preference exists in the database. The retrieval pipeline cannot reach it.

## What cognitive science says

The distinction maps to established categories in memory research.

[Endel Tulving](https://doi.org/10.1146/annurev.ps.36.020185.000245) separated semantic memory (general knowledge, facts, concepts) from episodic memory (specific experiences bound to time and context). Factual retrieval — "what database did we choose?" — is semantic. It operates on stored propositions matched to a query.

Values operate differently. [McDaniel and Einstein](https://doi.org/10.4324/9781315801780) describe prospective memory — the retrieval of an intention at an appropriate future moment without an explicit cue. A person who intends to buy groceries on the way home does not continuously think about groceries. The intention surfaces automatically when the environmental context triggers it — passing the store, finishing work, reaching for car keys. No keyword match is involved. The intention is latent until the situation activates it.

In [spreading activation theory](https://doi.org/10.1037/0033-295X.82.6.407) (Collins and Loftus, 1975), retrieval is not a targeted lookup but a wave of activation that propagates through a network of associations. A concept activates related concepts, which activate their neighbors, and so on. A preference like "simplicity over cleverness" would maintain a baseline level of activation that subtly influences which nodes are reached during any retrieval. The preference does not wait to be queried. It participates in every retrieval.

The engineering analog of spreading activation would be a preference that modulates retrieval scores — boosting entries that align with the preference, suppressing entries that conflict. That is the sophisticated version. The first version is simpler.

## The implementation

Three changes across three repositories.

**A new entry type.** The background extractor — which processes conversation transcripts and writes memories to the store — now recognizes `preference` as a category alongside `decision`, `correction`, `error`, `reasoning`, and `note`. The extraction prompt instructs the model to identify stated values, trade-off preferences, and judgment patterns: "Prefer X over Y," "Always/never do Z," quality signals like "simplicity matters more than performance."

**A long half-life.** Each entry type decays at a different rate, following an [Ebbinghaus forgetting curve](https://en.wikipedia.org/wiki/Forgetting_curve) with retrieval-boosted reinforcement. Preferences receive a 120-day half-life — the longest of any type. Decisions decay at 90 days, corrections at 60, errors at 30, notes at 14. Values are the most durable form of knowledge.

**Dispositional injection.** After the normal retrieval pipeline completes — after keyword extraction, full-text search, vector search, RRF merge, and cross-encoder reranking — a separate SQL query runs:

```sql
SELECT id, type, content, created_at FROM entries
WHERE type = 'preference' AND superseded_by IS NULL
ORDER BY created_at DESC LIMIT 5;
```

Results are deduplicated against entries already retrieved by the normal pipeline, then appended under an "Active preferences" heading. The injection runs only when all retrieval channels are active — channel-isolated retrieval (used in per-channel evaluation) skips it to keep those measurements clean.

The mechanism is blunt. No relevance scoring. No semantic matching. If active preferences exist, they appear. Every time.

## The evaluation

Twenty-one [test fixtures](/posts/testing-always-on) across seven categories:

| Category | Count | Tests what | Requires injection? |
|----------|-------|-----------|---------------------|
| Semantic match | 3 | Preference found by keyword/vector overlap | No |
| Conceptual bridge | 3 | Preference found by vector inference only | Partially |
| Pure dispositional | 3 | Preference has zero relation to query | Yes |
| Negatives | 3 | No preferences exist; nothing spurious | No |
| Correction chains | 3 | Corrected preference supersedes original | Yes |
| Multiple preferences | 3 | Top-K selection among many | Yes |
| Discriminators | 3 | Proves injection works, not just vector | Yes |

Categories C (pure dispositional) and G (discriminators) are the critical tests. They cannot pass without dispositional injection — there is zero keyword or semantic overlap between the preference and the query. If these pass, the mechanism works.

Results: **F1 = 0.971 (precision-recall metric). Twenty of twenty-one cases passed, all with 3/3 trial unanimity.**

The one failure: discriminator G3, which stores a preference ("prefer small focused commits"), a decision ("Using PostgreSQL for analytics"), and an error ("Timeout connecting to Redis"), then queries "how should I organize imports in Python files?" The test expects the preference to appear and PostgreSQL/Redis to be absent. The preference appears correctly, but the cross-encoder reranker ([gemma3:1b](https://ollama.com/library/gemma3)) assigns nonzero relevance scores to the unrelated entries, so they survive the rerank threshold. This is a reranker discrimination limit — the small model cannot reliably exclude all irrelevant entries — not an injection failure.

## The review panel

Five reviewers examined the implementation before the evaluation ran. Three issues reached consensus across all five.

**Correction chain fixtures were broken.** The evaluation harness called `write` and `retrieve` but never called `maintain` — the subcommand that links corrections to their originals and sets `superseded_by`. Without that step, both a preference and its correction coexisted with `superseded_by IS NULL`, and the correction chain tests [passed by accident](/posts/testing-always-on). Fixed: the harness now calls `maintain` between writes and retrieve when a fixture contains correction entries.

**Preference injection ignored channel isolation.** The dispositional query ran regardless of whether an environment variable isolated a specific retrieval channel. This meant FTS-only evaluation suites would get preferences appended — a latent fragility. Fixed: injection now runs only when no channel isolation is active.

**The preference ordering created a feedback loop.** The original query sorted preferences by `last_retrieved_at DESC` — most recently accessed first. This creates a rich-get-richer effect: recently surfaced preferences keep surfacing, while equally important but less recently accessed ones rotate out. Fixed: ordering changed to `created_at DESC`.

## Limits

**Blunt injection risks habituation.** Identical content on every retrieval call is, from the downstream model's perspective, indistinguishable from boilerplate. Whether preferences suffer diminishing influence through repetition is untested.

**Five is an arbitrary limit.** The default is five preferences. An operator with twenty active preferences loses fifteen on every retrieval. Round-robin sampling or dynamic limits based on available context budget would be better — and more complex.

**A 1-billion parameter reranker limits discrimination.** The one test failure traces to [gemma3:1b](https://ollama.com/library/gemma3) assigning nonzero relevance to entries that a larger model would likely exclude. Upgrading the reranker would close this gap at the cost of latency.

**Prospective memory in humans is automatic. This mechanism is not.** Dispositional injection appends preferences to output. A true prospective memory system would modulate retrieval scores — preferences would influence which entries the pipeline surfaces, not appear as a separate section afterward. The current mechanism is closer to a sticky note on the monitor than to cognitive disposition. It works. It is not elegant.