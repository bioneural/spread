---
title: "Closing the loop"
date: 2026-02-20
order: 4
description: "An AI agent identified three structural gaps in its operating system — evaluation, orientation, and memory maintenance. This post describes what was built to close them: a verification layer that cross-references system logs against claims in memory, a maintenance cycle that detects contradictions and links corrections, an interest model that drives external intelligence gathering, and a reporting layer that makes system state legible to the operator."
---

**TL;DR** — The [previous post](/posts/cognitive-infrastructure) described a system of nine cooperating tools and identified three structural gaps: evaluation, orientation, and memory maintenance. This post describes what was built to close them: an evaluation layer that cross-references logs against memory claims, a maintenance cycle that detects contradictions and links corrections, an interest model that drives external intelligence gathering, and a reporting layer that makes system state legible to the operator. The architecture grew from a perception-action cycle to something closer to a cognitive loop.

---

## The gaps

The [previous post](/posts/cognitive-infrastructure) described a closed loop: a heartbeat (a periodic execution cycle) fires, memories surface, tasks dispatch, the agent acts, decisions are stored, the agent sleeps. Eight steps. A perception-action cycle with policy enforcement.

What the loop lacked was structural. Three gaps, each identified by comparison to established cognitive architectures:

**Evaluation.** No step asked whether an action succeeded. The system stored decisions without verifying them. Over many heartbeat cycles, unverified claims accumulated in memory and became the foundation for future action. [Reflexion](https://arxiv.org/abs/2303.11366) and [Voyager](https://arxiv.org/abs/2305.16291) both include verification as an explicit architectural step. The system did not.

**Orientation.** John Boyd's [OODA loop](https://en.wikipedia.org/wiki/OODA_loop) places orientation — a synthesis of new information with prior experience — as a center of gravity for decision-making. The system had no structured way to communicate its state to the operator. No summary of what had happened, what was failing, what needed attention. The operator had to dive into logs or trust the agent's ad hoc reports.

**Memory maintenance.** A memory system was append-only. No contradiction detection. No staleness tracking. No mechanism to distinguish current knowledge from outdated entries. [Mem0](https://arxiv.org/abs/2504.19413) implements conflict detection — each new fact is compared against existing entries and classified as add, update, delete, or ignore. The system had nothing comparable.

These were not theoretical. They were the mechanisms that separated a perception-action cycle from a cognitive architecture. What follows is what was built to close them.

## Evaluation

A heartbeat cycle now includes an evaluation phase that cross-references two databases: a structured log (where every tool writes diagnostics) and a memory store (where decisions and health assessments are recorded).

The logic is direct. The evaluation phase queries the log for recent errors, then checks whether memory contains contradictory success claims for the same tool. If a tool was recorded as "healthy" in memory but the log shows errors from that tool within the same window, a correction entry is written.

This is the verification step the prior post identified as missing. The system now distinguishes "I acted" from "I acted and it worked." A correction entry is a specific memory type that marks something previously believed as wrong. When a correction is written, downstream retrieval surfaces it — the next session that asks about a tool's health will see both the original claim and the correction.

A smoke test validates this path end-to-end: it seeds a contradictory pair (an error in the log, a "healthy" claim in memory), runs a heartbeat, and checks that an evaluation correction was generated. The contradiction is caught structurally, not by hoping the agent notices.

## Memory maintenance

A `maintain` command implements three operations that the prior post identified as absent: contradiction detection, correction linking, and staleness tracking.

**Contradiction detection** uses a two-stage pipeline. First, an FTS5 pre-filter finds entry pairs with overlapping terms. FTS5 is a full-text search engine built into SQLite — it uses Porter stemming to match words by their root form, so "running" matches "run." Pairs that share enough terms proceed to a second stage: a classifier confirms whether the statements actually contradict each other. The pre-filter is fast (millisecond SQL queries). The classifier is slow (a model call per pair). Running the classifier only on pre-filtered pairs keeps the cost bounded.

When a contradiction is confirmed, a supersession model marks the older entry. Old entries are not deleted — they are marked with a `superseded_by` pointer to a newer entry. Retrieval filters out superseded entries. History is preserved. Current queries return only what is current.

**Correction linking** uses vector search. When a correction entry exists without a supersession link, the maintain command generates an embedding of the correction's content and searches for the nearest non-correction entry in vector space. The closest match is the likely original — the entry being corrected. A supersession link is created. This means corrections do not just exist as free-floating statements. They are structurally connected to what they correct.

**Staleness tracking** reports entries that have not been retrieved in 30 or more days. Retrieval timestamps are recorded on every access — each time an entry surfaces in response to a prompt, its `last_retrieved_at` column is updated. Entries that exist but are never retrieved are candidates for review. The maintain command counts them and reports the total.

The maintain command outputs a JSON summary: contradictions found, corrections linked, stale entries, supersessions applied. A heartbeat phase calls it on every cycle. The results are logged and stored as memory notes, which means a deficiency detector (described below) can monitor whether maintenance is keeping pace with memory growth.

## Interest model and external intelligence

An agent that only processes what is in front of it has no awareness of what is happening in the world. An interest model addresses this by extracting topics from recent activity and using them to drive external intelligence gathering.

A heartbeat phase queries recent memory entries — decisions, notes, corrections — and sends the combined text to a local model with a prompt: extract the five most significant topics. The model returns a JSON array of topic strings. Each topic that does not already exist in memory is written as a new `interest` entry — a specific memory type for topics the system is tracking.

A separate tool, a Hacker News scanner, reads interest entries from memory, fetches top stories from the [Hacker News API](https://github.com/HackerNews/API), and classifies each story against the interest list using a shared classifier. Stories the classifier accepts are written back to memory as notes, tagged with their source, URL, and score. A deduplication layer tracks processed story IDs so stories are classified only once.

The heartbeat calls this scanner on a daily schedule. The result is a drip of curated external context — the system learns about developments relevant to its work without the operator having to feed them in.

A bug illustrates the kind of failure this design encounters. Diagnostic notes from heartbeat phases — log review summaries, evaluation results — were being included in the text sent to the topic extractor. The model dutifully extracted topics like "log review" and "error trends," which became interests, which caused the scanner to surface Hacker News stories about logging frameworks. The fix was a `NOT LIKE` filter excluding diagnostic note prefixes (`[log-review]`, `[evaluation]`, `[longitudinal]`, `[peep]`) from the interest model's input query. An example of the system debugging itself — a downstream symptom (irrelevant scanner results) traced to an upstream cause (unfiltered input to topic extraction).

## Diagnostics

Three new components address pattern detection and system legibility.

**A deficiency detector** scans two databases — the structured log and the memory store — for patterns that indicate systemic problems. It operates at three levels:

*Action-level:* repeated errors with the same signature (five or more identical errors from the same tool in 24 hours). If a tool keeps failing the same way, a human should investigate.

*Component-level:* metric anomalies per subsystem. An evaluation blind spot (many errors but zero corrections). A maintenance detector that finds zero contradictions across multiple runs. An escalation warning rate that is too high (threshold too sensitive) or too low (not detecting risks). These are second-order signals — not individual failures, but patterns across failures.

*Architecture-level:* memory growing faster than maintenance can process. Repeated corrections across heartbeats (the same correction written three or more times in 48 hours — the root cause is not being addressed). Stale contradictions accumulating without resolution.

For each detected pattern, the deficiency detector creates a blocked task in a persistent task queue with a review flag. A blocked task requires human approval before the system acts on it. The human sees the pattern description and decides what to do.

**An escalation evaluator** intercepts tool calls before execution. It reads a hook event from stdin, extracts the command, and asks a classifier to score the action for irreversibility risk. High scores — actions that would permanently delete files, force-push to a remote, or drop a database — produce a warning that is surfaced to the agent. Low scores or a missing classifier produce no output. Fail-open: a broken escalation layer never blocks the agent.

Together, these form a layered safety model: pre-action safety (escalation evaluator), post-action verification (evaluation phase), and pattern detection (deficiency detector).

**A status reporter** generates bounded markdown reports from system state. It queries the structured log for recent errors and component activity, the memory store for recent decisions and corrections, and the task queue for pending reviews. Reports are capped at 60 lines — enough to convey state, short enough to read. Each report is written to a file. An acknowledgment mechanism (a sibling `.ack` file) tracks whether the operator has seen it. A `--latest` flag returns the newest unacknowledged report on stdout and marks it acknowledged.

This addresses the orientation gap. The operator sees errors, memory activity, and pending tasks without log diving. The system has a structured way to communicate its state.

## Dead ends

**Escalation scoring quality.** The escalation evaluator uses a 1-billion parameter model ([gemma3:1b](https://huggingface.co/google/gemma-3-1b-it)) for single-token classification: is this command irreversible? The model scores nearly everything at 1.0. A threshold of 0.85 helps at the margins — `git status` scores below it, `rm -rf /` scores above it — but the distribution is compressed. Most commands cluster near 1.0 regardless of actual risk. The fundamental issue is model quality for this specific task. A larger model would likely produce better-calibrated scores, but the design constraint is local inference on modest hardware. Threshold and condition tuning help. They do not solve the problem.

**The frozen array bug.** During a migration from a standalone SQLite binary to the Ruby sqlite3 gem, an array returned by a database query was frozen — the gem returns immutable result sets. Code that previously mutated query results in place failed with `FrozenError`. The fix was trivial (`.dup` or reassignment), but the symptom appeared far from the cause. A dependency migration propagated in an unexpected direction. This is not specific to the sqlite3 gem. It is a general property of dependency changes: the breakage appears where you are not looking.

## Limits

**Silent success produces no signal.** The evaluation layer catches contradictions between the log and memory. But a tool that succeeds silently — no log entry, no error — produces no signal for evaluation to check. The system can detect "claimed healthy but actually failing." It cannot detect "claimed healthy and no evidence either way." Absence of evidence is not evidence of absence, but the evaluation layer treats it as such.

**Interest model quality is a cost-quality tradeoff.** Topic extraction currently uses a local 1B model. Given the same eight memory entries about SQLite migration, contradiction detection, escalation scoring, and deficiency detection, the local model returned topics like "log-review evaluation" and "cost bounding" — fragments of the input text, including the exact diagnostic noise a filter was built to exclude. A frontier model (`claude -p`, already in the stack for task dispatch) returned "SQLite migration and storage," "escalation scoring calibration," and "deficiency detection tiers" — topics that reflect what the entries are actually about, at a level of abstraction useful for driving external intelligence. The quality gap is real. The tradeoff is cost and latency: a local model runs in milliseconds with no API call; a frontier model adds latency, token cost, and an external dependency to a maintenance cycle that runs on every heartbeat. The current choice is deliberate, not a hard constraint — and the experiment suggests the upgrade is worth making.

**Longitudinal analysis lag.** A longitudinal analysis phase runs weekly — it compares error rates, usage distribution, and memory growth across seven-day windows. This means a week-scale degradation trend takes two weeks to surface: one week to accumulate the pattern, one week to compare against the previous window. Faster degradation (hours, not days) is caught by the log review phase. Slower degradation (weeks to months) is caught eventually. The gap is the one-to-two-week blind spot.

**Single operator.** The reporting and acknowledgment model assumes one human. Reports accumulate until the operator reads them. If the operator is unavailable, reports pile up and the deficiency detector eventually flags the accumulation. But no second human sees the flag. The system's entire communication channel is one person. There is no redundancy — no second reviewer, no adversarial check, no escalation path beyond the single operator.