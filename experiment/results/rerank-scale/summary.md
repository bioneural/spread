# Cross-Encoder Reranking — Scale Experiment Results

Date: 2026-02-19T19:28:57Z

Scales tested: 1 5

## Scale 1 (120 entries)

| Query | Type | RRF P@10 | Reranked P@10 | Delta |
|-------|------|----------|---------------|-------|
| Q01 | single | 1/10 | 1/10 | 0 |
| Q02 | single | 6/10 | 7/10 | +1 |
| Q03 | single | 8/10 | 8/10 | 0 |
| Q04 | single | 4/10 | 4/10 | 0 |
| Q05 | single | 2/10 | 3/10 | +1 |
| Q06 | single | 3/10 | 4/10 | +1 |
| Q07 | single | 5/10 | 6/10 | +1 |
| Q08 | single | 6/10 | 6/10 | 0 |
| Q09 | single | 7/10 | 7/10 | 0 |
| Q10 | single | 6/10 | 6/10 | 0 |
| Q11 | paraphrase | 2/10 | 2/10 | 0 |
| Q12 | paraphrase | 4/10 | 5/10 | +1 |
| Q13 | paraphrase | 2/10 | 2/10 | 0 |
| Q14 | paraphrase | 4/10 | 4/10 | 0 |
| Q15 | paraphrase | 1/10 | 2/10 | +1 |

## Scale 5 (480 entries)

| Query | Type | RRF P@10 | Reranked P@10 | Delta |
|-------|------|----------|---------------|-------|
| Q01 | single | 1/10 | 1/10 | 0 |
| Q02 | single | 5/10 | 6/10 | +1 |
| Q03 | single | 7/10 | 7/10 | 0 |
| Q04 | single | 5/10 | 5/10 | 0 |
| Q05 | single | 2/10 | 2/10 | 0 |
| Q06 | single | 1/10 | 1/10 | 0 |
| Q07 | single | 7/10 | 5/10 | -2 |
| Q08 | single | 7/10 | 8/10 | +1 |
| Q09 | single | 10/10 | 6/10 | -4 |
| Q10 | single | 5/10 | 8/10 | +3 |
| Q11 | paraphrase | 2/10 | 3/10 | +1 |
| Q12 | paraphrase | 0/10 | 1/10 | +1 |
| Q13 | paraphrase | 0/10 | 0/10 | 0 |
| Q14 | paraphrase | 3/10 | 3/10 | 0 |
| Q15 | paraphrase | 3/10 | 4/10 | +1 |

## Aggregate: Cross-Scale Comparison

| Scale | Entries | Query Type | N | Mean RRF P@10 | Mean Reranked P@10 | Mean Delta |
|-------|---------|------------|---|---------------|--------------------|-----------|
| 1 | 120 | Direct | 10 | 4.80/10 | 5.20/10 | +0.40 |
| 1 | 120 | Paraphrase | 5 | 2.60/10 | 3.00/10 | +0.40 |
| **1** | **120** | **All** | **15** | **4.07/10** | **4.47/10** | **+0.40** |
| 5 | 480 | Direct | 10 | 5.00/10 | 4.90/10 | -0.10 |
| 5 | 480 | Paraphrase | 5 | 1.60/10 | 2.20/10 | +0.60 |
| **5** | **480** | **All** | **15** | **3.87/10** | **4.00/10** | **+0.13** |

## Negative Queries: Rerank Score Distribution by Scale

| Scale | Entries | Query | Candidates | Mean Score | Max Score | Scores > 0.5 |
|-------|---------|-------|------------|------------|-----------|-------------|
| 1 | 120 | Q16 | 8 | 0.000 | 0.000 | 0 |
| 1 | 120 | Q17 | 4 | 0.000 | 0.000 | 0 |
| 1 | 120 | Q18 | 3 | 0.000 | 0.000 | 0 |
| 1 | 120 | Q19 | 1 | 0.000 | 0.000 | 0 |
| 1 | 120 | Q20 | 18 | 0.000 | 0.000 | 0 |
| 5 | 480 | Q16 | 20 | 0.000 | 0.000 | 0 |
| 5 | 480 | Q17 | 20 | 0.000 | 0.000 | 0 |
| 5 | 480 | Q18 | 20 | 0.000 | 0.000 | 0 |
| 5 | 480 | Q19 | 1 | 0.000 | 0.000 | 0 |
| 5 | 480 | Q20 | 20 | 0.000 | 0.000 | 0 |

## Hypothesis: Does reranking help more at larger corpus sizes?

The hypothesis is that RRF degrades at scale (dual-channel overlap drops to zero)
while cross-encoder reranking evaluates content directly and is unaffected by
channel agreement. If true, the reranking delta should increase at larger scales.

| Scale | Mean RRF P@10 (all) | Mean Reranked P@10 (all) | Delta |
|-------|---------------------|--------------------------|-------|
| 1 (120 entries) | 4.07/10 | 4.47/10 | +0.40 |
| 5 (480 entries) | 3.87/10 | 4.00/10 | +0.13 |
