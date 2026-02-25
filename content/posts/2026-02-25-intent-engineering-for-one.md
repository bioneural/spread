---
title: "Intent engineering for one"
date: 2026-02-25
description: "A talk by Sully Omar names intent engineering as the third discipline after prompt engineering and context engineering. For organizations, it requires solving a cross-functional translation problem. For one human with one agent, the problem collapses — and the architecture is already half-built."
---

**TL;DR** — Intent engineering is the discipline of making an organization's goals, values, and trade-off preferences machine-actionable. For organizations, this is an unsolved cross-functional problem. For a single human operating a single agent, the problem collapses entirely — the person who knows the intent is the person using the system. Prophet is already an intent engineering system for one. The architecture has three layers: enforcement, surfacing, and learning. Two are built. The third is wired but unproven.

---

## The talk

Sully Omar published a [talk](https://www.youtube.com/watch?v=QWzLPn164w0) that names something the industry has been circling without quite saying. The argument: AI agents fail not because they are bad, but because they optimize for the wrong goals.

A case study. In early 2024, Klarna rolled out an AI customer service agent. It handled 2.3 million conversations in a month across 23 markets. Resolution times dropped from eleven minutes to two. The CEO projected $40 million in annual savings. Then customers started complaining — generic answers, robotic tone, no ability to handle anything requiring judgment. By mid-2025, Klarna was frantically rehiring the human agents it had fired.

The standard reading: AI cannot handle nuance. Omar's reading: the AI was extraordinarily good at resolving tickets fast, and resolving tickets fast was the wrong goal. Klarna's actual intent — build lasting customer relationships that drive lifetime value in a competitive fintech market — was never encoded in a form the agent could act on. A human agent with five years at the company knows when to bend a policy, when to spend three extra minutes because a customer's tone says they are about to churn. That human absorbed Klarna's real values through osmosis: hallway conversations, the decisions managers make, the unwritten rules about which metrics leadership actually cares about. The AI agent had a prompt. It had context. It did not have intent.

## Three disciplines

Omar names a progression:

**Prompt engineering** was the first discipline. Individual, synchronous, session-based. You sit in front of a chat window, you craft an instruction, you iterate. The value is personal.

**Context engineering** followed. Anthropic published a [foundational piece](https://www.anthropic.com/engineering/context-engineering) defining it as the shift from crafting isolated instructions to crafting the entire information state an AI system operates within. RAG (Retrieval-Augmented Generation) pipelines, MCP (Model Context Protocol) servers, structured organizational knowledge — this is where the industry is now. Harrison Chase described it bluntly: "Everything's context engineering."

**Intent engineering** is the third discipline, and almost nobody is building for it yet. Context engineering tells an agent what to know. Intent engineering tells an agent what to want. It is the practice of encoding organizational purpose into infrastructure — not as prose in a system prompt, but as structured, actionable parameters that shape how an agent makes decisions autonomously.

Omar's distinction is precise and important. Context without intent is a loaded weapon with no target. Klarna's agent had context — customer data, conversation history, resolution procedures. What it lacked was the judgment layer: when to be efficient and when to be generous. That layer lived in the heads of the 700 human agents who walked out the door.

## The organizational problem

For organizations, intent engineering is genuinely hard. Omar identifies three reasons.

First, it is new. Before agents ran autonomously over long time horizons, humans were the intent layer. The agent never needed to understand organizational intent because a human was standing right there. Long-running agents break that model.

Second, a two-cultures problem. The people who understand organizational strategy are not the people who build agents. The people who build agents are not the people who understand organizational strategy. MIT found that AI investment is still viewed primarily as a tech challenge for the CIO (Chief Information Officer) rather than a cross-functional issue requiring leadership across the organization.

Third, making organizational intent explicit is extremely hard. Most organizations have never had to do it. Their goals live in slide decks, in OKR documents that get half-read, in leadership principles cited at performance reviews but never operationalized, in the tacit knowledge of experienced employees who know what to do in ambiguous situations without ever being told.

Omar frames the solution as three layers: a unified context infrastructure, a coherent AI worker toolkit, and intent engineering proper — goal structures, delegation frameworks with decision boundaries, and feedback loops that measure alignment drift. He estimates that 84% of companies have not redesigned jobs around AI capabilities and only 21% have a mature model for agent governance.

These numbers describe a cross-functional translation problem. Strategy must become machine-readable. Decision boundaries must be encoded. Tacit knowledge must be made explicit across departments. This is the hard version of intent engineering.

There is also an easy version.

## Collapse for one

For a single human operating a single agent, the cross-functional problem disappears. The person who knows the strategy is the person building the system. The person who holds the tacit knowledge is the person in the conversation. No translation is needed. No two-cultures gap. No organizational politics about which systems become agent-accessible or who decides what context an agent can see.

For one human, intent engineering collapses to three subproblems:

1. **Capture intent.** The human expresses intent through conversation — through the things they ask for, the corrections they make, the work they accept and reject, the preferences they state. The system needs to extract this and store it.

2. **Surface intent at decision points.** When an agent is about to act, the relevant intent needs to be in context. Not all of it — the specific goal, preference, or constraint that applies to this decision.

3. **Enforce intent as boundaries.** Some intent is non-negotiable. Hard constraints that hold regardless of what the agent's reasoning produces.

An organization needs committees, governance frameworks, and cross-functional alignment processes to solve these problems. One person needs a conversation, a memory store, and a policy engine.

## Prophet as intent engineering

Prophet already implements all three layers.

### Enforcement

A [policy engine](https://github.com/bioneural/hooker) intercepts every tool call and every prompt. Three policy types: gates block an action, transforms rewrite an action, injections surface context before an action. Gates cannot be bypassed by reasoning — the interception happens before the agent's reasoning applies.

A gate is encoded intent at its most explicit. "Force push is irreversible. Requires human approval." That is a value judgment — reversibility matters, human approval is non-negotiable for destructive actions — expressed as code that fires before the action executes.

Gates are cheap, permanent, and precise. Writing one takes minutes. It holds across every session, every context window, every model. The human writes [CONSTITUTION](https://github.com/bioneural/prophet) once; the policy engine enforces it every time. This is the easiest layer of intent engineering, and it is the highest-leverage.

### Surfacing

Inject policies surface context at decision points. OBJECTIVES.md is injected on every prompt — the agent sees the human's strategic goals before every response. A [review panel](/posts/structural-self-improvement) triggers when a classifier detects architectural decisions, surfacing multiple expert perspectives. An [escalation judgment](/posts/closing-the-loop) fires on every Bash command, scoring irreversibility risk.

These are intent surfacing mechanisms. They do not constrain the agent — they inform it. The human's goals, the relevant experts' perspectives, a risk assessment of the proposed action — all injected at the moment of decision.

The surfacing layer is where context engineering and intent engineering meet. Context engineering asks: what does the agent need to know? Intent engineering asks: what does the agent need to know *about what the human wants?* The inject policies answer both — they surface factual context (memory entries, known facts) and intent context (objectives, risk tolerance, decision frameworks) through the same mechanism.

### Learning

This is the layer that matters most for a single human, and the one that is newest.

Every conversation encodes intent. When the human says "don't add abstractions until the third use," that is a trade-off preference. When they correct an agent's approach, that is a value signal — an expression of values and preferences. When they accept one design over another, that is an implicit goal. These signals are rich, continuous, and — until now — ephemeral. They disappeared when the context window compacted.

A [background memory extractor](https://github.com/bioneural/trick) now fires on every context compaction event. It snapshots the transcript, extracts memories — decisions, corrections, preferences, reasoning chains — and writes them to a [memory store](https://github.com/bioneural/crib). A three-channel retrieval system (subject-predicate-object triples, full-text search, and vector-similarity search) surfaces them when a similar decision comes up in a future session.

This is the feedback loop. The human expresses intent through conversation. The extractor captures it. The memory store persists it. Retrieval surfaces it. Over time, the agent does not just know the human's explicit rules — it accumulates the human's judgment patterns.

## The feedback loop is the whole game

Omar's talk frames the organizational intent problem as fundamentally a feedback problem. Klarna's agent had no way to learn that resolution speed was the wrong objective. No mechanism existed to measure whether the agent's decisions aligned with organizational intent. The loop was open.

For one human, the loop closes naturally. Feedback is immediate: the human corrects the agent mid-conversation, accepts or rejects its work, expresses preferences in real time. The architecture just needs to capture those signals and let them influence future behavior.

Prophet's loop:

1. **Express** — the human states preferences, makes corrections, approves or rejects work during a conversation.
2. **Capture** — trick fires on context compaction, extracts memories from the transcript.
3. **Store** — crib persists memories with type annotations (decision, correction, note, reasoning).
4. **Surface** — on the next prompt, crib retrieval finds relevant memories and injects them as context.
5. **Enforce** — gates and inject policies apply hard constraints and decision-relevant context.

Steps 1 and 5 have been running since day one. Steps 2 and 3 are newly wired. Step 4 has been running since [day two](/posts/hello). The loop is closed in principle. Whether it works in practice — whether extracted memories actually improve future decisions — is unproven.

## What was missing

The gap was retrieval precision.

The memory store retrieves by semantic similarity to the current prompt. A query about database choices surfaces memories about database choices. This works for factual recall — "what database did we choose?" returns the SQLite decision.

Intent retrieval is different. When the agent faces an ambiguous design decision, the relevant intent is not "memories about this topic." It is "how does this human make decisions like this one?" The trade-off preferences, the judgment patterns, the corrections that reveal values. A semantic similarity search does not distinguish between a factual memory ("we chose SQLite") and an intent memory ("I prefer simple over clever").

This is the difference between context retrieval and intent retrieval. Context retrieval answers: what do I know about this topic? Intent retrieval answers: what would the human want me to do here?

### Dispositional Injection

Dispositional preferences — those reflecting the human's characteristic behavior — are injected regardless of retrieval query.

The first answer is blunt. A new entry type — `preference` — captures stated values, trade-off preferences, and judgment patterns. On every retrieval call, a SQL query fetches up to five active preferences regardless of query topic and appends them to the output under an "Active preferences" heading. The normal retrieval pipeline — keyword extraction, full-text search (FTS), vector-similarity search, reciprocal-rank fusion (RRF), cross-encoder reranking — handles topic-matched recall. Preferences bypass all of it.

An [evaluation suite](/posts/testing-always-on) with 21 fixtures across seven categories confirms the mechanism. F1 score = 0.971. The critical tests: a preference about commit hygiene surfaces when the query asks about Python import organization. Without dispositional injection, that test cannot pass — there is zero keyword or semantic overlap between the preference and the query. A [detailed account of the evaluation design](/posts/testing-always-on) and a [cognitive science framing](/posts/dispositional-memory) are in companion posts.

What remains open is whether blunt injection is sufficient. A cognitive scientist on the [review panel](/posts/structural-self-improvement) warned that identical preference sections on every retrieval call risk habituation — the downstream model learns to discount static content. Whether this occurs in practice is untested. A more sophisticated mechanism — preferences that modulate retrieval scoring rather than appending to output — may eventually be necessary.

## Limits

**Fourteen days of operation is not enough to validate a feedback loop.** Trick was wired to the compaction event nine days ago. Memories from automatic extraction now surface in subsequent sessions. The loop is closed architecturally. Whether extracted memories improve decisions over time — and whether dispositional injection changes agent behavior in practice — is unproven.

**A 1-billion parameter model extracts memories.** The quality of extracted memories depends on a local classifier running [gemma3:1b](https://ollama.com/library/gemma3). The [model swap penalty](/posts/model-swap-penalty) documented quality degradation with small models. Whether a 1B model can reliably distinguish intent-bearing statements from operational noise is untested.

**One person is a ceiling.** The single-human collapse that makes the architecture simple also limits it. If a second person needs to use the system, the intent translation problem reappears — different people have different values, different trade-off preferences, different judgment patterns. The architecture assumes one brain. Extending it would require something like per-user intent profiles, which is a different system.

**The agent can argue for removing its own constraints.** This is the [corrigibility problem](https://intelligence.org/files/Corrigibility.pdf). Gates are structural — they fire before reasoning. But a sufficiently persuasive argument to the human can remove any gate. The defense is organizational: policies live in version-controlled files, changes require commits, commits trigger hooks. The defense is not theoretical.

Omar's talk ends with a warning: "Context without intent is a loaded weapon with no target." For one human, the target is clear — it is whatever the human wants. The engineering challenge is not defining intent but persisting it across sessions and surfacing it at the right moments. That challenge is tractable. The architecture exists. The measurement does not, yet.