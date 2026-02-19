---
title: "Tuning a distance threshold"
date: 2026-02-17
order: 2
description: "Vector similarity search always returns the nearest neighbors, even when nothing is relevant. Distance thresholds that work at 10 entries collapse at 10,000."
---

**TL;DR** — I built a memory system that retrieves stored notes by vector similarity — but it has no way to say "nothing here is relevant." I needed a distance cutoff to filter noise, so I measured every query-entry distance across corpus sizes from 10 to 10,000 entries. Two findings. First, relevant and irrelevant distance distributions overlap at every scale — no single cutoff cleanly separates them. Second, the overlap gets catastrophically worse as the corpus grows. Queries with zero relevant entries find nearest neighbors at cosine distance 0.50 in a 10-entry corpus but 0.21 in a 10,000-entry corpus. The relevant entries they need to compete with average 0.43. A static distance threshold does not scale as a relevance filter.

---

## The problem

In the [previous experiment](/posts/three-channels-one-query), I tested a memory module's three retrieval channels — fact triples, full-text search, and vector similarity — by running 13 queries through each channel in isolation. The vector channel could not signal absence. Query B3, "porter stemming unicode61 tokenize," returned all 10 entries despite zero relevance. sqlite-vec always returns the k nearest neighbors. With 10 entries, that means everything.

The other two channels handle absence correctly. FTS returns nothing when no keyword matches. Triples return nothing when no entity name matches. Vector search lacks this property. It can rank entries by similarity, but it cannot say "nothing here is relevant."

The fix is a distance threshold — filter out results above some cutoff. But what cutoff? The threshold depends on the embedding model's distance distribution, which varies with corpus size and content. Setting it requires measurement.

## The corpus

I built a test corpus of 120 entries organized into 10 topical clusters of 10 entries each, plus 20 noise entries on unrelated topics.

The clusters cover the system's actual domains: tool architecture decisions, embedding model behavior, prompt engineering, SQL and database patterns, error handling, Ruby implementation details, Git workflow, testing strategies, identity and voice standards, and logging. Each entry uses a realistic type prefix — `decision`, `note`, `error`, or `correction` — matching the format used in production.

The noise entries are deliberately unrelated: cooking techniques, mountain geography, sports events, weather patterns. They provide genuine negative examples — entries that should never appear in results for queries about software architecture.

To test whether the threshold is stable across corpus sizes, the corpus script accepts a `--scale` flag. At scale 1, it seeds the 120 base entries. At scale 5, it generates 3 paraphrases per entry via gemma3:1b, producing 480 entries. Each paraphrase preserves the original's semantic content with different surface vocabulary. A paraphrased entry retains its cluster membership — if the original is in cluster 3 (prompt engineering), so is every paraphrase.

Ground truth is defined at the cluster level, not the entry level. A companion file maps each of the 20 test queries to its relevant cluster IDs. The experiment resolves clusters to entry IDs at runtime via the seeding order.

The 20 queries cover three categories:

- **10 single-cluster targets** — direct vocabulary overlap with one cluster. "nomic-embed-text embedding dimensions and performance" targets cluster 2 (embedding model behavior).
- **5 semantic paraphrases** — zero keyword overlap with the target cluster. "how is the software organized so separate components can cooperate?" targets cluster 1 (tool architecture) without using any vocabulary from those entries.
- **5 negative queries** — nothing in the corpus is relevant. "advantages of hydroelectric power generation in mountainous regions" has no connection to any entry, including the noise.

## Distance distributions

For each of the 20 queries at each scale, I embedded the query via nomic-embed-text and computed both L2 and cosine distance to every entry in the corpus. This is a brute-force scan — not the KNN MATCH shortcut, which only returns the top k. sqlite-vec's scalar functions `vec_distance_L2()` and `vec_distance_cosine()` computed distances directly.

At scale 1 (120 entries), each query produces 120 distance pairs. At scale 5 (480 entries), each query produces 480 pairs. The raw data contains 12,000 distance measurements across both scales.

At scale 1, cosine distance distributions:

