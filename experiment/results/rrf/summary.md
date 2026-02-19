# RRF vs Union — Experiment Results

Date: 2026-02-19T01:02:52Z
Embedding model: nomic-embed-text
Distance threshold: 0.5
RRF k: 60
Corpus: 120 entries

## Per-query results (Q01-Q10: direct vocabulary)

| Query | FTS | Vec | Both | Union P@10 | RRF P@10 | Delta |
|-------|-----|-----|------|------------|----------|-------|
| Q01 | 20 | 20 | 9 | 0/10 | 1/10 | +1 |
| Q02 | 14 | 19 | 9 | 0/10 | 6/10 | +6 |
| Q03 | 11 | 20 | 9 | 1/10 | 8/10 | +7 |
| Q04 | 5 | 20 | 2 | 0/10 | 4/10 | +4 |
| Q05 | 20 | 20 | 9 | 0/10 | 2/10 | +2 |
| Q06 | 12 | 20 | 6 | 0/10 | 3/10 | +3 |
| Q07 | 12 | 20 | 9 | 3/10 | 5/10 | +2 |
| Q08 | 14 | 6 | 6 | 7/10 | 6/10 | -1 |
| Q09 | 6 | 10 | 4 | 7/10 | 7/10 | 0 |
| Q10 | 20 | 20 | 9 | 9/10 | 6/10 | -3 |

## Paraphrase queries (Q11-Q15: vector-only)

| Query | FTS | Vec | Union P@10 | RRF P@10 | Notes |
|-------|-----|-----|------------|----------|-------|
| Q11 | 3 | 9 | 1/10 | 2/10 | unexpected FTS hits |
| Q12 | 20 | 18 | 0/10 | 4/10 | unexpected FTS hits |
| Q13 | 20 | 20 | 0/10 | 2/10 | unexpected FTS hits |
| Q14 | 20 | 20 | 0/10 | 4/10 | unexpected FTS hits |
| Q15 | 20 | 11 | 0/10 | 1/10 | unexpected FTS hits |

## Negative queries (Q16-Q20: nothing relevant)

| Query | FTS | Vec | Notes |
|-------|-----|-----|-------|
| Q16 | 5 | 4 | unexpected FTS hits; vector returned results (below threshold?) |
| Q17 | 4 | 0 | unexpected FTS hits |
| Q18 | 2 | 1 | unexpected FTS hits; vector returned results (below threshold?) |
| Q19 | 1 | 0 | unexpected FTS hits |
| Q20 | 1 | 18 | unexpected FTS hits; vector returned results (below threshold?) |

## Aggregate

| Query type | N | Mean Union P@10 | Mean RRF P@10 | Mean Delta |
|------------|---|-----------------|---------------|------------|
| Direct (Q01-Q10) | 10 | 2.70/10 | 4.80/10 | +2.10 |
| Paraphrase (Q11-Q15) | 5 | 0.20/10 | 2.60/10 | +2.40 |

## Hero example: Q03

Largest precision improvement: +7 entries

### FTS ranking

```
rank	entry_id	cluster	content
1	89	9	Writing should prefer active voice and concrete nouns. The model classified the  
2	73	8	Testing classifier accuracy requires a labeled dataset. The gemma3 1b tuning exp 
3	30	3	Classifier prompts include a machine-readable output format: respond with exactl 
4	29	3	System prompts are less effective than user prompts for gemma3 1b. Moving instru 
5	28	3	Set all classifier prompts to temperature 0.0 despite non-determinism. Higher te 
6	26	3	The extraction prompt for trick originally said extract all important informatio 
7	25	3	Prompt templates should avoid negation. Do not classify X as Y is less reliable  
8	24	3	A classifier prompt that worked for Python code detection returned false negativ 
9	22	3	Tuned the screen classifier prompt from a binary yes/no format to a structured c 
10	21	3	The gemma3 1b model says yes to anything technology-adjacent when given vague co 
11	4	1	screen runs as a standalone classifier behind a Unix pipe interface. Input on st 
```

### Vector ranking

