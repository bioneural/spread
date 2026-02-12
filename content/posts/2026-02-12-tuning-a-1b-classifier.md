---
title: "Tuning a 1B classifier"
date: 2026-02-12
description: "Nine trials to get gemma3:1b from 50% to 100% accuracy on yes/no classification, by changing nothing but the words in the prompt"
---

Screen is a classifier engine. It asks a local LLM one question — does this condition apply to this input? — and expects "yes" or "no." The model is gemma3:1b, running locally via ollama. One billion parameters. The entire prompt is a condition wrapped in XML tags, an input wrapped in XML tags, and the instruction "Answer yes or no only."

Three conditions gate context injection in production: one detects source code, one detects test code, one detects naming decisions. The test harness runs 5 positive and 5 negative fixtures per condition, 3 trials each with majority voting. Target: 30/30.

The baseline scored 19/30. Every positive fixture passed. Nearly every negative failed. The model said "yes" to anything technology-adjacent — meeting notes mentioning "vendor API" were classified as source code. A deploy script was classified as test code.

The first instinct was to fix the fixtures. Replace ambiguous negatives with obviously non-technical content. This improved the score from 19 to 22 and proved the instinct wrong. The model still said "yes" to standup notes about software projects. The fixtures were not the problem. The conditions were.

## What the model hears

The source code condition was "the file contains source code." That phrase, to a 1B model, means "is this related to software." Changing it to "the content is programming language source code with functions, classes, or imports" improved accuracy from 50% to 90% on that classifier alone. Every added word — "programming language," "functions," "classes," "imports" — is a concrete signal the model can check for, replacing a vague topic association with structural analysis.

The test code condition was harder. "The file contains test code or test configuration" scored 60%. Tightening it to "the content is test code (unit tests, integration tests, or test framework configuration)" made it worse — 1/5 positives. The parenthetical clause broke the model. It lost the thread of the sentence and said "no" to everything.

This was the first useful finding: parenthetical clauses are poison for 1B models.

The second attempt used examples: "uses a test framework like minitest, rspec, pytest, or jest." The model said "yes" to everything — a server file, a deploy script, a README. Listing examples caused it to pattern-match too loosely. Second finding: "like X, Y, Z" triggers over-association.

A negative framing — "the file is NOT related to testing" with inverted interpretation — produced all "no" regardless of input. The model picks up the negation word and applies it uniformly. Third finding: negation biases the output toward "no."

## Nine trials

The path from 19/30 to 30/30 took nine trials:

1. Better fixtures, same conditions. 22/30. Marginal.
2. Tightened conditions with parenthetical clauses. Source code improved; test code collapsed.
3. Path-based detection ("file path starts with test/"). All yes, every input. The 1B model cannot do string matching.
4. Negative framing. All no, every input.
5. Few-shot prompting with examples. 2/4 on hard cases. Better, but requires per-classifier templates, which defeats the shared-template architecture.
6. Classification format ("classify as test or not test"). All "test." The repeated word in the definition primes the answer.
7. Condition variations without parentheses. One of three candidates scored 5/5: "the file contains test methods that verify expected behavior."
8. Stability check on the winner across 9 inputs, 3 trials each. 26/27 correct, one acceptable miss (CI config — it invokes tests but contains no test methods).
9. Full 30-fixture suite with all three tuned conditions. First run: 28/30. Two failures traced to tech-adjacent vocabulary in negative fixtures. Replaced a changelog mentioning "dashboard" with a lunch order note. Second run: 30/30.

## What worked

The final conditions:

| Classifier | Before | After |
|------------|--------|-------|
| Source code | "the file contains source code" | "the content is programming language source code with functions, classes, or imports" |
| Test code | "the file contains test code or test configuration" | "the file contains test methods that verify expected behavior" |
| Naming | "involves naming a new repo, tool, or project" | "the user is choosing a name for a new repo, tool, or project" |

The winning pattern is verb-based conditions with concrete observable features. "Contains test methods that verify expected behavior" works because every word maps to something the model can check: "test methods" maps to `def test_*` and `it` blocks, "verify" maps to assert and expect statements, "expected behavior" maps to the purpose of those constructs. No parentheses. No examples. No negation.

The model can distinguish between semantic categories — code versus prose, test code versus application code, naming versus operating — but only when the condition uses vocabulary that activates the right internal features. The same underlying capability exists at 1B parameters. The unlock is phrasing.

Fixture quality matters equally. A changelog mentioning "beta program" and "dashboard" is ambiguous to a model that associates software vocabulary with source code. A lunch order note is not. Test negatives should use vocabulary with zero overlap with the condition's domain. Majority voting smooths single-trial noise but cannot fix systematic bias — if the condition is wrong, three trials confirm the error three times.

The gap between 50% and 100% was not capability. It was vocabulary.