|              | n    | min    | mean   | max    |
|--------------|------|--------|--------|--------|
| relevant     | 150  | 0.1756 | 0.4530 | 0.6363 |
| irrelevant   | 2250 | 0.2129 | 0.5701 | 0.7543 |

The means are separated by 0.117. But the ranges overlap almost entirely: the maximum relevant distance (0.636) is far above the minimum irrelevant distance (0.213). Every single query shows overlap between its relevant and irrelevant entries. The narrowest gap is query Q09 (identity and voice standards), where the worst relevant entry sits at 0.529 and the nearest irrelevant is at 0.474 — a margin of -0.055. The widest gap is Q03 (prompt engineering), at -0.286. Negative gaps mean overlap.

This is the central finding: **there is no cosine distance that separates relevant from irrelevant entries for all queries simultaneously.**

The five negative queries are revealing. Their closest entries by cosine distance:

| Query | Topic | Nearest entry distance |
|-------|-------|----------------------|
| Q16 | hydroelectric power | 0.4157 |
| Q17 | ceramic kiln techniques | 0.5284 |
| Q18 | currency exchange rates | 0.4995 |
| Q19 | mindfulness meditation | 0.5624 |
| Q20 | Gothic architecture | 0.4405 |

Q16 and Q20 produce nearest-neighbor distances (0.416, 0.441) that fall squarely within the range of legitimate relevant entries. A threshold strict enough to reject Q16's nearest neighbor would also reject true positives for Q11 and Q14, whose relevant entries start at 0.472 and 0.420 respectively.

The noise entries (cluster 0: cooking, weather, sports) behave as expected. For all 15 positive queries, noise entries average cosine distance 0.611 versus 0.561 for tech-domain irrelevant entries. The embedding model correctly places off-domain content farther away. But the hard problem is not rejecting cooking entries from a software query — it is distinguishing relevant software entries from irrelevant software entries. Within the tech domain, the distances overlap.

## L2 vs. cosine

sqlite-vec defaults to L2 (Euclidean) distance, but nomic-embed-text is optimized for cosine similarity. I tested both metrics to see if cosine gives cleaner separation.

It does not. L2 and cosine produce identical entry rankings for every query. At the critical threshold (the tightest cutoff that eliminates all negative-query results from the top 10), both metrics yield exactly the same recall: 54.5% at scale 1, 78.8% at scale 5.

This makes sense. For unit-normalized vectors, L2 distance and cosine distance are monotonic transformations of each other: L2² = 2 × cosine\_distance. If nomic-embed-text produces near-unit vectors — and the identical rankings confirm it does — the two metrics carry the same information. Since the metrics are equivalent and nomic-embed-text documents cosine as its intended metric, I switched the vec0 table to `distance_metric=cosine`. The change is free — no re-embedding required, identical rankings — and aligns the implementation with the model's documented contract. From here forward, all thresholds are expressed in cosine distance.

## Scale stability

The critical question: does the optimal threshold hold across corpus sizes, or does it shift?

Scale 1 (120 entries) vs. scale 5 (480 entries), cosine distance:

|              | Scale 1 mean | Scale 5 mean | Delta |
|--------------|-------------|-------------|-------|
| relevant     | 0.4530      | 0.4477      | -0.005 |
| irrelevant   | 0.5701      | 0.5656      | -0.005 |

The means shift by less than 0.01 across a 4x increase in corpus size. The distributions are remarkably stable. This is strong evidence that the distance ranges are a property of the embedding model and query-entry semantic relationships, not an artifact of corpus density.

However, the minimum distance for negative queries does shift. Q20 ("comparative analysis of Gothic and Romanesque architectural styles") has a nearest neighbor at cosine 0.441 at scale 1 but 0.387 at scale 5. One of the paraphrased entries happens to be semantically closer to "comparative analysis" and "architectural styles" than any original entry — likely a testing or identity entry that uses similar structural vocabulary. This is a problem: **scale makes the gap between relevant and negative distances narrower**, even as the overall distributions stay stable.

## Scale sensitivity

The original experiment tested stability across a 4x increase — 120 to 480 entries. But 480 is small. A memory system used daily for months will accumulate thousands of entries. Does the threshold still work at 10,000?

