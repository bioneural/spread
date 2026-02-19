# Cross-Encoder Reranking — Experiment Results

Date: 2026-02-19T06:18:56Z
Embedding model: nomic-embed-text
Distance threshold: 0.5
RRF k: 60
Rerank model: gemma3:1b
RRF candidates for reranking: 20 → top 10
Corpus: 120 entries

## Direct-vocabulary queries (Q01-Q10)

| Query | RRF P@10 | Reranked P@10 | Delta |
|-------|----------|---------------|-------|
| Q01 | 1/10 | 1/10 | 0 |
| Q02 | 6/10 | 7/10 | +1 |
| Q03 | 8/10 | 8/10 | 0 |
| Q04 | 4/10 | 4/10 | 0 |
| Q05 | 2/10 | 3/10 | +1 |
| Q06 | 3/10 | 4/10 | +1 |
| Q07 | 5/10 | 6/10 | +1 |
| Q08 | 6/10 | 6/10 | 0 |
| Q09 | 7/10 | 7/10 | 0 |
| Q10 | 6/10 | 6/10 | 0 |

## Paraphrase queries (Q11-Q15)

| Query | RRF P@10 | Reranked P@10 | Delta |
|-------|----------|---------------|-------|
| Q11 | 2/10 | 2/10 | 0 |
| Q12 | 4/10 | 5/10 | +1 |
| Q13 | 2/10 | 2/10 | 0 |
| Q14 | 4/10 | 4/10 | 0 |
| Q15 | 1/10 | 2/10 | +1 |

## Negative queries (Q16-Q20): rerank score distribution

| Query | Candidates | Mean Score | Max Score | Scores > 0.5 |
|-------|------------|------------|-----------|-------------|
| Q16 | 8 | 0.000 | 0.000 | 0 |
| Q17 | 4 | 0.000 | 0.000 | 0 |
| Q18 | 3 | 0.000 | 0.000 | 0 |
| Q19 | 1 | 0.000 | 0.000 | 0 |
| Q20 | 18 | 0.000 | 0.000 | 0 |

## Aggregate

| Query type | N | Mean RRF P@10 | Mean Reranked P@10 | Mean Delta |
|------------|---|---------------|--------------------|-----------|
| Direct (Q01-Q10) | 10 | 4.80/10 | 5.20/10 | +0.40 |
| Paraphrase (Q11-Q15) | 5 | 2.60/10 | 3.00/10 | +0.40 |

## Hero example: Q02

Largest precision improvement: +1 entries

### RRF ranking (top 10)

~~~
rank	entry_id	cluster	rrf_score	channels	content
1	13	2	0.030018	fts+vec	Chose nomic-embed-text over mxbai-embed-large because it runs under 100ms per em 
2	11	2	0.029907	fts+vec	nomic-embed-text produces 768-dimensional float vectors. At default ollama setti 
3	17	2	0.029877	fts+vec	The embedding for a 200-word paragraph and the embedding for a 5-word query live 
4	14	2	0.02971	fts+vec	The embedding API returns a JSON response with an embeddings key containing an a 
5	18	2	0.029412	fts+vec	Store embeddings as float[768] in sqlite-vec vec0 virtual table. The vec0 format 
6	75	8	0.029387	fts+vec	End-to-end tests are slow because they call ollama for every embedding and extra 
7	12	2	0.02885	fts+vec	Batch embedding via the ollama /api/embed endpoint accepts an array of inputs an 
8	38	4	0.028309	fts+vec	Entries table uses AUTOINCREMENT for the primary key despite the performance cos 
9	37	4	0.027912	fts+vec	sqlite-vec vec0 virtual table does not support UPDATE. To change an embedding, y 
10	93	10	0.016393	fts	Log entries include the tool name as a structured field, not embedded in the mes 
~~~

### Reranked (top 10)

~~~
rank	entry_id	cluster	rerank_score	rrf_score	channels	content
1	11	2	0.991747	0.029907	fts+vec	nomic-embed-text produces 768-dimensional float vectors. At default ollama setti 
2	13	2	0.609866	0.030018	fts+vec	Chose nomic-embed-text over mxbai-embed-large because it runs under 100ms per em 
3	17	2	0.015370	0.029877	fts+vec	The embedding for a 200-word paragraph and the embedding for a 5-word query live 
4	19	2	0.000077	0.014925	vec	Cosine similarity and L2 distance produce different orderings for the same query 
5	14	2	0.000015	0.02971	fts+vec	The embedding API returns a JSON response with an embeddings key containing an a 
6	18	2	0.000000	0.029412	fts+vec	Store embeddings as float[768] in sqlite-vec vec0 virtual table. The vec0 format 
7	75	8	0.000000	0.029387	fts+vec	End-to-end tests are slow because they call ollama for every embedding and extra 
8	12	2	0.000000	0.02885	fts+vec	Batch embedding via the ollama /api/embed endpoint accepts an array of inputs an 
9	38	4	0.000000	0.028309	fts+vec	Entries table uses AUTOINCREMENT for the primary key despite the performance cos 
10	37	4	0.000000	0.027912	fts+vec	sqlite-vec vec0 virtual table does not support UPDATE. To change an embedding, y 
~~~