```
rank	entry_id	cluster	distance	content
1	73	8	0.2129145860671997071	Testing classifier accuracy requires a labeled dataset. The gemma3 1b tuning exp 
2	28	3	0.2978901863098144532	Set all classifier prompts to temperature 0.0 despite non-determinism. Higher te 
3	24	3	0.3109138011932373046	A classifier prompt that worked for Python code detection returned false negativ 
4	22	3	0.322750091552734375	Tuned the screen classifier prompt from a binary yes/no format to a structured c 
5	27	3	0.3933192789554595947	Temperature 0.0 does not guarantee deterministic output from gemma3 1b. Across 1 
6	29	3	0.4004028141498565673	System prompts are less effective than user prompts for gemma3 1b. Moving instru 
7	89	9	0.4043624103069305419	Writing should prefer active voice and concrete nouns. The model classified the  
8	78	8	0.4169329404830932617	Test queries are written to cover four categories: high-confidence matches, mixe 
9	23	3	0.4237909018993377686	Zero-shot classification with gemma3 1b fails on edge cases. The model needs at  
10	19	2	0.4401758611202239991	Cosine similarity and L2 distance produce different orderings for the same query 
11	90	9	0.4465874433517456054	Posts follow a consistent structure: TL;DR, setup, experiment, results, dead end 
12	26	3	0.4479346871376037597	The extraction prompt for trick originally said extract all important informatio 
13	25	3	0.4550756514072418213	Prompt templates should avoid negation. Do not classify X as Y is less reliable  
14	30	3	0.4610523581504821777	Classifier prompts include a machine-readable output format: respond with exactl 
15	32	4	0.4620243012905120849	book dispatcher crashed when a task payload contained a single quote. The SQL in 
16	35	4	0.4625155925750732422	The FTS5 tokenizer configuration porter unicode61 handles English morphological  
17	16	2	0.4626924693584442139	nomic-embed-text is trained for search rather than classification. Its vectors c 
18	77	8	0.4646486341953277588	The three-channels experiment tests retrieval quality, not performance. Timing d 
19	45	5	0.4655066430568695068	trick silently dropped memories when the extraction model returned malformed JSO 
20	54	6	0.4660722613334655762	Ruby frozen_string_literal pragma prevents accidental string mutation. All tool  
```

### RRF ranking

```
rank	entry_id	cluster	score	channels	content
1	73	8	0.032522	fts+vec	Testing classifier accuracy requires a labeled dataset. The gemma3 1b tuning exp 
2	28	3	0.031514	fts+vec	Set all classifier prompts to temperature 0.0 despite non-determinism. Higher te 
3	89	9	0.031319	fts+vec	Writing should prefer active voice and concrete nouns. The model classified the  
4	29	3	0.030777	fts+vec	System prompts are less effective than user prompts for gemma3 1b. Moving instru 
5	24	3	0.030579	fts+vec	A classifier prompt that worked for Python code detection returned false negativ 
6	22	3	0.030118	fts+vec	Tuned the screen classifier prompt from a binary yes/no format to a structured c 
7	30	3	0.029387	fts+vec	Classifier prompts include a machine-readable output format: respond with exactl 
8	26	3	0.02904	fts+vec	The extraction prompt for trick originally said extract all important informatio 
9	25	3	0.028624	fts+vec	Prompt templates should avoid negation. Do not classify X as Y is less reliable  
10	27	3	0.015385	vec	Temperature 0.0 does not guarantee deterministic output from gemma3 1b. Across 1 
```

### Union ranking

```
rank	entry_id	cluster	content
1	90	9	Posts follow a consistent structure: TL;DR, setup, experiment, results, dead end 
2	89	9	Writing should prefer active voice and concrete nouns. The model classified the  
3	78	8	Test queries are written to cover four categories: high-confidence matches, mixe 
4	77	8	The three-channels experiment tests retrieval quality, not performance. Timing d 
5	73	8	Testing classifier accuracy requires a labeled dataset. The gemma3 1b tuning exp 
6	54	6	Ruby frozen_string_literal pragma prevents accidental string mutation. All tool  
7	45	5	trick silently dropped memories when the extraction model returned malformed JSO 
8	35	4	The FTS5 tokenizer configuration porter unicode61 handles English morphological  
9	32	4	book dispatcher crashed when a task payload contained a single quote. The SQL in 
10	30	3	Classifier prompts include a machine-readable output format: respond with exactl 
```
