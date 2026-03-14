---
title: "What a memory system needs to become infrastructure"
date: 2026-03-14
description: "A comparison between crib — the memory layer of Prophet, an operating system for a single agent — and Google's always-on memory agent, a daemon that loads all stored memories into the language model's context. They solve memory differently: crib searches and ranks, the daemon delegates retrieval to the model. Neither is complete. The gaps reveal three patterns worth examining: background consolidation, bidirectional connection graphs, and multimodal ingestion."
---

**TL;DR** — I compared [crib](https://github.com/bioneural/crib), my memory system for [Prophet](https://github.com/bioneural/prophet) (an operating system for running a solo-founder software company), against [Google's always-on memory agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent), a daemon that loads stored memories directly into the language model's context and lets the model decide what is relevant. Crib searches through three parallel channels — full-text, vector similarity, and knowledge triples — then fuses and reranks the results. Results from all three channels are fused using reciprocal rank fusion (merging multiple rankings), then reranked by a cross-encoder (a neural model scoring query-document relevance) that makes binary relevance judgments. Google's daemon stores up to 50 memories and hands them all to the model at query time. The architectures differ in how they handle scale, temporal modeling, and failure modes. Google's daemon introduces three patterns that crib lacks and that I am evaluating for adoption: background consolidation that synthesizes new understanding from accumulated memories, bidirectional connection graphs that surface latent relationships, and multimodal ingestion. Neither system solves cold-start context injection — the problem of giving a newly spawned agent everything it needs to know without forcing it to explore a memory store. That gap is the most consequential one for Prophet.

---

## Two designs

Crib — the memory layer I built for Prophet — stores memories in SQLite and retrieves them through three parallel channels. Full-text search via FTS5, with Porter stemming (a word normalization algorithm). Vector similarity via [sqlite-vec](https://github.com/asg017/sqlite-vec) on 1024-dimensional Voyage AI embeddings. Knowledge triples — subject, predicate, object — extracted by a language model on write. Results from all three channels are fused using reciprocal rank fusion, then reranked by a cross-encoder that makes binary relevance judgments. The system is a single Ruby script, invoked via stdin/stdout, integrated into agent sessions through [hooker](https://github.com/bioneural/hooker) (a git-hooks-style event system for Claude Code). It is framework-agnostic. It fails open — if the database is missing, if an API is down, if the reranker is broken, the agent continues unimpeded.

Google's [always-on memory agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent) takes the opposite approach. No embeddings. No search indexes. No retrieval pipeline. Memories are rows in SQLite with a summary, extracted entities, topics, and an importance score. On query, the system loads all memories — capped at 50 — into the language model's context window and lets the model find what is relevant. Retrieval is an in-context reasoning task, not an information retrieval task. The system runs as a persistent daemon with three concurrent loops: a file watcher polling an inbox directory every five seconds, a consolidation cycle firing every 30 minutes, and an HTTP API for external interaction.

## Where crib is stronger

Crib's three-channel retrieval pipeline handles larger memory stores than the daemon's approach of loading all memories into context. The daemon caps at 50 entries — a constraint imposed by context window economics. Whether crib's pipeline degrades gracefully at thousands of entries is not yet measured under production load, but the architecture does not impose a hard ceiling the way context-window loading does.

Temporal modeling is more precise in crib. Knowledge triples carry `valid_from` and `valid_until` timestamps. When a new fact supersedes an old one with the same subject and predicate, the old triple is marked with its end date. The database preserves history. Google's daemon has `created_at` and a boolean `consolidated` flag. There is no concept of truth changing over time.

Provenance tracking distinguishes agent-generated memories from operator-stated ones. The `source` field enables trust hierarchies — an operator correction overrides an agent observation. Google's daemon tracks which file a memory came from. There is no trust model.

Fail-open design matters for production agent loops. Crib never blocks the calling agent. Every error path exits 0 with empty output. Google's daemon is a persistent process — if it crashes, the agents lose their memory service entirely. Whether fail-open is the correct tradeoff depends on the system: a daemon that crashes loudly may surface problems that a fail-open system silently absorbs. For Prophet, where agents must not stall on infrastructure failures, I chose fail-open.

Framework independence matters for Prophet's architecture, where every agent is a Claude Code session. Crib integrates via stdin/stdout pipes. Google's daemon is built on the [Google Agent Development Kit](https://google.github.io/adk-docs/).

## Three patterns I am examining

### Background consolidation

Google's daemon runs a consolidation loop every 30 minutes. It reviews unconsolidated memories, identifies cross-cutting patterns, and generates higher-order insights stored in a separate `consolidations` table. The metaphor is deliberate: the human brain consolidates memories during sleep. Accumulated experiences are reviewed in batch, and new understanding emerges that was not present in any individual memory.

Crib consolidates on write. When a new triple shares the same subject and predicate as an existing one, the old triple is superseded. This is temporal consolidation — maintaining current truth. It is not generative consolidation. The system never looks across memories and synthesizes something new.

The distinction matters. Temporal consolidation answers "what is true now?" Generative consolidation answers "what patterns have I not noticed?" For a system that runs autonomously for hours or days, the second question may be as important as the first. Whether generative consolidation produces actionable insight — or noise — depends on the quality of the synthesis model and the density of the memory store. This is testable but untested.

### Bidirectional connection graphs

When Google's consolidation discovers a relationship between memory A and memory B, both memories get their `connections` field updated with a link to the other. Over time, an emergent knowledge graph forms — not designed, but discovered through periodic review.

Crib's knowledge triples are one-directional. Subject relates to object via predicate. The system does not discover relationships between memories that were not explicit in the original text. A background process that periodically searches for latent connections between stored memories and records them could build a richer model of the knowledge space. Whether the discovered connections would improve retrieval quality or just add storage cost is an open question.

### Multimodal ingestion

Google's daemon sends raw image, audio, video, and PDF bytes directly to Gemini and lets the language model extract a text representation. No OCR pipeline. No speech-to-text service. The model's multimodal capabilities handle feature extraction. The resulting text becomes the stored memory.

Crib is text-only. Prophet will need to process research papers, screenshots, invoices, recorded meetings, and customer communications. Multimodal ingestion is a clear gap. The question is implementation: delegate to the language model (as Google does) or use specialized extraction tools for each modality. The tradeoff is generality versus accuracy.

## What neither system solves

### Cold-start context injection

When Prophet spawns a new agent — a worker picking up a task, a planning agent exploring a new domain — that agent starts with an empty context window. Neither system gives the agent a compact briefing of everything it needs to know.

Crib integrates via a hook that runs a retrieval query against the user's prompt. This is reactive — the agent must say something before memory is consulted. Google's daemon requires an explicit query. Neither produces a "here is your world" document at agent startup.

The pattern I am considering: a periodically-generated summary document — distilled from the full memory store — that gets injected into every new agent's system prompt. The agent starts knowing the essential facts, the active decisions, the standing directives. If it needs more detail, it can query the full memory store. But it does not start cold. Whether a compact summary can preserve enough nuance, or whether the right granularity varies by agent role, is unresolved.

### Memory scoping by role

A planning agent and a worker agent need different memories. A planning agent needs strategic context, active goals, and architectural decisions. A worker agent needs the specific technical facts relevant to its task. Neither system supports scoped or role-filtered retrieval.

### Concurrent multi-agent writes

Both systems assume a single writer. Prophet will have many agents writing concurrently. Crib's SQLite write-ahead logging (WAL) mode helps with concurrent reads, but the dedup and consolidation logic was not designed for multiple agents writing simultaneously. Race conditions in triple extraction and supersession are likely under concurrent load. Whether this becomes a bottleneck depends on write frequency, which depends on how aggressively agents produce memories. The problem may not materialize at Prophet's initial scale.

## Conclusion

Crib's retrieval architecture handles the problems that a production memory system must solve: scale beyond context-window limits, temporal truth, provenance, fail-open resilience, and framework independence. Google's daemon introduces three patterns that crib lacks: generative consolidation, emergent connection graphs, and multimodal ingestion. Whether these patterns improve the system in practice requires implementation and measurement.

The gaps that neither system addresses — cold-start briefings, role-scoped retrieval, concurrent multi-agent writes — are the actual engineering problems for a multi-agent operating system.

## Limits

This comparison is between a production system with months of operational history and a reference implementation designed to demonstrate Google's Agent Development Kit. The sophistication gap is expected. The value is not in ranking the systems — it is in identifying the patterns that each embodies and that the other lacks.

The cold-start briefing concept is untested. It may be that a compact summary loses critical nuance, or that the right granularity depends on the agent's role in ways that a single summary cannot accommodate. The idea is a hypothesis, not a validated design.