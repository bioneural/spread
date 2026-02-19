---
title: "The model swap penalty"
date: 2026-02-19
order: 1
description: "A local inference server running two models — one for embedding
  queries and one for scoring relevance — silently spends six seconds swapping between them on
  every alternating call. Two environment variables eliminate the penalty
  entirely."
---

**TL;DR** — [Ollama](https://ollama.com/), the local inference server I use for all model calls in a [memory module](https://github.com/bioneural/crib), defaults to keeping one model loaded at a time. When a retrieval pipeline alternates between an embedding model and a reranking model, ollama unloads one and loads the other on every switch — a six-second penalty invisible in single-model benchmarks. Two environment variables (`OLLAMA_MAX_LOADED_MODELS` and `OLLAMA_KEEP_ALIVE`) eliminate it. Per-call latency dropped from ~6 seconds to ~0.3 seconds.

---

## The setup

The retrieval pipeline in crib (a memory module for a system of cooperating tools) makes two kinds of ollama calls per query:

1. **Embedding** — `nomic-embed-text` converts the query into a 768-dimensional vector for similarity search
2. **Reranking** — `gemma3:1b` reads each query-document pair and scores relevance via [logprob extraction](/posts/cross-encoder-reranking)

A single retrieval call embeds the query once, then reranks up to 20 candidates. The calls alternate: embed → rerank × 20. In isolation, each rerank call takes ~350ms. But end-to-end retrieval was taking far longer than the sum of its parts.

## The dead end: threading

The initial hypothesis: sequential HTTP calls were the bottleneck. Twenty rerank calls at 350ms each = 7 seconds, all sequential. I implemented concurrent HTTP requests using Ruby threads — dispatch all 20 rerank calls in parallel, collect results.

7.4 seconds for 10 entries. No improvement. Ollama serializes inference on a single Metal device (Apple Silicon GPU). Concurrent HTTP requests queue on the server side. The threads add connection overhead for zero throughput gain.

## The real problem

Instrumentation revealed the actual mechanism. The *first* rerank call after an embed call took ~6 seconds. Subsequent rerank calls (without an intervening embed) took ~0.3 seconds. The pattern was consistent:

~~~ text
embed query          →  0.05s
rerank candidate 1   →  6.20s  ← model swap
rerank candidate 2   →  0.31s
rerank candidate 3   →  0.28s
...
rerank candidate 20  →  0.35s
~~~

Ollama's default behavior: load one model, serve requests, unload it when a different model is requested, load the new one. The [ollama FAQ](https://github.com/ollama/ollama/blob/main/docs/faq.md#how-does-ollama-handle-concurrent-requests) confirms this — by default, `num_parallel` is 1 and models are evicted after 5 minutes of inactivity (or immediately when a different model is requested and `OLLAMA_MAX_LOADED_MODELS` is 1, the default).

The 6-second penalty is the cost of loading gemma3:1b's weights (~1.2 GB) into GPU memory after evicting nomic-embed-text (~578 MB). This happens on *every* retrieval call because the pipeline always alternates models.

## The fix

Two [ollama environment variables](https://github.com/ollama/ollama/blob/main/docs/faq.md#how-do-i-configure-ollama-server) eliminate the swap:

~~~ text
OLLAMA_MAX_LOADED_MODELS=3    # keep up to 3 models in GPU memory
OLLAMA_KEEP_ALIVE=-1          # never auto-evict loaded models
~~~

On macOS with Homebrew-managed ollama, these go in the launchd plist. [Homebrew](https://brew.sh/) stores installed formula files in a directory called the Cellar (`/opt/homebrew/Cellar/`). The source plist lives at `/opt/homebrew/Cellar/ollama/<version>/homebrew.mxcl.ollama.plist`. Edit this file, not the symlink at `~/Library/LaunchAgents/` — `brew services restart` regenerates the symlink from the Cellar copy. After restarting:

~~~ text
$ ollama ps
NAME                    SIZE      PROCESSOR    UNTIL
gemma3:1b               1.2 GB    100% GPU     Forever
nomic-embed-text        578 MB    100% GPU     Forever
~~~

Both models stay resident. Alternating-call benchmark:

| Call | Model | Before | After |
|------|-------|--------|-------|
| 1 | nomic-embed-text | 0.05s | 0.05s |
| 2 | gemma3:1b | 6.20s | 0.26s |
| 3 | nomic-embed-text | 6.10s | 0.05s |
| 4 | gemma3:1b | 6.20s | 0.26s |

The swap penalty is eliminated. Total GPU memory footprint: ~1.8 GB for both models. Well within the unified memory of any M-series Mac.

## What this means for the pipeline

At 20 rerank candidates per query:

- **Before:** 0.05s embed + 6.2s first rerank (swap) + 19 × 0.3s remaining = **12.0s**
- **After:** 0.05s embed + 20 × 0.3s rerank = **6.1s**

The swap penalty was doubling the retrieval latency. It was also invisible in any benchmark that tested a single model in isolation — the swap only manifests when models alternate.

## Dead ends

**Concurrent HTTP requests.** Ruby threads dispatching 20 rerank calls in parallel. Ollama serializes them — Metal inference runs on one device, the server queues requests. Same wall-clock time plus thread overhead. Threading would help with a multi-GPU setup or multiple ollama instances, not with a single Apple Silicon chip.

**Editing `~/Library/LaunchAgents/homebrew.mxcl.ollama.plist` directly.** The file is a symlink. `brew services restart` regenerates it from the Cellar source template. Edits survive until the next restart, then vanish. The correct target is `/opt/homebrew/Cellar/ollama/<version>/homebrew.mxcl.ollama.plist`. `brew upgrade ollama` overwrites this too — the variables must be re-applied after upgrades.

## Limits

**Memory budget.** Keeping multiple models loaded consumes GPU memory proportional to their total size. Two small models (1.8 GB) fit easily. Adding a 7B model (~5 GB) could pressure the unified memory budget and force macOS to page — trading the model swap penalty for a memory pressure penalty.

**Ollama-specific.** The fix is specific to [ollama's model management](https://github.com/ollama/ollama/blob/main/docs/faq.md). Other inference servers ([llama.cpp server](https://github.com/ggml-org/llama.cpp/tree/master/examples/server), [vLLM](https://github.com/vllm-project/vllm), [TGI](https://github.com/huggingface/text-generation-inference)) have different model lifecycle strategies. The principle — keep frequently-used models resident — applies broadly. The mechanism varies.

**Upgrade fragility.** The Cellar plist edit does not survive `brew upgrade ollama`. A more durable approach: a launchd override plist or a wrapper script that sets the environment variables before invoking ollama. I document the variables and re-apply after upgrades.