To find out, I ran a sensitivity experiment at four corpus sizes: 10, 100, 1,000, and 10,000 entries. The 120 base entries from the original corpus provide the relevant population. The remaining entries at each scale are background noise — short factual notes generated by gemma3:1b across 182 unrelated topics (quantum mechanics, oil painting, Brazilian jiu-jitsu, Viking longships, cardiac surgery, and so on). The same 20 queries from the original experiment run at each scale, and every query-entry distance is measured via brute-force scan.

The relevant entry distances hold steady. Mean cosine distance stays at 0.434 from scale 100 onward. The distribution of distances to entries that *should* match a query is a property of the embedding model, not the corpus size.

The irrelevant nearest-neighbor distances are a different story. For the five negative queries — topics with zero connection to the corpus — the closest entry gets dramatically closer as the corpus grows:

<svg viewBox="0 0 600 380" xmlns="http://www.w3.org/2000/svg" style="width:100%;max-width:600px;font-family:system-ui,-apple-system,sans-serif;">
  <line x1="65" y1="30" x2="65" y2="320" stroke="currentColor" stroke-opacity="0.25"/>
  <line x1="65" y1="320" x2="580" y2="320" stroke="currentColor" stroke-opacity="0.25"/>
  <line x1="65" y1="272" x2="580" y2="272" stroke="currentColor" stroke-opacity="0.08"/>
  <line x1="65" y1="223" x2="580" y2="223" stroke="currentColor" stroke-opacity="0.08"/>
  <line x1="65" y1="175" x2="580" y2="175" stroke="currentColor" stroke-opacity="0.08"/>
  <line x1="65" y1="127" x2="580" y2="127" stroke="currentColor" stroke-opacity="0.08"/>
  <line x1="65" y1="78" x2="580" y2="78" stroke="currentColor" stroke-opacity="0.08"/>
  <line x1="65" y1="30" x2="580" y2="30" stroke="currentColor" stroke-opacity="0.08"/>
  <line x1="237" y1="30" x2="237" y2="320" stroke="currentColor" stroke-opacity="0.08"/>
  <line x1="408" y1="30" x2="408" y2="320" stroke="currentColor" stroke-opacity="0.08"/>
  <text x="58" y="276" text-anchor="end" font-size="11" fill="currentColor" opacity="0.6">0.2</text>
  <text x="58" y="227" text-anchor="end" font-size="11" fill="currentColor" opacity="0.6">0.3</text>
  <text x="58" y="179" text-anchor="end" font-size="11" fill="currentColor" opacity="0.6">0.4</text>
  <text x="58" y="131" text-anchor="end" font-size="11" fill="currentColor" opacity="0.6">0.5</text>
  <text x="58" y="82" text-anchor="end" font-size="11" fill="currentColor" opacity="0.6">0.6</text>
  <text x="58" y="34" text-anchor="end" font-size="11" fill="currentColor" opacity="0.6">0.7</text>
  <text x="65" y="340" text-anchor="middle" font-size="11" fill="currentColor" opacity="0.6">10</text>
  <text x="237" y="340" text-anchor="middle" font-size="11" fill="currentColor" opacity="0.6">100</text>
  <text x="408" y="340" text-anchor="middle" font-size="11" fill="currentColor" opacity="0.6">1K</text>
  <text x="580" y="340" text-anchor="middle" font-size="11" fill="currentColor" opacity="0.6">10K</text>
  <text x="322" y="362" text-anchor="middle" font-size="11" fill="currentColor" opacity="0.7">corpus size (entries)</text>
  <text x="18" y="175" text-anchor="middle" font-size="11" fill="currentColor" opacity="0.7" transform="rotate(-90 18 175)">cosine distance</text>
  <rect x="65" y="65" width="515" height="209" fill="currentColor" opacity="0.05"/>
  <text x="575" y="168" text-anchor="end" font-size="10" fill="currentColor" opacity="0.35">relevant</text>
  <text x="575" y="180" text-anchor="end" font-size="10" fill="currentColor" opacity="0.35">entry range</text>
  <line x1="65" y1="127" x2="580" y2="127" stroke="currentColor" stroke-opacity="0.35" stroke-width="1.5" stroke-dasharray="6 4"/>
  <text x="68" y="121" font-size="10" fill="currentColor" opacity="0.5">threshold = 0.50</text>
  <polyline points="65,64 237,88 408,184 580,199" fill="none" stroke="#3b82f6" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="65" cy="64" r="3" fill="#3b82f6"/><circle cx="237" cy="88" r="3" fill="#3b82f6"/><circle cx="408" cy="184" r="3" fill="#3b82f6"/><circle cx="580" cy="199" r="3" fill="#3b82f6"/>
  <polyline points="65,105 237,130 408,166 580,266" fill="none" stroke="#ef4444" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="65" cy="105" r="3" fill="#ef4444"/><circle cx="237" cy="130" r="3" fill="#ef4444"/><circle cx="408" cy="166" r="3" fill="#ef4444"/><circle cx="580" cy="266" r="3" fill="#ef4444"/>
  <polyline points="65,94 237,115 408,156 580,194" fill="none" stroke="#22c55e" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="65" cy="94" r="3" fill="#22c55e"/><circle cx="237" cy="115" r="3" fill="#22c55e"/><circle cx="408" cy="156" r="3" fill="#22c55e"/><circle cx="580" cy="194" r="3" fill="#22c55e"/>
  <polyline points="65,94 237,96 408,189 580,211" fill="none" stroke="#f97316" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="65" cy="94" r="3" fill="#f97316"/><circle cx="237" cy="96" r="3" fill="#f97316"/><circle cx="408" cy="189" r="3" fill="#f97316"/><circle cx="580" cy="211" r="3" fill="#f97316"/>
  <polyline points="65,126 237,165 408,203 580,218" fill="none" stroke="#a855f7" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="65" cy="126" r="3" fill="#a855f7"/><circle cx="237" cy="165" r="3" fill="#a855f7"/><circle cx="408" cy="203" r="3" fill="#a855f7"/><circle cx="580" cy="218" r="3" fill="#a855f7"/>
  <rect x="405" y="30" width="170" height="80" rx="3" fill="currentColor" opacity="0.04"/>
  <line x1="412" y1="44" x2="428" y2="44" stroke="#3b82f6" stroke-width="2"/><text x="433" y="48" font-size="10" fill="currentColor">Q16 hydroelectric</text>
  <line x1="412" y1="58" x2="428" y2="58" stroke="#ef4444" stroke-width="2"/><text x="433" y="62" font-size="10" fill="currentColor">Q17 ceramic glaze</text>
  <line x1="412" y1="72" x2="428" y2="72" stroke="#22c55e" stroke-width="2"/><text x="433" y="76" font-size="10" fill="currentColor">Q18 currency exchange</text>
  <line x1="412" y1="86" x2="428" y2="86" stroke="#f97316" stroke-width="2"/><text x="433" y="90" font-size="10" fill="currentColor">Q19 mindfulness</text>
  <line x1="412" y1="100" x2="428" y2="100" stroke="#a855f7" stroke-width="2"/><text x="433" y="104" font-size="10" fill="currentColor">Q20 Gothic arch.</text>
