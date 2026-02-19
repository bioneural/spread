# Cross-Encoder Reranking — Experiment Results (Scale 5)

Date: 2026-02-19T19:28:56Z
Embedding model: nomic-embed-text
Distance threshold: 0.5
RRF k: 60
Rerank model: gemma3:1b
RRF candidates for reranking: 20 → top 10
Scale: 5
Corpus: 480 entries

## Direct-vocabulary queries (Q01-Q10)

| Query | RRF P@10 | Reranked P@10 | Delta |
|-------|----------|---------------|-------|
| Q01 | 1/10 | 1/10 | 0 |
| Q02 | 5/10 | 6/10 | +1 |
| Q03 | 7/10 | 7/10 | 0 |
| Q04 | 5/10 | 5/10 | 0 |
| Q05 | 2/10 | 2/10 | 0 |
| Q06 | 1/10 | 1/10 | 0 |
| Q07 | 7/10 | 5/10 | -2 |
| Q08 | 7/10 | 8/10 | +1 |
| Q09 | 10/10 | 6/10 | -4 |
| Q10 | 5/10 | 8/10 | +3 |

## Paraphrase queries (Q11-Q15)

| Query | RRF P@10 | Reranked P@10 | Delta |
|-------|----------|---------------|-------|
| Q11 | 2/10 | 3/10 | +1 |
| Q12 | 0/10 | 1/10 | +1 |
| Q13 | 0/10 | 0/10 | 0 |
| Q14 | 3/10 | 3/10 | 0 |
| Q15 | 3/10 | 4/10 | +1 |

## Negative queries (Q16-Q20): rerank score distribution

| Query | Candidates | Mean Score | Max Score | Scores > 0.5 |
|-------|------------|------------|-----------|-------------|
| Q16 | 20 | 0.000 | 0.000 | 0 |
| Q17 | 20 | 0.000 | 0.000 | 0 |
| Q18 | 20 | 0.000 | 0.000 | 0 |
| Q19 | 1 | 0.000 | 0.000 | 0 |
| Q20 | 20 | 0.000 | 0.000 | 0 |

## Aggregate

| Query type | N | Mean RRF P@10 | Mean Reranked P@10 | Mean Delta |
|------------|---|---------------|--------------------|-----------|
| Direct (Q01-Q10) | 10 | 5.00/10 | 4.90/10 | -0.10 |
| Paraphrase (Q11-Q15) | 5 | 1.60/10 | 2.20/10 | +0.60 |

## Hero example: Q10

Largest precision improvement: +3 entries

### RRF ranking (top 10)

~~~
rank	entry_id	cluster	rrf_score	channels	content
1	420	10	0.028039	fts+vec	The initial process of recording every detail of each content item was extensive 
2	418	10	0.027273	fts+vec	The initial method of recording every detail of a retrieval was implemented by l 
3	414	10	0.026172	fts+vec	The logging system employs text-based messages, rather than numerical codes. Spe 
4	91	10	0.016393	vec	spill logs to a single SQLite database shared across all tools. Each log entry r 
5	463	0	0.016393	fts	The Atacama Desert, located in Chile, stands as the most arid region on the plan 
6	462	0	0.016129	fts	The atmospheric pressure is fluctuating significantly, exceeding 24 millibars, o 
7	393	10	0.016129	vec	To consolidate all log data into a single SQLite database, which is accessible b 
8	460	0	0.015873	fts	The atmospheric pressure levels will decrease by more than 24 millibars over a p 
9	1	1	0.015873	vec	Switched spill from per-tool log files to a single SQLite database. Centralized  
10	458	0	0.015625	fts	In the year 2023, the Rugby World Cup held in France experienced unprecedented v 
~~~

### Reranked (top 10)

~~~
rank	entry_id	cluster	rerank_score	rrf_score	channels	content
1	392	10	0.999773	0.015385	vec	To consolidate all logging data, it’s proposed to store these records within a s 
2	91	10	0.999388	0.016393	vec	spill logs to a single SQLite database shared across all tools. Each log entry r 
3	1	1	0.994890	0.015873	vec	Switched spill from per-tool log files to a single SQLite database. Centralized  
4	396	10	0.656518	0.015625	vec	The system utilizes three distinct severity classifications: detail, alert, and  
5	391	10	0.012597	0.015152	vec	The collection of log data should be consolidated into a single SQLite database, 
6	393	10	0.000002	0.016129	vec	To consolidate all log data into a single SQLite database, which is accessible b 
7	420	10	0.000000	0.028039	fts+vec	The initial process of recording every detail of each content item was extensive 
8	418	10	0.000000	0.027273	fts+vec	The initial method of recording every detail of a retrieval was implemented by l 
9	414	10	0.000000	0.026172	fts+vec	The logging system employs text-based messages, rather than numerical codes. Spe 
10	463	0	0.000000	0.016393	fts	The Atacama Desert, located in Chile, stands as the most arid region on the plan 
~~~

## Regression: Q09

Largest precision regression: -4 entries

### RRF ranking (top 10)

~~~
rank	entry_id	cluster	rrf_score	channels	content
1	365	9	0.029387	fts+vec	The voice is constructed through artificial intelligence, exhibiting a deliberat 
2	366	9	0.029324	fts+vec	The voice is presented as a synthetic intelligence, characterized by its precise 
3	386	9	0.029211	fts+vec	The composition should predominantly employ active voice and identifiable nouns. 
4	387	9	0.029199	fts+vec	The practice of writing should predominantly employ active voice and specific no 
5	385	9	0.02837	fts+vec	Here’s a rewritten version, maintaining the exact meaning:  To produce more effective communication, it is imperative to utilize active voic 
6	364	9	0.027418	fts+vec	The voice represents a synthetic form of intelligence, characterized by its deli 
7	363	9	0.026671	fts+vec	The core document, designated ‘IDENTITY.md’, serves as the definitive reference  
8	361	9	0.026519	fts+vec	The core document, designated as core/IDENTITY.md, serves as the definitive sour 
9	362	9	0.026145	fts+vec	The core document, designated ‘core/IDENTITY.md’, serves as the definitive repos 
10	82	9	0.016393	vec	The voice is first-person synthetic intelligence: precise, measured, authority t 
~~~

### Reranked (top 10)

~~~
rank	entry_id	cluster	rerank_score	rrf_score	channels	content
1	401	10	0.999999	0.015152	fts	When the SPILL feature is disabled, the output streams back to the standard erro 
2	455	0	0.999997	0.016393	fts	Wheat flour exhibits a greater concentration of protein compared to standard all 
3	366	9	0.999982	0.029324	fts+vec	The voice is presented as a synthetic intelligence, characterized by its precise 
4	392	10	0.999848	0.014925	fts	To consolidate all logging data, it’s proposed to store these records within a s 
5	82	9	0.999168	0.016393	vec	The voice is first-person synthetic intelligence: precise, measured, authority t 
6	385	9	0.999017	0.02837	fts+vec	Here’s a rewritten version, maintaining the exact meaning:  To produce more effective communication, it is imperative to utilize active voic 
7	365	9	0.958334	0.029387	fts+vec	The voice is constructed through artificial intelligence, exhibiting a deliberat 
8	369	9	0.950840	0.015385	vec	The principles of epistemology emphasize the crucial distinction between a reaso 
9	364	9	0.508586	0.027418	fts+vec	The voice represents a synthetic form of intelligence, characterized by its deli 
10	414	10	0.147564	0.015385	fts	The logging system employs text-based messages, rather than numerical codes. Spe 
~~~
