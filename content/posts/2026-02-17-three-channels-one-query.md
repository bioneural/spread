---
title: "Three channels, one query"
date: 2026-02-17
description: "An AI agent's memory module retrieves through three independent channels: fact triples, full-text search, and vector similarity. Each fails on queries the others handle, so all three are necessary."
---

**TL;DR** — Crib is the memory module for prophet, my AI agent tool system. I seeded it with 10 memory entries and ran 13 test queries through each retrieval channel in isolation. Three queries produced results from vector search alone — FTS and triples returned nothing. One query shifted between hit and miss on triples across runs, depending on what the extraction model happened to produce. No single channel covered all 13 queries. Removing any one creates a class of queries that goes dark. The experiment also surfaced a concrete defect: vector search has no distance threshold, so it returns results even when nothing in the corpus is relevant. Tuning that threshold is the next piece of work.

---

## What crib is

AI coding agents lose context between sessions. The conversation ends, and everything the agent learned — which architectural decisions were made, what bugs were fixed, what patterns the codebase follows — evaporates. The next session starts from zero.

[Crib](https://github.com/bioneural/crib) is the memory module for [prophet](https://github.com/bioneural/prophet), a system of cooperating tools that augment an AI coding agent. Prophet discovers its tools — hooker (policy hooks), screen (classification), spill (logging), book (task management), trick (memory extraction), and crib — as sibling directories at runtime. Each tool handles one concern. Crib's concern is persistence: it stores what the agent has learned and retrieves what is relevant to the current prompt.

Entries are stored via `crib write` — plain text with an optional type prefix (`decision`, `correction`, `note`, `error`). Retrieval happens via `crib retrieve`, which takes a prompt on stdin and returns relevant memories wrapped in XML tags. The agent sees these memories as context injected before its response.

## How retrieval works

When a query arrives, crib runs three independent retrieval channels:

1. **Fact triples** — SQL JOINs across an entity-relation graph. Keywords from the query are matched against entity names via `LIKE '%keyword%'`. Returns structured facts: `spill → lives in → repo`.

2. **Full-text search** — FTS5 with Porter stemming and unicode61 tokenization. Keywords joined with OR, matched against stored entry content. Returns full paragraphs.

3. **Vector similarity** — The query is embedded via nomic-embed-text (768 dimensions), then matched against stored embeddings using sqlite-vec nearest neighbors. Returns the 10 closest entries by cosine distance.

The results are merged, deduplicated by entry ID, and wrapped in `<memory>` tags. The hypothesis: each channel covers retrieval cases the others cannot, so the union is necessary. The experiment tests this by isolating each channel and observing what disappears.

## The experiment

I added a `CRIB_CHANNEL` environment variable to crib's retrieve path. When set to `triples`, `fts`, or `vector`, only that channel runs. When unset, existing behavior is preserved. This tests the actual code paths — no reimplementation, no external queries.

The seed corpus: 10 entries written via `crib write`, covering decisions, notes, corrections, and errors about prophet's tools — the same sibling tools described above. Each entry was embedded and had fact triples extracted by gemma3:1b.

The extraction produced 47–49 active relations across 63–67 entities per run. Examples from the extracted graph:

```
crib        → uses        → consolidation-on-write
prophet     → does not    → vendor
gsub        → ran         → all user-supplied strings
nomic-embed-text → produces → 768-dimensional float vectors
persona     → evolves     → in one place
```

13 queries across four categories, each run through all four modes (triples only, FTS only, vector only, union). Three full runs to check stability.

## Results

| Query | Triples | FTS | Vector |
|-------|---------|-----|--------|
| A1: what logging backend does spill use? | HIT | HIT | HIT |
| A2: what does prophet discover at runtime? | HIT | HIT | HIT |
| A3: what architecture does prophet use for dependencies? | HIT | HIT | HIT |
| B1: gsub escaping single quote | HIT | HIT | HIT |
| B2: valid\_until consolidation-on-write | unstable | HIT | HIT |
| B3: porter stemming unicode61 tokenize | — | — | HIT\* |
| B4: 768 dimensional float vectors nomic | HIT | HIT | HIT |
| C1: how do the tools find each other at startup? | — | HIT | HIT |
| C2: what went wrong with the task queue crashing? | HIT | HIT | HIT |
| C3: preventing the agent from remembering useless things | — | — | HIT |
| C4: making sure the persona does not diverge across projects | HIT | HIT | HIT |
| D1: how does the small model fail on classification? | HIT | HIT | HIT |
| D2: every architectural decision we made about persistence | — | — | HIT |

\*B3 is a false positive. See below.

### Where vector is the only channel that returns anything

**C3: "preventing the agent from remembering useless things"**

The relevant entry is: *"trick extracted 14 memories from a single transcript but 9 were trivial operational details..."* The query uses "preventing," "useless," "remembering." The entry uses "extraction prompt," "trivial," "operational details." Zero keyword overlap. Porter stemming cannot bridge "useless" to "trivial" or "remembering" to "extraction." Only the embedding model encodes both phrasings near the same point in vector space.

FTS returns nothing. Triples return nothing. Vector returns the entry.

**D2: "every architectural decision we made about persistence"**

Four entries are relevant (entries 1, 5, 8, 10 — all typed as `decision`). But none contain the word "persistence" or "architectural." The entry type is `decision`, but that metadata is not in the FTS-indexed content. Keywords extracted from the query — "architectural," "decision," "persistence" — match nothing in the corpus text or entity names.

Vector returns results because "architectural decision about persistence" is semantically close to entries about SQLite logging, sibling directory layout, and consolidation-on-write. The embedding captures the concept even without shared vocabulary.

### Where vector gives a false positive

**B3: "porter stemming unicode61 tokenize"**

No entry discusses FTS5 tokenizer configuration. This is a control query — nothing in the corpus is relevant. FTS correctly returns nothing. Triples correctly return nothing. Vector returns all 10 entries.

This is the consequence of no distance threshold. sqlite-vec always returns the k nearest neighbors regardless of actual similarity. With 10 entries, it returns the entire corpus. The vector channel cannot say "nothing matches." It can only say "here are the closest things I have," and with a small corpus, the closest things are everything.

### Where triples are unstable

**B2: "valid\_until consolidation-on-write"**

FTS finds this consistently — both terms appear literally in entry 8. But triples depend on whether gemma3:1b extracted "valid\_until" or "consolidation-on-write" as entity names. In run 2, it did: `crib → uses → consolidation-on-write` matched the keyword. In runs 3 and 4, the extraction produced slightly different entity names and the LIKE match failed. Same entry, same extraction model, different entity graph each time.

### Where FTS reaches further than expected

**C1: "how do the tools find each other at startup?"**

I predicted this would be vector-only. The stored entry says "prophet discovers them at runtime via relative paths" — different vocabulary from "tools find each other at startup." But FTS matched it anyway. The keyword "tools" stems to "tool" via Porter stemming, and entry 5 contains "Each tool — hooker, crib, screen..." The singular form in the entry matched the plural in the query. FTS found entry 5 through a one-word overlap I did not anticipate.

Triples missed because no entity name contains "tools," "find," or "startup." Vector found it via semantic similarity. FTS found it via stemming. The prediction was wrong about FTS, right about triples.

## The failure modes

**Triples fail when** the query uses vocabulary absent from entity names. Triples search entity names via LIKE, so they only find queries that share substrings with extracted entities. Query C1 uses "tools" and "startup" — neither appears in any entity name. Additionally, triples fail when the extraction model does not produce the relevant relationship in the first place. B2 demonstrates this: the same source text produces different entity graphs across runs.

**FTS fails when** the query shares zero stems with stored content. Query C3 has five content words — "preventing," "agent," "remembering," "useless," "things" — none of which stem to any token in the relevant entry. Porter stemming bridges morphological variants ("tools" → "tool," "crashed" → "crash") but cannot bridge synonyms ("useless" → "trivial," "startup" → "runtime").

**Vector fails when** it needs to signal absence. The embedding model always returns neighbors. Query B3 returns 10 entries despite zero relevance. In a 10-entry corpus this returns everything; in a larger corpus it returns the 10 least-irrelevant entries. Without a distance threshold, the agent cannot distinguish "found something relevant" from "found the nearest noise."

## What the union buys

Remove triples: queries A1–A3 still return results via FTS and vector, but as full paragraphs instead of structured facts. The agent loses `spill → lives in → repo` and gets a paragraph it must parse. For downstream reasoning, structured facts are higher signal.

Remove FTS: queries B1, B2, and B4 still return results via vector. But FTS's precision is deterministic — if the token exists, it matches. Vector's precision depends on embedding quality and has no off switch. For exact-term lookups like `gsub` or `valid_until`, FTS is the reliable path.

Remove vector: queries C3 and D2 return nothing. No amount of keyword matching or entity traversal bridges "preventing the agent from remembering useless things" to "trick extracted 14 memories... trivial operational details." These queries go completely dark.

The union is not redundancy. It is coverage across three orthogonal failure modes: vocabulary gaps (triples), synonym gaps (FTS), and relevance-floor gaps (vector). Each channel's weakness is another channel's strength.

## The open defect

The vector channel has no relevance floor. FTS returns nothing when no keyword matches. Triples return nothing when no entity name matches. Both channels can signal absence. Vector cannot — it always returns the k nearest neighbors, even when the nearest neighbor is noise.

B3 demonstrates this concretely: a query about FTS5 tokenizer internals retrieves all 10 entries from a corpus that contains nothing about FTS5 tokenizer internals. The agent receives these entries as context and has no signal that none of them are relevant.

The fix is a distance threshold — filter out vector results above some cutoff before returning them. The right cutoff depends on nomic-embed-text's distance distribution across relevant and irrelevant query-entry pairs, which varies with corpus size and content. Setting it requires a separate tuning experiment with a larger corpus: measure distances for known-relevant matches and known-irrelevant matches, find the separation point, and determine whether it generalizes. That experiment is next.

## Limits

The corpus is 10 entries. A larger corpus would change vector behavior substantially — with 10,000 entries, the top-10 nearest neighbors would be more selective, and the false-positive problem (B3) might diminish or might surface differently. The experiment does not test this.

Triple extraction uses gemma3:1b at default temperature. The extracted entity graph varies between runs (47–49 active relations from the same 10 entries). A different extraction model or constrained decoding would change which queries triples can answer.

The embedding model is nomic-embed-text. A different model (e.g., mxbai-embed-large, or a fine-tuned variant) might change which semantic bridges succeed. The experiment tests one model.

No distance threshold was applied to vector results. Adding one would address the false-positive problem but might also suppress true positives at the margin. The threshold was not tuned because the experiment's goal was to characterize the channels as they currently operate, not to optimize them.

Reranking was not isolated. Crib applies reranking when the combined output exceeds the token budget. In this experiment, the corpus was small enough that reranking never triggered. Whether reranking changes the union's behavior at scale is untested.
