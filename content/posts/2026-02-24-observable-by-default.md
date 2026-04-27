---
title: "Observable by default"
date: 2026-02-24
order: 5
description: "Prophet — an AI agent's operating system — had no way to prove it was working correctly. Five additions — an evaluation harness (testing framework), a central dispatch module (infrastructure consolidation), interaction surfaces (user-facing interfaces), a health aggregator (system health monitor), and a shared data layer (unified data access) — transformed it from a black box into an instrument panel."
---

**TL;DR** — Prophet had a structural blind spot: no way for the operator to verify correctness without reading databases directly. Five additions address this: an offline evaluation harness with majority voting across trials; a central dispatch module that enables test isolation; three interaction surfaces (CLI, web, MCP); a health aggregator that probes every module's diagnostic subcommand; and a shared data access layer that keeps all surfaces consistent. Observability as a design requirement, not an afterthought.

---

## The blind spot

The [previous post](/posts/closing-the-loop) described a cognitive loop: a heartbeat fires, memory surfaces, actions execute, results store. The loop had evaluation (cross-referencing logs against memory claims), maintenance (contradiction detection, correction linking), and diagnostics (deficiency detection, escalation scoring, status reports).

What it lacked was instrumentation. The operator could read reports — bounded markdown summaries — but could not query system state interactively. There was no way to search memory directly, no way to see which policy decisions fired on a given prompt, no way to verify that retrieval quality had not degraded after a model change. The system logged everything but exposed nothing.

This is a common failure mode in autonomous systems: internal state is rich, but the external interface is a file dump. The operator either trusts the system or reads raw databases. Neither scales.

## Evaluation harness

The most important addition is an offline evaluation framework that measures the three model-dependent subsystems: retrieval, classification, and extraction.

Each subsystem has a YAML (a data serialization format) fixture file containing known inputs and expected outputs. A retrieval fixture seeds a memory store with specific entries, runs a query, and checks whether results contain expected terms. A classification fixture provides a condition and content, expecting a yes/no decision. An extraction fixture provides a transcript and checks whether an extractor produces the expected number and content of memory entries.

Each test case runs N trials (default three). A majority vote across trials determines pass or fail. This handles the fundamental challenge of evaluating stochastic systems: a classifier might return "yes" twice and "no" once for the same input. A majority vote treats two out of three as a pass, not a flake.

Results report precision, recall, and F1 per suite. The harness exits zero if all suites pass, nonzero otherwise.

The design choice that matters: this tests behavioral correctness, not code coverage. Code coverage tells you whether a line executed. An evaluation harness tells you whether a retrieval query returns the right memories after a model upgrade. These are different categories of measurement. For a system whose behavior depends on model outputs, behavioral measurement catches the regressions that matter.

## Central dispatch

Previously, each of the system's eleven command-line tools duplicated the same infrastructure: path resolution, database connections, logging, cross-tool communication. A central dispatch module now consolidates all of it into four capabilities:

**Path resolution** — constants for the project root, state directory, database paths, and sibling binary locations. No tool computes its own paths.

**Logging** — structured log entries to a logging database, with automatic stderr fallback if the database is unavailable.

**Database access** — SQLite3 (an embedded database) connections with consistent configuration: busy timeout for concurrent access, hash results for readable queries.

**Sibling dispatch** — calls other modules via `Open3.capture3` with automatic environment variable injection. Every cross-module call goes through one function, which means every call is loggable, mockable, and auditable.

The test benefit is the largest. A dispatch module maintains a stub registry — tests can mock sibling calls without running real binaries. A call history tracker lets tests assert that a tool called the right modules in the right order. This replaced ad hoc test isolation with a single mechanism.

## Interaction surfaces

Three surfaces now expose system state to different consumers.

**Command-line tools** provide quick checks: a single-line health summary (heartbeat age, memory count, pending tasks, recent errors) and a configuration lister (all governing documents and policy files).

**A web interface** runs on a stdlib-only HTTP server — no framework, no external dependencies, no JavaScript. It serves seven pages: a dashboard with health status and recent activity; a reports view with acknowledgment controls; a task manager; a review queue for human-in-the-loop policy decisions; a memory search interface; an objectives editor; and a policy audit trail showing which hooks fired and why.

The server binds to all interfaces on port 7700, which means it is accessible via [Tailscale](https://tailscale.com/) from any device on the tailnet. A 60-second auto-refresh keeps the dashboard current. The operator can check system health from a phone without SSH.

**A Model Context Protocol endpoint** exposes seven read-only tools via [JSON-RPC 2.0](https://www.jsonrpc.org/specification). External AI systems that support [MCP](https://modelcontextprotocol.io/) can query status, health, reports, tasks, memory, and logs without direct database access. This surface serves AI-to-AI interaction — a use case the web interface does not address.

All three surfaces read from a shared data access layer, described below.

## Health aggregator

A constitution section — a design requirement — requires every module to have a diagnostic subcommand. A health aggregator calls each one and merges the results into a single JSON object with a top-level pass/fail boolean.

The aggregator checks prerequisites (Ruby version, required packages, ollama and claude binaries), verifies that all sibling repositories are present and their diagnostic subcommands respond, validates policy syntax, checks heartbeat cron entries, probes the web server's health endpoint, and confirms Tailscale is running.

A cron job can call the aggregator and alert if the exit code is nonzero. Before this existed, verifying system health required manually checking each component.

## Shared data layer

A unified data access module sits between interaction surfaces and databases. It provides read and write methods for every entity — reports, tasks, reviews, memory entries, logs, policy decisions, configuration — using parameterized SQL queries against three SQLite databases.

Previously, each surface wrote its own SQL. The data access layer eliminates that duplication: a schema change requires updating one module, not three surfaces independently. Write operations route through the appropriate command-line tool via dispatch, preserving a single write path with consistent logging and error handling.

## Dead ends

**Stdlib HTTP parsing.** The web server parses HTTP requests by hand — headers line by line, query strings character by character, form bodies with URL decoding. This works for the current use cases but has hard limits. A multipart form upload would require substantial additional parsing. The constraint (no external gems for web serving) is worth the tradeoff, but the tradeoff is real.

## Limits

**No historical evaluation tracking.** The evaluation harness prints results to stdout and exits. There is no persistence — no way to compare today's retrieval F1 against last week's. Regression detection requires the operator to remember previous scores. *Update: a `history.jsonl` file now persists every evaluation run (timestamp, git SHA, model, per-suite F1). A regression detector compares the current run against previous results and fails if F1 drops by more than 0.1. This gap is closed.*

**No coverage measurement.** The test suite validates behavior end-to-end but does not measure code coverage. There is no floor — no way to detect that a new module was added without corresponding tests. Ruby's stdlib `Coverage` module could provide this without adding a dependency, but it has not been integrated. *Update: `PROPHET_COVERAGE=1` enables Ruby's stdlib `Coverage` module during smoke tests. A 50% floor rejects runs that drop below it. Results persist to `.state/coverage/report.json`. This gap is closed.*

Both gaps identified above — historical tracking and coverage measurement — have been addressed. Per-channel isolation was addressed by [separate fixture suites per retrieval channel](/posts/three-stolen-ideas) and a [dispositional injection suite](/posts/testing-always-on) that tests retrieval with all channels active. The remaining open item from this post is interface contracts: diagnostic subcommands still check liveness only, not output shape.