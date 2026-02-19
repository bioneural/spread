---
title: "Beyond distance thresholds"
date: 2026-02-18
order: 1
description: "A static distance cutoff cannot distinguish relevant from irrelevant vector search results at scale. The retrieval community has known this for years. Here is what they built instead."
---

**TL;DR** — In the [previous post](/posts/tuning-a-distance-threshold), I showed that a fixed cosine distance threshold collapses as corpus size grows — queries with zero relevant entries find nearest neighbors at distance 0.21 in a 10,000-entry corpus, well inside the range of genuinely relevant results. This is a known problem. The retrieval community's answer is not a better threshold. It is layering additional signals: cross-encoder reranking, adaptive per-query cutoffs, hybrid retrieval fusion, and learned relevance classifiers. This post surveys these approaches and evaluates which ones fit a small local system running ollama and sqlite-vec.

---

## The problem, restated

Vector similarity search always returns the k nearest neighbors. Every vector in the corpus "matches" the query vector — there is no concept of a non-match. This is unlike keyword search, where non-matching documents simply do not appear.

A static distance threshold attempts to impose a relevance floor: ignore results beyond some cutoff. The [previous experiment](/posts/tuning-a-distance-threshold) showed this does not scale. As the corpus grows, the probability of some entry being coincidentally close to any given query approaches certainty. The threshold becomes useless.

