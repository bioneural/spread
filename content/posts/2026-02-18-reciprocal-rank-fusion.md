---
title: "Reciprocal rank fusion"
date: 2026-02-18
description: "A memory module retrieves through full-text search and vector
  similarity independently. Reciprocal Rank Fusion scores entries found by
  both channels higher than entries found by one, improving precision without
  new models or training data."
---

**TL;DR** — The [previous post](/posts/beyond-distance-thresholds) surveyed techniques for improving retrieval quality beyond static distance thresholds. Reciprocal Rank Fusion was the first to build: it replaces a naive union merge with a formula that rewards entries found by multiple retrieval channels. On a 120-entry corpus with 20 test queries, mean precision@10 for direct-vocabulary queries improved from 2.7/10 to 4.8/10. The cost was eight lines of Ruby, no new models, and no training data.

---

## The merge problem

[Crib](https://github.com/bioneural/crib) is a memory module I built for a system of cooperating tools. It retrieves through three independent channels: fact triples (structured subject-predicate-object relations), FTS5 full-text search (keyword matching), and sqlite-vec vector similarity (semantic embedding distance).

Before this change, the merge strategy was union: combine results from all channels, deduplicate by entry ID, sort by creation date descending, return the top 10. This treated every entry equally regardless of how it was found. An entry returned by both FTS and vector search scored the same as one returned by only vector search. The merge discarded the signal that multiple channels agreeing on an entry is evidence of relevance.

The [survey post](/posts/beyond-distance-thresholds) identified Reciprocal Rank Fusion as the first technique to implement — it requires no new dependencies, no new models, and no training data. It uses infrastructure that already exists.

## The formula

Each entry at rank *r* in a result list receives a score of `1/(k + r + 1)`, where *k* is a smoothing constant (default 60, per [Cormack, Clarke & Buettcher 2009](https://dl.acm.org/doi/10.1145/1571941.1572114)). Ranks are 0-indexed. Scores are summed across channels.

A concrete example: an entry at rank 2 in both FTS and vector scores `1/(60+2+1) + 1/(60+2+1) = 1/63 + 1/63 = 0.0317`. An entry at rank 0 in only one channel scores `1/(60+0+1) = 1/61 = 0.0164`. The dual-channel entry wins despite neither individual rank being the highest.

The key advantage: RRF operates on ranks, not scores. FTS relevance and cosine distance live in incompatible ranges. RRF sidesteps the normalization problem by discarding the scores entirely and using only the orderings.

Fact triples are excluded from fusion. They are structured subject-predicate-object tuples, not entries — they have no entry ID to fuse on. Triples pass through separately.

To give RRF enough candidates to work with, both channels now retrieve 20 candidates each (up from 10). The fused output is capped at 10.

## The experiment

I seeded a 120-entry corpus across 10 topical clusters plus 20 noise entries on unrelated subjects (cooking, weather, geography, sports). I ran 20 test queries: 10 direct-vocabulary queries targeting specific clusters (both channels should find results), 5 paraphrase queries designed for zero keyword overlap (semantic meaning only), and 5 negative queries where nothing in the corpus is relevant.

For each query I captured the FTS and vector rankings independently, computed RRF scores, and reconstructed the old union merge. Precision@10 measures how many of the top 10 returned entries belong to the target cluster.

## Results

### Direct-vocabulary queries (Q01–Q10)

| Query | Target | FTS | Vec | Both | Union P@10 | RRF P@10 | Delta |
|-------|--------|-----|-----|------|------------|----------|-------|
| Q01 | Logging backend | 20 | 20 | 9 | 0/10 | 1/10 | +1 |
| Q02 | Embedding config | 14 | 19 | 9 | 0/10 | 6/10 | +6 |
| Q03 | Classifier tuning | 11 | 20 | 9 | 1/10 | 8/10 | +7 |
| Q04 | SQL/DB design | 5 | 20 | 2 | 0/10 | 4/10 | +4 |
| Q05 | Error handling | 20 | 20 | 9 | 0/10 | 2/10 | +2 |
| Q06 | Ruby stdlib | 12 | 20 | 6 | 0/10 | 3/10 | +3 |
| Q07 | Git workflow | 12 | 20 | 9 | 3/10 | 5/10 | +2 |
| Q08 | Test design | 14 | 6 | 6 | 7/10 | 6/10 | -1 |
| Q09 | Voice standards | 6 | 10 | 4 | 7/10 | 7/10 | 0 |
| Q10 | Logging/observability | 20 | 20 | 9 | 9/10 | 6/10 | -3 |

Mean precision improved from **2.70/10** (union) to **4.80/10** (RRF), a gain of +2.10 per query. Seven queries improved, one was unchanged, and two regressed.

### The hero example: Q03

Query: "how was the classifier prompt tuned for accuracy?" — targets cluster 3 (prompt engineering).

Under union merge, the top 10 were sorted by creation date descending, which surfaced entries from clusters 9, 8, 6, 5, and 4 before reaching a single cluster 3 entry at rank 10. Precision: 1/10.

Under RRF, entries that appeared in both FTS and vector results floated to the top. Nine of the top 10 candidates appeared in both channels, and eight of them belonged to cluster 3. The one non-cluster-3 entry in the top 10 (entry 73, a testing entry about "classifier accuracy") appeared in both channels because the word "classifier" matched the query keywords. Precision: 8/10.

The mechanism is visible in the scores. Entry 28 ("Set all classifier prompts to temperature 0.0") scored `1/66 + 1/63 = 0.0152 + 0.0159 = 0.0311` — it ranked 5th in FTS and 2nd in vector. Entry 90 ("Posts follow a consistent structure: TL;DR, setup...") ranked 11th in vector and was absent from FTS. Its RRF score was zero. Under union, entry 90 appeared at rank 1 because it had the most recent creation date. Under RRF, it vanished.

### The regressions: Q08 and Q10

Q10 ("centralized logging with severity levels and tool names") regressed from 9/10 to 6/10. All 10 target entries have high entry IDs (91–100) because logging is cluster 10, seeded last. Union's recency sort placed them at the top. RRF replaced recency with agreement, promoting entries from other clusters that happened to match on keywords like "tool" and "logging." The recency bias was accidentally helpful here.

Q08 ("end-to-end smoke test design and test isolation") regressed from 7/10 to 6/10. RRF promoted a noise entry about cricket ("Cricket test matches can last five days...") because the word "test" appeared in both the query and the entry, giving it dual-channel presence. A keyword match on a common English word is not evidence of relevance, but RRF cannot distinguish this from a genuinely informative keyword match.

### Paraphrase queries (Q11–Q15)

| Query | FTS | Vec | Union P@10 | RRF P@10 |
|-------|-----|-----|------------|----------|
| Q11 | 3 | 9 | 1/10 | 2/10 |
| Q12 | 20 | 18 | 0/10 | 4/10 |
| Q13 | 20 | 20 | 0/10 | 2/10 |
| Q14 | 20 | 20 | 0/10 | 4/10 |
| Q15 | 20 | 11 | 0/10 | 1/10 |

These queries were designed for zero keyword overlap with their target entries, so I expected FTS to return nothing. It did not. The keyword extraction strips stop words and short words but does not prevent matches on content words that happen to appear elsewhere in the corpus. "Making the small language model give reliable categorization outputs" (Q12) produces keywords like "language," "model," "reliable," and "outputs" — all of which appear in non-target entries.

Mean precision still improved from 0.20/10 (union) to 2.60/10 (RRF), because the unexpected FTS overlap created dual-channel hits on some relevant entries.

### Negative queries (Q16–Q20)

All five negative queries returned results from at least one channel. FTS matched on incidental keyword overlap (e.g., "power" and "generation" in Q16 matching corpus entries about different topics). Vector returned results under the 0.5 distance threshold for three of five queries. RRF cannot help here — it fuses what the channels return, and both channels return noise for irrelevant queries. Filtering noise from negative queries requires a different mechanism: reranking or adaptive cutoffs.

### Aggregate

| Query type | N | Mean Union P@10 | Mean RRF P@10 | Mean Delta |
|------------|---|-----------------|---------------|------------|
| Direct | 10 | 2.70/10 | 4.80/10 | +2.10 |
| Paraphrase | 5 | 0.20/10 | 2.60/10 | +2.40 |

## Implementation

The `rrf_merge` method in [crib](https://github.com/bioneural/crib) (commit [`2fe6d15`](https://github.com/bioneural/crib/commit/2fe6d15)):

```ruby
def rrf_merge(fts_entries, vector_entries, k: RRF_K, limit: RRF_LIMIT)
  scores = Hash.new(0.0)
  entry_by_id = {}

  fts_entries.each_with_index do |entry, rank|
    id = entry['id']
    scores[id] += 1.0 / (k + rank + 1)
    entry_by_id[id] = entry
  end

  vector_entries.each_with_index do |entry, rank|
    id = entry['id']
    scores[id] += 1.0 / (k + rank + 1)
    entry_by_id[id] ||= entry
  end

  sorted = scores.sort_by { |_id, score| -score }
  sorted.first(limit).map { |id, _score| entry_by_id[id] }
end
```

Integration: `rrf_merge` replaces the union in the retrieve command. When only one channel returns results, it falls back to returning that channel's top 10 directly. Triples remain separate — they pass through outside the fusion step.

## Dead ends

**k sensitivity.** I considered testing k=20, k=60, and k=100 to see if the smoothing constant matters at this scale. It does not. With candidate pools of 20, the rank range is 0–19. At k=60, the score range is 1/61 to 1/80 — a compression ratio of about 1.3:1. At k=20, it would be 1/21 to 1/40 — about 1.9:1. The difference changes individual scores but not the relative ordering of fused entries when both channels contribute similar rankings. At larger candidate pools (hundreds of entries), k would matter more.

**Including triples in RRF.** Triples are subject-predicate-object tuples, not entries. They do not have entry IDs. Joining triples back to source entries through the relations table is possible but awkward, and the signal gain is minimal — triples already serve a different function (structured facts) than the entry-level retrieval.

## Limits

**120-entry corpus.** At 10,000 entries, the candidate pools (20 per channel) might not overlap at all, reducing dual-channel hits to near zero. Alternatively, the dual-hit signal could become stronger if both channels independently surface the same entries from a much larger pool. The experiment cannot distinguish these outcomes.

**Paraphrase queries are limited.** If most real queries use vocabulary that does not overlap with stored entries, RRF's dual-channel signal is weaker. The experiment showed RRF still helped on paraphrase queries due to incidental keyword overlap, but this is not guaranteed.

**Equal channel weighting.** If vector search is systematically better than FTS for a query type, equal weights dilute the better signal with the worse one. Weighted RRF exists (multiply each channel's contribution by a coefficient) but adds a tuning parameter that requires labeled data to set correctly.

**Union's recency bias may be desirable.** Q10 demonstrated this: when the user wants recent information and the relevant entries happen to be recent, union's creation-date sort is accidentally effective. RRF replaces recency with agreement. For some query patterns, that is a downgrade.

**Noise filtering.** RRF improved which relevant entries ranked highest, but it cannot filter out noise when both channels return irrelevant results. The negative queries demonstrate this — RRF faithfully fuses garbage from both channels. A cross-encoder reranker or adaptive cutoff operates downstream of RRF and addresses this gap.

## Next

Cross-encoder reranking. The [survey](/posts/beyond-distance-thresholds) identified it as the highest-impact technique after rank fusion. The [Qwen3 0.6B reranker](https://ollama.com/library/qwen3-reranker) runs in ollama. RRF feeds better candidates into the reranker — the two techniques compose.
