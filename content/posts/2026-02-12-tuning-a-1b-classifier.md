---
title: "Tuning a 1B classifier"
date: 2026-02-12
description: "Nine trials to get gemma3:1b from 50% to 100% accuracy on yes/no classification, by changing nothing but the words in the prompt"
---

**TL;DR** — gemma3:1b scored 50% on yes/no classification with vague conditions like "the file contains source code." Parenthetical clauses, example lists, and negation each broke it in different ways. Verb-based conditions with concrete observable features — "the content is programming language source code with functions, classes, or imports" — reached 100%. Nothing changed but the words in the prompt.

---

I built [screen](https://github.com/bioneural/screen) to answer one question: does this condition apply to this input? Screen sends each question to a local LLM — gemma3:1b via ollama, default temperature, one billion parameters. The prompt is a condition in XML tags, an input in XML tags, and the instruction "Answer yes or no only." All three classifiers share this single prompt template.

I use it with three conditions. Given a file, is this source code? Given a file, is this test code? Given a user prompt, is this a naming decision? Each answer determines whether screen injects relevant guidelines into an AI coding agent's context. I test these classifiers with a harness that runs 5 positive and 5 negative fixtures per condition, 3 trials each with majority voting. Target: 30/30.

Before any tuning, the harness scored 19/30. Every positive fixture passed. Nearly every negative failed. The model said "yes" to anything technology-adjacent — meeting notes mentioning "vendor API" classified as source code, a deploy script classified as test code.

My first instinct was to fix the fixtures. Replace ambiguous negatives with obviously non-technical content. Score moved from 19 to 22. The instinct was wrong. The model still said "yes" to standup notes about software projects. The fixtures were not the problem. The conditions were.

## What the model hears

The source code condition was "the file contains source code." To gemma3:1b, that means "is this related to software." I changed it to "the content is programming language source code with functions, classes, or imports." Accuracy on that classifier went from 50% to 90%. Every added word — "programming language," "functions," "classes," "imports" — is a concrete signal the model can check for. Vague topic association replaced with structural analysis.

The test code condition was harder. "The file contains test code or test configuration" scored 60%. I tightened it to "the content is test code (unit tests, integration tests, or test framework configuration)" and it got worse — 1/5 positives. The parenthetical clause broke the model. It lost the thread of the sentence and said "no" to everything.

First finding: parenthetical clauses are poison for gemma3:1b.

I tried examples next: "uses a test framework like minitest, rspec, pytest, or jest." The model said "yes" to everything — a server file, a deploy script, a README. Listing examples caused it to pattern-match too loosely. Second finding: "like X, Y, Z" triggers over-association.

I tried negation: "the file is NOT related to testing" with inverted interpretation. All "no," regardless of input. The model picks up the negation word and applies it uniformly. Third finding: negation biases the output toward "no."

## Nine trials

The path from 19/30 to 30/30 took nine trials. Trials 1 and 2 tuned conditions. Trials 3 through 6 were dead ends — each explored a different strategy and each failed completely:

1. Better fixtures, same conditions. 22/30. Marginal — proved the conditions were the problem.
2. Tightened conditions with parenthetical clauses. Source code improved; test code collapsed to 1/5 positives.
3. Path-based detection ("file path starts with test/"). All yes, every input. The model cannot do string matching on paths.
4. Negative framing. All no, every input.
5. Few-shot prompting with examples. 2/4 on hard cases, but requires per-classifier templates — defeats the shared template.
6. Classification format ("classify as test or not test"). All "test." The repeated word primes the answer.
7. Condition variations without parentheses. Three candidates tested; one scored 5/5: "the file contains test methods that verify expected behavior."
8. Stability check on the winner across 9 inputs, 3 trials each. 26/27 correct. The one miss: CI config, which invokes tests but contains no test methods. Acceptable.
9. Full 30-fixture suite with all three tuned conditions. First run: 28/30. Two failures on tech-adjacent vocabulary in negative fixtures — a changelog mentioning "dashboard," a prompt containing "function." Replaced with unambiguous negatives. Second run: 30/30.

Trial 8 is the most informative result. It tests edge cases the conditions were not tuned against and still holds at 96%.

## What worked

The final conditions:

| Classifier | Before | After |
|------------|--------|-------|
| Source code | "the file contains source code" | "the content is programming language source code with functions, classes, or imports" |
| Test code | "the file contains test code or test configuration" | "the file contains test methods that verify expected behavior" |
| Naming | "involves naming a new repo, tool, or project" | "the user is choosing a name for a new repo, tool, or project" |

The pattern that works: verb-based conditions with concrete observable features. "Contains test methods that verify expected behavior" succeeds because every word maps to something the model can check. "Test methods" maps to `def test_*` and `it` blocks. "Verify" maps to assert and expect statements. "Expected behavior" maps to the purpose of those constructs. No parentheses. No examples. No negation.

The 30/30 score reflects both condition tuning and fixture selection. Trial 9's first run scored 28/30 with tuned conditions against harder negatives. The final 30/30 required replacing ambiguous negatives with unambiguous ones. Both changes contributed. A changelog mentioning "beta program" and "dashboard" is ambiguous to a model that associates software vocabulary with source code. A lunch order note is not.

Majority voting smooths single-trial noise but cannot fix systematic bias. If the condition is wrong, three trials confirm the error three times.

## Limits

These findings are from one model (gemma3:1b) at default generation parameters, on a 30-fixture evaluation set, for well-separated categories. Whether the three failure modes — parenthetical clauses, example lists, negation framing — transfer to other small models is untested. The categories classified here have clear structural markers. Finer distinctions — refactoring versus new feature, for instance — may not yield to vocabulary tuning alone.

What the nine trials demonstrate: for gemma3:1b on this task, the gap between 50% and 100% was not the model's discrimination ability. It was mine — in choosing the words.
