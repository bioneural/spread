---
title: "What a memory system needs to become infrastructure"
date: 2026-03-14
description: "A comparison between two approaches to agent memory: a three-channel retrieval system with knowledge triples and vector search, and a minimal always-on daemon that dumps all memories into the language model context. Neither is complete. The gaps reveal what a production memory layer for a multi-agent operating system actually requires: background consolidation that generates new understanding, startup briefing documents for cold-start agents, and multimodal ingestion. The retrieval system is the stronger foundation, but the daemon has three patterns worth stealing."
---

**TL;DR** — I compared my memory system (three-channel retrieval with full-text search, vector similarity, and knowledge triples, fused via reciprocal rank fusion and cross-encoder reranked) against [Google's always-on memory agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent) (a daemon that dumps up to 50 memories into the language model context and lets the model do the retrieval). The retrieval system is more capable. The daemon is more interesting architecturally. Three patterns from the daemon belong in production memory infrastructure: background consolidation that synthesizes new understanding from accumulated memories, bidirectional connection graphs that build emergent knowledge, and multimodal ingestion. Neither system solves cold-start context injection — the problem of giving a newly spawned agent everything it needs to know without forcing it to explore a memory store. That gap is the most consequential one for [Prophet](https://github.com/bioneural/prophet) — an autonomous operating system for running a solo-founder software company.

---

## Two designs

The memory system I built — [crib](https://github.com/bioneural/crib) — stores memories in SQLite and retrieves them through three parallel channels. Full-text search via FTS5 with Porter stemming. Vector similarity via [sqlite-vec](https://github.com/asg017/sqlite-vec) on 1024-dimensional Voyage AI embeddings. Knowledge triples — subject, predicate, object — extracted by a language model on write. Results from all three channels are fused using reciprocal rank fusion, then reranked by a cross-encoder that makes binary relevance judgments. The system is a single Ruby script, invoked via stdin/stdout, integrated into agent sessions through [hooker](https://github.com/bioneural/hooker) (a git-hooks-style event system for Claude Code). It is framework-agnostic. It fails open — if the database is missing, if an API is down, if the reranker is broken, the agent continues unimpeded.

Google's [always-on memory agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent) takes the opposite approach. No embeddings. No search indexes. No retrieval pipeline. Memories are rows in SQLite with a summary, extracted entities, topics, and an importance score. On query, the system loads all memories — capped at 50 — into the language model's context window and lets the model find what is relevant. Retrieval is an in-context reasoning task, not an information retrieval task. The system runs as a persistent daemon with three concurrent loops: a file watcher polling an inbox directory every five seconds, a consolidation cycle firing every 30 minutes, and an HTTP API for external interaction.

## Where the retrieval system is stronger

The retrieval pipeline scales. Three channels with fusion and reranking will find relevant memories in a store of thousands. The no-retrieval approach breaks at 50 entries — that is a hard cap imposed by context window economics.

Temporal modeling is more precise. Crib's knowledge triples carry `valid_from` and `valid_until` timestamps. When a new fact supersedes an old one with the same subject and predicate, the old triple is marked with its end date. The database preserves history. Google's system has `created_at` and a boolean `consolidated` flag. There is no concept of truth changing over time.

Provenance tracking distinguishes agent-generated memories from operator-stated ones. The `source` field enables trust hierarchies — an operator correction overrides an agent observation. Google's system tracks which file a memory came from. There is no trust model.

Fail-open design is non-negotiable for production agent loops. Crib never blocks the calling agent. Every error path exits 0 with empty output. Google's system is a daemon — if it crashes, the agents lose their memory service entirely.

Framework independence matters for Prophet's architecture, where every agent is a Claude Code session. Crib integrates via stdin/stdout pipes. Google's system is welded to the [Google Agent Development Kit](https://google.github.io/adk-docs/).

## Three patterns worth stealing

### Background consolidation

Google's daemon runs a consolidation loop every 30 minutes. It reviews unconsolidated memories, identifies cross-cutting patterns, and generates higher-order insights stored in a separate `consolidations` table. The metaphor is deliberate: the human brain consolidates memories during sleep. Accumulated experiences are reviewed in batch, and new understanding emerges that was not present in any individual memory.

Crib consolidates on write. When a new triple shares the same subject and predicate as an existing one, the old triple is superseded. This is temporal consolidation — maintaining current truth. It is not generative consolidation. The system never looks across memories and synthesizes something new.

The distinction matters. Temporal consolidation answers "what is true now?" Generative consolidation answers "what patterns have I not noticed?" For a system that runs autonomously for hours or days, the second question is as important as the first.

### Bidirectional connection graphs

When Google's consolidation discovers a relationship between memory A and memory B, both memories get their `connections` field updated with a link to the other. Over time, an emergent knowledge graph forms — not designed, but discovered through periodic review.

Crib's knowledge triples are one-directional. Subject relates to object via predicate. The system does not discover relationships between memories that were not explicit in the original text. A background process that periodically searches for latent connections between stored memories and records them would build a richer model of the knowledge space.

### Multimodal ingestion

Google's system sends raw image, audio, video, and PDF bytes directly to Gemini and lets the language model extract a text representation. No OCR pipeline. No speech-to-text service. The model's multimodal capabilities handle feature extraction. The resulting text becomes the stored memory.

Crib is text-only. Prophet will need to process research papers, screenshots, invoices, recorded meetings, and customer communications. Multimodal ingestion is not optional.

## What neither system solves

### Cold-start context injection

When Prophet spawns a new agent — a worker picking up a task, a planning agent exploring a new domain — that agent starts with an empty context window. Neither system gives the agent a compact briefing of everything it needs to know.

Crib integrates via a hook that runs a retrieval query against the user's prompt. This is reactive — the agent must say something before memory is consulted. Google's system requires an explicit query. Neither produces a "here is your world" document at agent startup.

The pattern I want: a periodically-generated summary document — distilled from the full memory store — that gets injected into every new agent's system prompt. The agent starts knowing the essential facts, the active decisions, the standing directives. If it needs more detail, it can query the full memory store. But it does not start cold.

### Memory scoping by role

A planning agent and a worker agent need different memories. A planning agent needs strategic context, active goals, and architectural decisions. A worker agent needs the specific technical facts relevant to its task. Neither system supports scoped or role-filtered retrieval.

### Concurrent multi-agent writes

Both systems assume a single writer. Prophet will have many agents writing concurrently. Crib's SQLite WAL mode helps with concurrent reads, but the dedup and consolidation logic was not designed for multiple agents writing simultaneously. Race conditions in triple extraction and supersession are likely under concurrent load.

## Conclusion

The retrieval system is the stronger foundation. The daemon has three patterns that belong in it. The gaps — cold-start briefings, role-scoped retrieval, concurrent multi-agent writes — are the actual engineering problems for a multi-agent operating system.

The next work is to bring the daemon's patterns into the retrieval system: a background consolidation process that generates insight, bidirectional connection discovery, and multimodal ingestion. And to solve the cold-start problem, which neither system has attempted.

## Limits

This comparison is between a production system with months of operational history and a reference implementation designed to demonstrate Google's Agent Development Kit. The sophistication gap is expected. The value is not in proving one is better — it is in identifying the patterns that each system embodies and that the other lacks.

The cold-start briefing concept is untested. It may be that a compact summary loses critical nuance, or that the right granularity depends on the agent's role in ways that a single summary cannot accommodate. The idea is a hypothesis, not a validated design.

The concurrent multi-agent write problem is stated but not scoped. SQLite's WAL mode supports concurrent readers and a single writer. Whether this becomes a bottleneck depends on write frequency, which depends on how aggressively agents produce memories. The problem may not materialize at Prophet's initial scale.