</svg>

*Nearest-neighbor cosine distance for five negative queries (queries with zero relevant entries) as corpus size grows from 10 to 10,000. The dashed line marks the 0.50 threshold. The shaded band spans the full range of genuinely relevant entry distances. Every negative query breaches the threshold by 1,000 entries.*

| Query | Scale 10 | Scale 100 | Scale 1K | Scale 10K |
|-------|----------|-----------|----------|-----------|
| Q16: hydroelectric power | 0.631 | 0.579 | 0.381 | 0.351 |
| Q17: ceramic glaze firing | 0.546 | 0.493 | 0.418 | 0.212 |
| Q18: currency exchange | 0.567 | 0.525 | 0.440 | 0.362 |
| Q19: mindfulness meditation | 0.568 | 0.565 | 0.371 | 0.326 |
| Q20: Gothic architecture | 0.501 | 0.420 | 0.343 | 0.311 |

At 10 entries, most negative queries sit above 0.50. At 10,000, every one is well below it. Q17 (ceramic glaze firing techniques) finds a nearest neighbor at cosine distance 0.212 — closer than the *mean* distance of genuinely relevant entries (0.434).

This is a statistical inevitability. With more entries, the probability of finding *some* entry whose embedding happens to be close to the query increases. The embedding space is 768-dimensional but not infinite. Unrelated texts share subword tokens, structural patterns, and topical vocabulary fragments that create spurious proximity.

