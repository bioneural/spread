---
title: "Cross-encoder reranking"
date: 2026-02-18
description: "A memory module merges keyword search and vector similarity
  results using a formula called Reciprocal Rank Fusion, but the formula
  cannot filter noise — it faithfully promotes whatever the channels return.
  A small language model reading each query-document pair produces a relevance
  score that reranks candidates after fusion, improving precision and scoring
  every irrelevant result at zero."
---

**TL;DR** — [Rank fusion](/posts/reciprocal-rank-fusion) improved retrieval precision in a memory module from 2.7/10 to 4.8/10, but it cannot filter noise — negative queries get the same confident-looking results as real ones. I added a reranking step after fusion: a small language model (gemma3:1b) reads each query-document pair and produces a continuous relevance score from its logprobs. On a 120-entry corpus, mean precision improved from 4.80/10 to 5.20/10 for direct queries. No query regressed. The real finding: every candidate returned for five irrelevant queries scored exactly 0.000. The reranker can distinguish noise from signal in a way that rank fusion cannot.

---

## The noise problem

[Crib](https://github.com/bioneural/crib) is a memory module I built for a system of cooperating tools. It retrieves through full-text search and vector similarity, then merges results using [Reciprocal Rank Fusion](/posts/reciprocal-rank-fusion) — entries found by both channels score higher than entries found by one.

RRF improved precision substantially, but the [previous experiment](/posts/reciprocal-rank-fusion) identified a structural limitation: RRF fuses whatever the channels return, including garbage. If a query about hydroelectric power generation hits keyword matches on "power" and "generation" in unrelated entries, RRF faithfully promotes those entries. It has no mechanism to evaluate whether a result is actually relevant to the query — it operates on ranks, not content.

The five negative queries in the test suite (topics like ceramic glazes, currency exchange, and Gothic architecture) all returned results from at least one channel. RRF cannot help. The technique I needed operates downstream of fusion: read the query and each candidate document together, then score relevance.

## Cross-encoder scoring

A cross-encoder processes a query-document pair jointly and produces a relevance score. Unlike a bi-encoder approach (which encodes query and document separately into embedding vectors and compares distances), a cross-encoder reads both texts together, attending to the relationship between them.

The [Qwen3 Reranker](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B) is a dedicated cross-encoder designed for this. I tried it first. [Ollama](https://ollama.com/) is the local model server I use for all inference. The quantized model files (GGUF format, the standard for running models locally) available in ollama ([dengcao/Qwen3-Reranker-0.6B](https://ollama.com/dengcao/Qwen3-Reranker-0.6B)) produced uniform logprobs across all tokens — every token had identical probability. The model is trained as a sequence classifier: it reads the input and produces output weights (logits) for "yes" and "no" at the final position. But ollama's generation API treats it as an autoregressive model, which does not work. The model output was a stream of `!` characters.

The fallback worked better: gemma3:1b, the same 1-billion-parameter model already used for classification elsewhere in the system. The prompt is direct:

~~~ text
Judge whether the Document is relevant to the Query.
Answer exactly "yes" or "no", nothing else.

Query: {query}

Document: {document}
~~~

With `temperature: 0.0`, `num_predict: 1`, and `logprobs: true`, the model generates a single token. The [ollama logprobs API](https://github.com/ollama/ollama/blob/main/docs/api.md#response-10) returns the top token probabilities. I extract the logprobs for the "yes" and "no" tokens and compute `P(yes) = exp(yes_logprob) / (exp(yes_logprob) + exp(no_logprob))` — a continuous score from 0.0 to 1.0.

A test across four documents for the query "nomic-embed-text embedding dimensions and performance":

| Document | Answer | Score |
|----------|--------|-------|
| "nomic-embed-text produces 768-dimensional float vectors..." | yes | 0.992 |
| "Chose nomic-embed-text over mxbai-embed-large..." | yes | 0.610 |
| "Store embeddings as float[768] in sqlite-vec..." | no | 0.000 |
| "The best way to caramelize onions..." | no | 0.000 |

The exact match scores 0.99. The related-but-indirect document scores 0.61. The tangentially related and completely irrelevant documents both score 0.00. The model discriminates well.

## The experiment

I seeded a 120-entry corpus across 10 topical clusters plus 20 noise entries (identical to the [rank fusion experiment](/posts/reciprocal-rank-fusion)). For each of 20 test queries:

1. Retrieve top 20 from FTS and vector independently
2. RRF merge → top 20 candidates (expanded from 10 to give the reranker more to work with)
3. Score each candidate via the reranker
4. Sort by rerank score descending → top 10

I compared precision@10 for RRF-only (top 10 of the 20 RRF candidates) against RRF+rerank (top 10 after reranking).

## Results

### Direct-vocabulary queries (Q01–Q10)

| Query | Target | RRF P@10 | Reranked P@10 | Delta |
|-------|--------|----------|---------------|-------|
| Q01 | Logging backend | 1/10 | 1/10 | 0 |
| Q02 | Embedding config | 6/10 | 7/10 | +1 |
| Q03 | Classifier tuning | 8/10 | 8/10 | 0 |
| Q04 | SQL/DB design | 4/10 | 4/10 | 0 |
| Q05 | Error handling | 2/10 | 3/10 | +1 |
| Q06 | Ruby stdlib | 3/10 | 4/10 | +1 |
| Q07 | Git workflow | 5/10 | 6/10 | +1 |
| Q08 | Test design | 6/10 | 6/10 | 0 |
| Q09 | Voice standards | 7/10 | 7/10 | 0 |
| Q10 | Logging/observability | 6/10 | 6/10 | 0 |

Four queries improved by +1 each. Six stayed the same. Zero regressed. Mean precision: **4.80/10 → 5.20/10** (+0.40).

### The hero example: Q02

Query: "nomic-embed-text embedding dimensions and performance" — targets cluster 2 (embedding model behavior).

Under RRF, entry 93 (cluster 10, about log entry field structure) held the 10th slot because it matched the keyword "embedded." The reranker scored it 0.000 and promoted entry 19 (cluster 2, about cosine vs L2 distance for embeddings) which had been at rank 14 in the RRF output. Entry 19 was not in the FTS results and sat below the RRF top 10, but the reranker recognized it as relevant to embeddings.

The score distribution shows the reranker's discrimination:

| Rank | Entry | Cluster | Rerank Score |
|------|-------|---------|-------------|
| 1 | #11 — "768-dimensional float vectors..." | 2 | 0.992 |
| 2 | #13 — "Chose nomic-embed-text over mxbai..." | 2 | 0.610 |
| 3 | #17 — "200-word paragraph and 5-word query..." | 2 | 0.015 |
| 4 | #19 — "Cosine similarity and L2 distance..." | 2 | 0.000 |
| 5–10 | Various | Mixed | 0.000 |

Only two entries received non-trivial scores. The reranker is strict: it requires that the document directly address the query, not merely share vocabulary.

### Paraphrase queries (Q11–Q15)

| Query | RRF P@10 | Reranked P@10 | Delta |
|-------|----------|---------------|-------|
| Q11 | 2/10 | 2/10 | 0 |
| Q12 | 4/10 | 5/10 | +1 |
| Q13 | 2/10 | 2/10 | 0 |
| Q14 | 4/10 | 4/10 | 0 |
| Q15 | 1/10 | 2/10 | +1 |

Mean precision: **2.60/10 → 3.00/10** (+0.40). The gain matches direct queries — the reranker helps equally whether the query uses the same vocabulary as the documents or paraphrases.

### Negative queries (Q16–Q20): the noise test

This is the result that matters most. RRF returned candidates for all five negative queries — between 1 and 18 per query. These are entries about software architecture, cooking, geography, and sports that matched on incidental keywords or fell within the vector distance threshold.

| Query | Topic | Candidates | Mean Score | Max Score |
|-------|-------|------------|------------|-----------|
| Q16 | Hydroelectric power | 8 | 0.000 | 0.000 |
| Q17 | Ceramic glazes | 4 | 0.000 | 0.000 |
| Q18 | Currency exchange | 3 | 0.000 | 0.000 |
| Q19 | Mindfulness meditation | 1 | 0.000 | 0.000 |
| Q20 | Gothic architecture | 18 | 0.000 | 0.000 |

Every candidate scored exactly 0.000. Not a single irrelevant entry received even a marginal relevance score. Q20 is especially striking — 18 candidates (the vector channel returned 18 results below the distance threshold for "comparative analysis of Gothic and Romanesque architectural styles") and every one scored zero.

This is the capability RRF lacks. RRF promotes entries that multiple channels agree on, but it cannot evaluate whether any of those entries actually answer the query. The reranker reads each candidate alongside the query and says "no, none of these are relevant." With a score threshold (e.g., filter candidates below 0.5), the reranker could return an empty result set — the correct answer when nothing in memory is relevant.

### Aggregate

| Query type | N | Mean RRF P@10 | Mean Reranked P@10 | Delta |
|------------|---|---------------|--------------------|----|
| Direct (Q01–Q10) | 10 | 4.80/10 | 5.20/10 | +0.40 |
| Paraphrase (Q11–Q15) | 5 | 2.60/10 | 3.00/10 | +0.40 |

### Latency

Each reranker call takes ~350ms (gemma3:1b, M-series Apple Silicon). At 20 candidates per query, reranking adds ~7 seconds. The full experiment — 120-entry corpus seeding, 20 queries with retrieval and reranking — completed in 15 minutes. Corpus seeding accounts for 13 of those minutes.

For production use, the 7-second per-query overhead is too high for interactive retrieval. Batching the reranker calls (sending multiple candidates in a single prompt) or using a faster model would reduce this. The experiment script calls ollama 20 times sequentially per query; a batched approach could reduce that to 1–2 calls.

## Implementation

The `rerank_score` function calls ollama's `/api/chat` endpoint with logprobs enabled and computes `P(yes)` from the first generated token:

~~~ ruby
def cross_encoder_rerank(prompt, entries, model: RERANK_MODEL)
  entries.map { |entry|
    score = rerank_score(prompt, entry['content'], model: model)
    entry.merge('rerank_score' => score)
  }.sort_by { |e| -e['rerank_score'] }
end

def rerank_score(prompt, document, model: RERANK_MODEL)
  rerank_prompt = <<~PROMPT
    Judge whether the Document is relevant to the Query.
    Answer exactly "yes" or "no", nothing else.

    Query: #{prompt}

    Document: #{document}
  PROMPT

  response = ollama_chat(model, rerank_prompt,
    temperature: 0.0, num_predict: 1, logprobs: true, top_logprobs: 10)
  extract_yes_probability(response)
end
~~~

Integration point: after `rrf_merge` produces 20 candidates, `cross_encoder_rerank` scores and sorts them, then the top 10 are returned. The existing generation-based rerank function (which sends all entries to the model in a single prompt and asks it to select relevant ones) is replaced by this per-entry scoring approach.

## Dead ends

**Qwen3 Reranker in ollama.** The [Qwen3-Reranker-0.6B](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B) is a dedicated reranker trained to output yes/no relevance judgments. Its [prompt format](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B) uses a system message ("Judge whether the Document meets the requirements...") and a structured user message with `<Instruct>`, `<Query>`, and `<Document>` fields. But the GGUF conversions available in ollama ([dengcao](https://ollama.com/dengcao/Qwen3-Reranker-0.6B), [sam860](https://ollama.com/sam860/qwen3-reranker)) produced uniform token probabilities — all tokens had identical logprobs of -11.93. The model is a sequence classifier, not a text generator. Ollama's generation API cannot extract the classification logits. This is a known limitation: ollama does not support reranker models natively.

**Logprob extraction bug.** The first experiment run produced all-zero scores. Two bugs: (1) `printf "."` inside a command substitution (`$(...)`) printed progress dots to stdout, corrupting the JSON that the substitution was supposed to capture; (2) the logprob extraction code iterated over all `top_logprobs` entries and used the last match for "no" — but "No", "NO", and " no" (with leading space) all match after `.strip.downcase`, overwriting the correct logprob (near-zero, meaning high confidence) with variants that had much lower logprobs. The fix: use the first match for each token class, since `top_logprobs` is sorted by probability descending.

## Limits

**Strict relevance definition.** The reranker treats relevance as "does this document directly answer the query?" rather than "is this document topically related?" For Q03 ("how was the classifier prompt tuned for accuracy?"), only entry 22 — which describes the exact tuning from binary to structured format — scored above zero. Seven other entries in the correct cluster (about classifier prompts, temperature settings, system vs user prompts) scored 0.000. They are topically related but do not directly answer the question. In a memory system, topically related context is often useful even if it does not directly answer the query.

**Modest precision gains.** The +0.40 improvement on 120 entries is small. At larger corpus sizes where RRF's dual-channel overlap drops to zero, the reranker may help more — it evaluates content, not channel agreement. But the current experiment does not test this.

**Latency.** 7 seconds per query for 20 candidates is not acceptable for interactive use. The ollama generation API requires one HTTP call per candidate. A batched approach (multiple candidates in a single prompt) or a faster inference path would be needed for production.

**Model size vs. accuracy.** gemma3:1b is the smallest model that produces usable yes/no judgments. Larger models (4B, 8B) would likely produce better discrimination at higher latency cost. The accuracy of the 1B model on edge cases (entry mentions the topic but does not directly answer the query) is an open question.

## Next

Score-threshold filtering for negative queries. The experiment shows the reranker scores all irrelevant candidates at exactly 0.000. A threshold (e.g., return only entries with rerank score > 0.5) would let the system return empty results when nothing in memory is relevant — the correct behavior for queries outside the corpus domain. This would be the first time the system can say "I don't know" instead of returning noise.
