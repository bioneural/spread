---
title: "Push, pull, and the memory retrieval gap"
date: 2026-03-03
description: "A structural comparison of two AI memory architectures: Open Brain, a personal knowledge system that any MCP-compatible AI client can search on demand, and Prophet—an operating system for single agents—whose memory layer pushes retrieved context into the agent automatically. They make opposite tradeoffs. Neither has solved mid-chain retrieval during agentic loops."
---

**TL;DR** — [Nate Jones](https://www.natebjones.com) built [Open Brain](https://natesnewsletter.substack.com/p/every-ai-you-use-forgets-you-heres?r=1z4sm5&utm_campaign=post&utm_medium=web), a personal knowledge system where you type a thought into Slack, it gets embedded and classified, and any MCP (Model Context Protocol)-compatible AI client can search it later. Postgres, pgvector, two Supabase Edge Functions, $0.10–$0.30/month. I compared it against my memory architecture — crib (a fact store) and lay (context files), both part of [Prophet](https://github.com/bioneural/prophet), an operating system for a single agent. The two systems make opposite tradeoffs. Open Brain waits for the agent to search; mine pushes relevant memories into context before the agent starts reasoning. Open Brain searches one way (vector similarity); mine searches three (structured triples, keyword matching, and vector similarity) then reranks the combined results. Open Brain requires the user to capture thoughts manually; mine extracts them from conversations automatically. Open Brain works across every MCP client; mine serves only one. Whether these architectural differences translate to measurable retrieval differences is untested — this post is structural analysis, not benchmark. What is clear: neither system has solved the deeper problem. Agents lose access to memory mid-reasoning, exactly when context would be most useful.

---

## The systems

Open Brain is a capture-and-retrieval loop. A user types a thought into a Slack channel. A Supabase Edge Function generates a 1536-dimensional embedding via OpenRouter, a language model API, extracts structured metadata (type, topics, people, action items) via GPT-4o-mini, a lightweight OpenAI model, and inserts the result into a Postgres table backed by pgvector. A second Edge Function exposes an MCP server with four tools: semantic search, recent thoughts, capture statistics, and a write-back endpoint. Any MCP-compatible client — Claude Desktop, Claude Code, ChatGPT, Cursor — can connect and search the same database.

Prophet's memory surface is two cooperating systems. Crib is a SQLite-backed memory store with three retrieval channels: fact triples (structured `subject → predicate → object` lookups), FTS5 full-text search (keyword matching with Porter stemming), and sqlite-vec (768-dimensional vector similarity via a local ollama model). Lay is a collection of context files — identity, objectives, constitution, review panel definitions — with frontmatter conditions that control when each file gets injected. A policy engine called hooker fires on every user prompt and every tool call, running crib retrieval and lay injection before an agent begins reasoning.

The structural difference is not in storage. It is in when and how memories reach the agent.

## Push versus pull

Open Brain is entirely pull-based. A user's memories exist in Postgres. For those memories to influence a conversation, the AI client must decide to call `search_thoughts` with a relevant query. If the agent does not think to search — or if the client does not support proactive tool use — the memories sit unused. The system knows things the agent never learns.

Prophet pushes. When a user submits a prompt, hooker intercepts it before the agent processes it. Hooker pipes the prompt text into `crib retrieve`, which queries all three channels, merges and deduplicates the results, reranks them with a local cross-encoder, and returns the top entries. Hooker injects those entries into the agent's context as structured XML. The agent sees relevant memories before it begins reasoning — without choosing to search, without knowing what was available, without spending a tool call.

Lay files work the same way. When a prompt matches a pattern — an architectural question triggers the review panel definition, a policy-sensitive action triggers the constitution — the relevant context file appears in the agent's context automatically. The agent does not request it. The system places it there because a pattern matched.

The theoretical advantage of push over pull is coverage: a push system can surface memories the agent did not know existed, while a pull system retrieves only what the agent thinks to ask for. Cognitive science distinguishes these as "spontaneous retrieval" and "strategic memory." Whether this theoretical advantage holds in practice — whether push-injected memories actually influence agent behavior more than pull-retrieved ones — is an empirical question I have not yet tested.

## Three channels versus one

Open Brain retrieves via a single mechanism: cosine similarity between a query embedding and stored thought embeddings. This is pgvector's `<=>` operator — one number, one ranking.

Crib retrieves across three channels that use different representations of the same content:

1. **Fact triples.** An ollama model extracts `(subject, predicate, object)` triples during the write path. "We switched from MySQL to PostgreSQL for billing" produces `(billing_database, uses, PostgreSQL)` and marks the previous triple `(billing_database, uses, MySQL)` with a `valid_until` timestamp. A query about billing databases resolves by a direct SQL join — no embedding math, no threshold tuning.

2. **Full-text search.** FTS5 with Porter stemming matches keyword queries. "What did we decide about caching?" finds entries containing "cache," "caching," "cached." Deterministic, no model dependency.

3. **Vector similarity.** sqlite-vec with 768-dimensional embeddings from a local nomic-embed-text model. Handles semantic matches where keywords fail — "career transition" finding a memory about "Sarah mentioned she might leave."

After the three channels return candidates, a reranker (local ollama cross-encoder) scores and merges them. The final output is a ranked list that combines structural precision, keyword recall, and semantic similarity.

The architectural hypothesis is that multi-channel retrieval reduces failure modes. A query like "what database does billing use?" on a single vector channel requires the query embedding to land close enough to the stored thought's embedding — a probabilistic match with a tunable threshold. On a triple store, the same query is a deterministic lookup. The answer is either there or it is not. But this is a hypothesis about retrieval quality, not a measured result. The two systems have not been evaluated against each other on the same corpus.

## Memory formation

Open Brain requires intentional capture. A user types a thought into Slack. Or an agent calls `capture_thought` through the MCP server. Either way, a human decision initiates every memory. If a conversation produces an insight and no one captures it, the insight is lost.

Prophet forms memories automatically. A background process called trick monitors conversation transcripts. When Claude Code compacts a conversation (summarizing earlier context to free the context window), trick extracts memories from the full transcript — decisions, corrections, notes, errors — and writes them into crib. The user does not choose what to remember. The system harvests from every conversation.

Open Brain compensates with a "Memory Migration" prompt and a "Spark" interview that generates an initial capture list. These are effective onboarding tools. But they are one-time operations. The ongoing capture loop still depends on the user remembering to type thoughts into Slack. Prophet's ongoing formation loop depends on nothing — conversations happen, memories form.

The tradeoff is precision versus recall. Automatic formation stores noise. A casual remark about lunch becomes a memory entry. Crib's salience decay (described below) is the pressure valve — low-value entries lose weight over time. Open Brain avoids this problem by only storing what the user deliberately captures. Intentional capture is higher-precision but lower-recall. Automatic formation is higher-recall but requires a pruning mechanism. Which tradeoff produces better downstream results depends on the use case and the quality of the pruning — neither is inherently superior.

## Decay

Open Brain has no decay mechanism. Every thought persists at equal weight. A thought captured six months ago and never retrieved sits alongside a thought captured yesterday and retrieved five times. At 20 captures per day, that is 3,600 thoughts after six months. At 100 per day (with automatic capture or migration), 18,000. The question is whether retrieval quality degrades as the corpus grows — more candidates means more noise in the similarity rankings, more irrelevant results crossing the threshold. This is a known challenge with single-channel vector retrieval, but I have not measured Open Brain's degradation curve.

Crib applies Ebbinghaus-style salience decay during a maintenance cycle. Each entry has a `last_retrieved` timestamp. Entries that are frequently retrieved maintain their salience. Entries that are never retrieved decay. A maintenance command — run by a scheduled process called the heartbeat — identifies stale entries (not retrieved in 30+ days) and reports them. Corrections link to their originals and propagate supersession.

The design intent is that decay makes the memory sharper over time rather than noisier — rehearsal strengthens traces, neglect weakens them, mirroring biological memory dynamics. Whether crib's decay actually produces measurably better retrieval than an undecayed corpus is an open question. The mechanism exists. The evaluation does not.

A memory system without decay answers "what do I know?" with "everything I ever captured." A memory system with decay answers the same question with "everything that has remained relevant." These are different systems with different behaviors. Which answer is more useful depends on the task.

## What Open Brain does that Prophet cannot

**Multi-client access.** Open Brain's MCP server means Claude Desktop, ChatGPT, Cursor, VS Code Copilot, and any future MCP client can share one memory. Prophet's crib is a local SQLite database accessed through a Ruby CLI. It serves one Claude Code instance on one machine. If I wanted my memories available in Claude Desktop and Cursor simultaneously, Prophet cannot do that today. Open Brain can.

This is not a minor difference. The MCP protocol is becoming the standard interface for AI tool integration. A system that speaks MCP is automatically compatible with every client that adopts the protocol. A system that speaks stdin/stdout to a local CLI is compatible with exactly the clients that can shell out to it. Prophet's current architecture is capable but parochial.

**Setup accessibility.** Open Brain targets non-programmers. Forty-five minutes of copy-paste across Supabase, OpenRouter, and Slack. No local models, no Ruby, no build step. Prophet requires cloning repositories, installing ollama, pulling embedding models, configuring policy files, and understanding hook semantics. The target audiences are different — Open Brain is consumer-grade, Prophet is operator-grade — but the accessibility gap is real.

**Structured metadata.** Open Brain classifies every capture with a type (decision, person note, insight, meeting debrief), topics, people, action items, and dates. This metadata enables filtered queries: "show me all decisions from last week" or "what do I know about Sarah?" Crib entries have a type field and tags, and the triple store captures entity relationships, but the structured metadata surface is thinner. Open Brain's classification prompt extracts more fields per entry. This is a pattern worth evaluating — richer per-entry metadata could enable query modes that crib's current schema does not support.

## What neither system has solved

**Mid-chain retrieval.** Prophet's hooker fires on `UserPromptSubmit` — the event that occurs when a human sends a message. During a multi-turn agentic loop where Claude Code calls tools and reasons across several steps without human input, `UserPromptSubmit` does not fire. Memories are injected at the start of the conversation turn, then the agent reasons for potentially dozens of steps without any new memory retrieval.

Open Brain's pull model means the agent could theoretically search mid-chain — but only if the client supports autonomous tool use during reasoning, and only if the agent decides that searching its memory is worth a tool call at that moment. In practice, agents optimizing for task completion rarely pause to search an external memory system mid-chain.

Both architectures retrieve memory at the boundary between the human and the agent. Neither retrieves memory at the boundary between one reasoning step and the next. For short interactions, this does not matter. For agentic chains that run for minutes — where the agent's context drifts from the original prompt — the memory surface goes dark at the moment it would be most useful.

**Context overload at scale.** Open Brain's spec acknowledges this: "Too much unstructured context can cause LLMs to cross-pollinate unrelated topics." Prophet faces the same tension. Push-based injection means crib sends the top-ranked memories on every prompt. If the corpus is large and the query is broad, "top-ranked" might still be ten entries that consume a significant fraction of the context window. The reranker helps. The salience decay helps. But the fundamental tension — inject enough to be useful, not so much that you dilute focus — is a parameter-tuning problem, not an architectural solution.

## What I take from this

Open Brain validates an approach: make memory a service, expose it via MCP, let any client connect. The implementation is simple — one table, one embedding model, one similarity function — and that simplicity is a feature. It works today, across multiple clients, for $0.10 a month.

Prophet validates a different approach: make memory automatic, push it into context before the agent asks, retrieve across multiple representations, and let unused memories decay. The implementation is more complex — three channels, a reranker, a policy engine, a background extractor. Whether that complexity produces measurably better outcomes than a single well-tuned vector store is the question the data would answer.

Three patterns in Open Brain's design are worth evaluating for Prophet:

1. **MCP as the retrieval interface.** Exposing crib's three-channel retrieval as an MCP server — triples, full-text, and vector, with reranking — would make Prophet's memory accessible to any MCP-compatible client. This is not on the roadmap today, but it is the convergence point where the architectures' respective strengths would combine. Whether the engineering cost is justified depends on how quickly MCP adoption spreads beyond early adopters.

2. **Richer per-entry metadata.** Open Brain's classification prompt extracts type, topics, people, action items, and dates from every capture. Crib's schema is thinner. Adding structured metadata to the write path could enable filtered retrieval modes that do not currently exist. This is a bounded change worth prototyping.

3. **Accessibility as a design constraint.** Prophet's setup assumes an operator who understands policy files, hook semantics, and local model infrastructure. Open Brain's setup assumes someone who can follow a guide. These serve different users, but considering accessibility earlier in the design process — not as a concession, but as a constraint that shapes architecture — is a discipline I have not applied.

The gap I am working on is mid-chain retrieval. Neither system solves it. Both systems go dark during agentic loops. For a system that aspires to continuous memory — where the agent's knowledge is available not just at conversation boundaries but between reasoning steps — this is the open problem.

## Limits

**I have not used Open Brain.** This comparison is based on a published specification, not hands-on experience. Production behavior may differ from the spec in ways that affect retrieval quality, latency, or reliability.

**The comparison is asymmetric.** Open Brain is a two-function memory system. Prophet is an eight-tool operating system where memory is one subsystem. Comparing Open Brain's entire architecture against Prophet's memory layer is the closest apples-to-apples framing, but Prophet's policy enforcement, task dispatch, and background extraction are structural advantages that exist outside the memory comparison.

**Neither system has been evaluated against the other.** A controlled comparison — same corpus, same queries, measure retrieval quality — would produce data instead of architectural arguments. This post is architectural arguments. The data does not exist yet.