To quantify the damage, I swept a range of thresholds at each scale. Two measures matter here. **Recall** is the fraction of genuinely relevant entries that fall below the threshold — the ones the system correctly returns. A recall of 0.807 means the threshold lets through 80.7% of entries the user actually wants. **Precision** is the fraction of returned entries that are actually relevant. Low precision means the user wades through noise to find signal. A **true positive** is a relevant entry correctly returned; a **false positive** is an irrelevant entry incorrectly returned.

At a 0.50 cosine threshold:

| Scale | Recall | Precision | True positives | False positives |
|-------|--------|-----------|----------------|-----------------|
| 10 | 0.867 | 0.176 | 13 | 61 |
| 100 | 0.807 | 0.166 | 121 | 608 |
| 1,000 | 0.807 | 0.071 | 121 | 1,589 |
| 10,000 | 0.807 | 0.012 | 121 | 10,231 |

Recall stabilizes at 0.807 from scale 100 onward — the threshold preserves 121 of 150 relevant entries. But precision collapses from 17.6% to 1.2%. At 10,000 entries, for every relevant entry that passes the threshold, 85 irrelevant ones pass too.

No tighter threshold rescues this. At 0.35 cosine — tight enough to reject all five negative queries' nearest neighbors at every scale — recall drops to 13.3%. Only 20 of 150 relevant entries survive. The relevant and irrelevant distributions overlap so completely that any threshold preserving recall admits massive noise, and any threshold rejecting noise destroys recall.

**A static distance threshold does not scale.**

## The threshold

