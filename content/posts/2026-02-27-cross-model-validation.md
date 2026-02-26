---
title: "Cross-model validation"
date: 2026-02-27
description: "Prophet's eval suite has only ever run against one model: gemma3:1b. Running the same 109 cases against gemma3:4b reveals which capabilities are model-dependent and which are infrastructure-dependent. Of six suites, only one changes: entity-triple retrieval (extracting entity relationships for retrieval) improves from F1 0.895 to 0.976. The other five suites produce identical scores. Most of Prophet's retrieval quality comes from infrastructure — full-text search, entity extraction, preference injection (prepending preferences) — not from the model."
---

**TL;DR** — Prophet's eval suite (109 cases across 6 suites) has only ever run against gemma3:1b. Running the same suite against gemma3:4b reveals that five of six suites produce identical scores. Only entity-triple retrieval (extracting entity relationships for retrieval) improves (F1 0.895 to 0.976). Memory extraction remains at F1 0.0 on both models. The result is clear: most of Prophet's retrieval quality comes from infrastructure — full-text search, entity graphs (extracted entity networks), preference injection (prepending preferences) — not from model quality. A larger model helps entity extraction at the margin but does not move the dominant suites.

---

## The gap

Prophet's [eval suite](/posts/preference-aware-retrieval) covers six capabilities: full-text retrieval, vector search, entity-triple retrieval, classification, memory extraction, and preference-aware intent retrieval. Every run to date used gemma3:1b, a 1-billion-parameter model served locally via ollama.

A single model creates an ambiguity. When a suite scores well, the score could reflect good infrastructure (indexing, query routing, result merging) or a capable model (embedding quality, extraction accuracy). When a suite scores poorly, the bottleneck could be infrastructure design or model limitations. Without a second data point, the two explanations are indistinguishable.

## The method

The eval harness already supports a `--model` flag. A comparison requires two runs:

```
bin/eval --model gemma3:1b --trials 3
bin/eval --model gemma3:4b --trials 3 --compare
```

Each run executes 109 cases with 3 trials per case (327 trials per model, 654 total). The `--compare` flag on the second run loads the previous result file and reports per-suite deltas.

gemma3:4b is a 4-billion-parameter model from the same family. Same architecture, same training data lineage, 4x the parameters. It runs on the same hardware via ollama with no configuration changes beyond the model tag.

## Results

| Suite | gemma3:1b F1 | gemma3:4b F1 | Delta |
|-------|-------------|-------------|-------|
| retrieval-fts | 1.000 | 1.000 | 0.000 |
| retrieval-vector | 0.765 | 0.765 | 0.000 |
| retrieval-triples | 0.895 | 0.976 | +0.081 |
| classification | 0.750 | 0.750 | 0.000 |
| extraction | 0.000 | 0.000 | 0.000 |
| retrieval-intent | 0.971 | 0.971 | 0.000 |

Five of six suites are identical across models. Only retrieval-triples changes.

### Per-case flips in retrieval-triples

Four cases that failed on 1b pass on 4b:

- **correction across entry types** (0/3 → 3/3): A correction entry targeting a different entry type. The 1b model extracted entities too narrowly to bridge the type gap.
- **note type** (0/3 → 3/3): A query about a note required extracting the entity from a note-typed entry. The 1b model missed it.
- **three entries, one specific** (1/3 → 3/3): Three entries shared an entity; only one matched the query. The 4b model extracted entities with enough specificity to disambiguate.
- **dense setup specific entity** (0/3 → 2/3): Ten entries in the database, a query targeting one specific entity among many. The 4b model found a partial match (2/3 trials).

One case that passed on 1b fails on 4b:

- **very short content** (3/3 → 0/3): A three-word entry. The 4b model failed to extract a usable entity from minimal text. This is a regression — a larger model is not uniformly better.

Net: 4 gains, 1 regression, 20 unchanged.

## Interpretation

The results split Prophet's capabilities into two categories.

**Infrastructure-dependent** (model does not matter):
- *retrieval-fts* — Full-text search uses SQLite FTS5. The model is not involved. F1 1.0 on both.
- *retrieval-intent* — Preference-aware retrieval uses injection: preferences are prepended to results regardless of query. The model is not in the retrieval path. F1 0.971 on both.
- *retrieval-vector* — Vector search uses ollama embeddings, but the same 8 cases fail on both models. The failures are structural (correction chains, multi-fact queries, short entries) rather than embedding-quality issues.

**Partially model-dependent** (model matters at the margin):
- *retrieval-triples* — Entity extraction feeds an entity graph. A larger model extracts more entities and bridges more cases. But 20 of 25 cases pass on both models, so the infrastructure (graph storage, substring matching) carries most of the weight.
- *classification* — Both models score F1 0.750. The same two cases fail on both: code detection and danger detection. Classification prompts may need redesign rather than a bigger model.
- *extraction* — Both models score F1 0.0. The extraction eval requires exact structural matches (JSON keys, array shapes) from `trick`'s memory extraction pipeline. Neither model produces output that passes the strict validators. This is a pipeline problem, not a model problem — the extraction prompts and parsing logic need work regardless of model size.

## Limits

**Two models, not a sweep.** gemma3:1b and gemma3:4b are from the same family. A model from a different family (e.g., phi, llama) might produce different results. Two data points establish a direction, not a curve.

**Extraction is a floor.** Both models score F1 0.0 on extraction. This means extraction cannot distinguish between model capabilities — it is bottlenecked by the pipeline, not the model. Fixing extraction requires pipeline changes before model comparisons become meaningful.

**Three trials per case.** A case passes if it succeeds in at least 2 of 3 trials. The dense-setup case passed 2/3 on 4b but 0/3 on 1b — a fragile boundary. More trials would increase confidence in borderline cases.

**Same hardware, different latency.** The 4b model runs slower than 1b on the same machine. This comparison measures accuracy, not cost. In production, the 1b model's speed advantage matters for phases like `peep` that make dozens of classification calls per heartbeat cycle.