This is not a novel observation. Elasticsearch has an [open issue](https://github.com/elastic/elasticsearch/issues/99416) describing the same problem: "all vectors 'match' the query vector." Pinecone's community has a [long-standing feature request](https://community.pinecone.io/t/similarity-search-with-score-cutoff/5822) for score cutoffs, acknowledging the gap. The industry's response is not to find a better threshold. It is to layer additional signals that a single distance metric cannot provide.

## Cross-encoder reranking

This is the single most recommended technique across the retrieval community. The pattern is a two-stage pipeline.

**Stage 1** (fast, broad): a bi-encoder retrieves the top 50–100 candidates via vector search — a k-nearest-neighbors query against precomputed embeddings stored in something like sqlite-vec, Faiss, or a managed vector database. The bi-encoder encodes query and document independently into separate vectors, then compares them by distance. It is fast because the document vectors are precomputed — only the query needs embedding at query time.

**Stage 2** (accurate, narrow): a cross-encoder rescores each candidate. Unlike a bi-encoder, a cross-encoder processes the query and document *together* through a single transformer pass. It sees both texts at once and can attend across them — the word "bridge" in the query can interact directly with "connection" in the document. This produces a relevance score that is far more accurate than vector distance, but far slower, because every candidate requires a full forward pass.

The two-stage design resolves the speed-accuracy tradeoff. The bi-encoder does the cheap filtering (10,000 entries down to 50). The cross-encoder does the expensive scoring (50 candidates, not 10,000).

Cross-encoder relevance scores are better calibrated than bi-encoder distances. A cross-encoder trained on relevance judgments outputs something closer to a probability of relevance, not a geometric distance in embedding space. This means a threshold on cross-encoder scores is more meaningful than a threshold on cosine distance — though the threshold problem does not vanish entirely.

**Available models (as of early 2026):**

- `cross-encoder/ms-marco-MiniLM-L-12-v2` — fast, general purpose, via sentence-transformers
- `BAAI/bge-reranker-v2-m3` — multilingual, strong accuracy
- `qwen3-reranker:0.6b` — available directly in ollama, compact enough for local use

The last option is directly relevant. A 0.6B parameter reranker running in ollama can rescore 50 candidates locally without external API calls. Multiple RAG guides describe cross-encoder reranking as "the optimization with the best effort-to-impact ratio."

## Adaptive cutoffs

Instead of a fixed threshold, detect the natural breakpoint in each query's results. If the top 3 results are at distances 0.18, 0.22, 0.25 and the next 7 are at 0.41, 0.43, 0.44, 0.45, 0.46, 0.47, 0.48 — the gap between 0.25 and 0.41 is the signal. Cut there.

**The kneedle algorithm** formalizes this. It finds the "knee point" in a curve — the point of maximum curvature where the score distribution transitions from gradual decrease to sharp drop. Two production implementations exist:

- **Weaviate's `autocut`** (shipped in version 1.20): limits results based on discontinuities in the distance distribution. The user specifies how many "groups" to return, where groups are separated by score jumps.
- **Vectara's "Knee Reranking"**: combines global regression with local pattern detection. Configurable parameters control sensitivity (how dramatic a score shift must be) and early bias (preference for higher-ranked results).

The [`kneed` Python library](https://github.com/arvkevi/kneed) implements the algorithm directly. The procedure: retrieve top-k results with distances, feed the sorted distances to `KneeLocator`, cut at the detected knee.

**The risk:** not all queries produce a clean knee. Some have gradual score decay with no obvious gap — every result is slightly worse than the previous one, with no natural boundary. The algorithm degrades gracefully (it returns all results rather than cutting aggressively), but it cannot create a signal that does not exist in the distance distribution.

Simpler statistical approaches exist: z-score filtering (drop results more than N standard deviations from the top-result mean), relative drop detection (cut where the distance jumps by more than X% from the previous result), percentile-based filtering. These are easier to implement but less robust — they assume specific score distributions that may not hold across different queries.

## Hybrid retrieval with rank fusion

A document that scores high on both keyword match and semantic similarity is far more likely to be relevant than one scoring high on only one signal. Combining retrieval channels exploits this.

**Reciprocal Rank Fusion (RRF)** is the standard algorithm. Each document at rank *r* in a result list receives a score of 1/(*k* + *r*), where *k* is a constant (typically 60). Scores are summed across all result lists. A document ranked 2nd in vector search and 5th in keyword search gets a higher fused score than a document ranked 1st in vector search but absent from keyword results.

The key advantage: RRF operates on ranks, not scores. This sidesteps the score normalization problem entirely. Cosine distance and BM25 scores live in incompatible ranges — RRF does not care. It only needs the ordering.

[Crib](https://github.com/bioneural/crib) already has the infrastructure for this. Its three retrieval channels — fact triples, FTS5 full-text search, and sqlite-vec vector similarity — run independently and merge results. The current merge is union-based: take everything any channel returns, deduplicate by entry ID. Replacing this with RRF would weight entries that appear in multiple channels higher, naturally filtering noise that only vector search returns.

Research from IBM suggests that three-way hybrid retrieval (BM25 + dense vectors + sparse learned representations) improves retrieval accuracy by 20–30% over any single signal. Even two-way fusion (keyword + vector) captures most of the gain.

## Learned relevance classifiers

A 2024 EMNLP paper, "Learning to Fuse Retrieval Signals," trains a Random Forest classifier to predict binary relevance for each query-passage pair. The feature vector for each pair contains:

- **Bi-encoder similarity score** — the raw cosine distance from the embedding model
- **Cross-encoder relevance score** — the more expensive but more accurate reranker output
- **BM25 score** — the keyword match signal (optional but helpful)

The classifier learns the decision boundary that a static threshold cannot provide. It learns that a cosine distance of 0.35 paired with a high cross-encoder score means relevant, while the same cosine distance paired with a low cross-encoder score means noise.

**The training data requirement is small.** The paper reports strong performance with 100–500 labeled query-passage pairs. The classifier itself is trivial to run — a Random Forest prediction takes microseconds. The cost is in generating the features: each candidate needs a cross-encoder score, which means a forward pass per candidate.

**Results:** the basic two-feature classifier (bi-encoder + cross-encoder) improves filtering by 8.6% on HotpotQA and 19.0% on FiQA over cross-encoder thresholding alone. Adding BM25 as a third feature provides further gains.

The tradeoff: the classifier is trained on a specific corpus and embedding model. If either changes substantially, retraining may be needed. But for a system with a stable embedding model and a gradually growing corpus, periodic retraining on a small labeled set is manageable.

## LLM-based relevance filtering

The most direct approach: after retrieving candidates, ask a language model whether each one is relevant.

**CRAG (Corrective Retrieval Augmented Generation)**, published in 2024, formalizes this. A lightweight evaluator (0.77B parameters, T5-based) scores each retrieved document and classifies confidence into three levels:

| Confidence | Action |
|---|---|
| **Correct** | Refine the document — strip irrelevant sentences, keep the core |
| **Incorrect** | Discard retrieval entirely, fall back to alternative sources |
| **Ambiguous** | Combine refined retrieval with fallback results |

The evaluator adds 2–5% computational overhead. CRAG consistently outperforms standard RAG on factual accuracy by catching low-quality retrievals before they reach the generation step.

**Self-RAG** (ICLR 2024, oral presentation) takes this further. The language model is fine-tuned to generate special reflection tokens inline with its output: `[Retrieve]` (should I retrieve now?), `[IsRel]` (is this passage relevant?), `[IsSup]` (is my generation supported by the passage?), `[IsUse]` (is this useful?). The model learns to self-critique, adaptively deciding when and whether to use retrieved content.

For a local system, a simpler version of CRAG is practical: retrieve candidates, pass each to a small local model with a relevance prompt, filter by the model's judgment. The tradeoff is latency — one LLM inference per candidate document. With a 1B model via ollama, this adds seconds per query, not milliseconds.

## What the frameworks ship

| Framework | Solution | Type |
|---|---|---|
| **Weaviate** | `autocut` | Kneedle-based adaptive cutoff |
| **Vectara** | Knee Reranking | Adaptive cutoff with sensitivity controls |
| **LangChain** | `similarity_score_threshold` | Static threshold |
| **LlamaIndex** | `SimilarityPostprocessor` | Static threshold; recommends layering rerankers |
| **Pinecone** | None | Community has requested it for years |
| **Elasticsearch** | Open issue exploring kneedle | Not shipped |

Weaviate and Vectara are the only frameworks that ship a non-static solution out of the box. The others offer static thresholds and recommend adding reranking as a separate step.

## What fits crib

[Crib](https://github.com/bioneural/crib) is a single-file Ruby script calling ollama and sqlite-vec. It runs locally, has no cloud dependencies, and retrieves through three channels that already exist. The constraints are: everything runs on one machine, latency matters (retrieval feeds into an LLM context window), and complexity should stay low.

**Rank fusion** is the first thing to implement. The three channels already run independently. Replacing the current union-based merge with RRF requires no new dependencies, no new models, and no training data. It uses the infrastructure that already exists and strengthens the relevance signal by weighting entries that multiple channels agree on.

**Cross-encoder reranking** is the highest-impact single addition. The Qwen3 reranker at 0.6B parameters runs in ollama. Retrieve top 30–50 candidates, rerank, return the top 10. This replaces the distance threshold problem with a more accurate relevance ranking.

**Adaptive cutoff** is the simplest replacement for the static threshold. The kneedle algorithm requires no training data and adapts per query. It can be applied after reranking for a cleaner signal, or directly on vector distances as a minimal improvement over the fixed cutoff.

**A learned classifier** becomes practical once cross-encoder scores are available. A Random Forest trained on 100–500 labeled examples learns the decision boundary that replaces thresholding entirely. The labeled examples can be accumulated organically — logging retrieval results and periodically reviewing them for relevance.

The approaches compose. Rank fusion feeds better candidates into the reranker. The reranker produces calibrated scores. The adaptive cutoff or classifier operates on those scores. Each layer reduces noise that the previous layer could not catch.

## Limits

This is a literature survey, not an experiment. The performance claims (8.6% improvement, 20–30% accuracy gain) come from published benchmarks on standard datasets — not from crib's corpus, embedding model, or query patterns. Whether these gains transfer to a 120-entry memory module with nomic-embed-text embeddings and gemma3:1b-extracted triples is untested.

The cross-encoder models listed may not be available or performant on all hardware. The Qwen3 reranker requires ollama support for reranking endpoints, which may require specific configuration.

The CRAG and Self-RAG approaches add latency. For a system where retrieval results feed into an LLM prompt, adding seconds of reranking latency before the main inference call may be acceptable or may not, depending on the use case.

None of these approaches eliminate the fundamental problem: determining relevance requires understanding intent, and no retrieval signal — distance, rank, cross-encoder score, or LLM judgment — is infallible. The goal is not perfect filtering. It is making the filtering good enough that the downstream consumer (the language model reading the retrieved context) receives more signal than noise.