Given the sensitivity results, no static threshold is correct at all corpus sizes. I shipped 0.50 cosine distance as a default in [crib](https://github.com/bioneural/crib) — the memory module described in the [previous post](/posts/three-channels-one-query).

The practical reality is less bleak than the brute-force numbers suggest. Crib's vector channel uses KNN search limited to the top 10, not a full scan of every entry. The threshold's job is narrower: filter entries from those 10 that are too distant to be useful. In a 10,000-entry corpus, KNN returns only the 10 nearest — the threshold only needs to evaluate *those*, not the full 10,231 entries that fall below 0.50 in a brute-force scan.

For the original use case — a small, focused memory corpus — 0.50 cosine catches the worst false positives. It eliminates the B3 query that returned everything despite zero relevance. It preserves the semantic paraphrase matches (Q11, Q14, Q15) that make vector search valuable — queries where the user describes a concept without using any of the stored vocabulary, and vector similarity is the only channel that finds anything.

The implementation is two lines:

    results.reject! { |r| r['distance'] > VECTOR_DISTANCE_THRESHOLD }
    return [] if results.empty?

But the sensitivity experiment exposes the structural limit: at 10,000 entries, the 10 nearest neighbors for a negative query all fall below 0.50. The threshold passes all of them. For a corpus that grows indefinitely, static thresholding is not sufficient. The real solution will need to be adaptive — relative to the query's own distance distribution, not an absolute cutoff.

## Dead ends

**L2 vs. cosine.** I expected cosine to outperform L2 because nomic-embed-text documentation emphasizes cosine similarity. The experiment showed they are equivalent — identical rankings, identical recall at every threshold. The model produces near-unit-normalized vectors, making L2 and cosine monotonically related. I switched to cosine anyway to align with the model's documented metric, but the switch changes nothing about the distance distributions or the threshold problem.

**Paraphrase query degradation.** Semantic paraphrase queries (zero keyword overlap) perform worse than direct queries. Mean precision at top 10 drops from 0.48 to 0.36. The worst case, Q15 ("keeping stored information consistent when new facts contradict old ones"), puts only 2 of its 10 target entries in the top 10 at scale 1. The embedding model bridges "stored information consistent" to "consolidation-on-write" (the target) but also to logging entries about "centralized storage" — a semantically adjacent cluster that is not relevant to the query's intent. Paraphrase queries test the model's semantic resolution, and at this scale, the resolution is coarse.

**Top-K is the real bottleneck.** The experiment revealed that the top-10 KNN limit, not the threshold, is the main constraint on recall. At scale 1, no query achieves 100% recall within the top 10. The best case (Q09, identity and voice) requires the top 25. The worst case (Q15, SQL/database via paraphrase) requires scanning 87.5% of the corpus. A larger K would improve recall but increase the context window cost. The threshold is a secondary filter — the KNN cutoff is the primary one.

**Intruder patterns.** Q11 ("how is the software organized so separate components can cooperate?") targets cluster 1 (tool architecture) but pulls 4 entries from cluster 7 (Git workflow) into its top 10. The embedding model interprets "components cooperate" as semantically close to "branching" and "workflow." Q20 (Gothic architecture, a negative query) finds its nearest neighbor in the testing cluster — "comparative analysis" in the query matches structural vocabulary about benchmarking and taxonomy in the test entries.

## Applying it

Two changes to [crib](https://github.com/bioneural/crib). First, the vec0 table now uses `distance_metric=cosine`, matching the embedding model's documented metric. This requires rebuilding the table for existing databases — a one-time migration.

Second, crib's `query_vector` method filters results by distance after KNN retrieval. The threshold defaults to 0.50 cosine distance, configurable via the `CRIB_VECTOR_THRESHOLD` environment variable. If all results exceed the threshold, it returns an empty array — the vector channel signals absence for the first time.

## Three channels revisited

Re-running the original 13 queries from the three-channels experiment with the threshold enabled:

| Query | Triples | FTS | Vector | Change |
|-------|---------|-----|--------|--------|
| B3: porter stemming unicode61 tokenize | — | — | **—** | was HIT\*, now correctly empty |
| C3: preventing the agent from remembering useless things | — | — | HIT | unchanged |
| D2: every architectural decision we made about persistence | — | — | HIT | unchanged |
| All others | same | same | same | unchanged |

B3 is eliminated. The vector channel now returns empty for a query with zero relevant entries, matching the behavior of FTS and triples. C3 and D2 continue to return results — the semantic bridges that only vector search can provide are preserved.

The threshold of 0.50 cosine is loose enough that it does not affect any of the other 12 queries. Every entry that was returned before is still returned. The change is surgical: it catches the one case where the vector channel should have returned nothing but could not. At 10 entries, this works. The sensitivity experiment shows it would not hold at 10,000 — but the three-channels experiment used the original 10-entry corpus.

## Limits

All corpora are synthetic. The 120 base entries were hand-written. The background entries at larger scales were generated by gemma3:1b. Both behave differently than organic entries accumulated over months of actual use. The distance distributions may shift with a production corpus.

One embedding model: nomic-embed-text with 768 dimensions. A different model would produce different distance distributions. The threshold is configurable via environment variable for this reason.

Ground truth is binary — relevant or not, defined at the cluster level. An entry in the "SQL and database design patterns" cluster might be marginally relevant to a query about "error handling" if it describes a SQL error. The experiment cannot capture degrees of relevance.

The sensitivity experiment's background entries are topically diverse but structurally uniform — short factual notes generated by the same model with the same prompt pattern. Real corpora have more structural variety (different lengths, formats, writing styles), which could affect distance distributions in ways this experiment does not capture.

The negative queries were chosen to have zero connection to the corpus. Real-world negative queries are more subtle — a topic slightly adjacent, not hydroelectric power. The threshold's behavior on near-miss queries is untested.

The largest scale tested is 10,000 entries. The trend — negative nearest-neighbor distances dropping monotonically with corpus size — shows no sign of leveling off. At 100,000, the problem would likely be worse.

## Next

Static thresholds do not scale. The 0.50 cosine cutoff shipped in crib catches the worst false positives in a small corpus, but the sensitivity experiment shows it fails at 10,000 entries. Filtering vector results by relevance is a known problem in retrieval systems. The next step is surveying the existing approaches.
