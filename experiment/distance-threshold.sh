#!/usr/bin/env bash

# distance-threshold.sh — measure vector distances across corpus scales
# to determine an optimal distance threshold for crib's vector channel.
#
# Runs at three corpus sizes (~120, ~500, ~1000 entries) to test whether
# the threshold is a property of the embedding model or an artifact of
# corpus density.
#
# For each scale:
#   1. Seeds corpus via corpus.sh --scale N
#   2. Runs 20 test queries (10 single-cluster, 5 paraphrase, 5 negative)
#   3. Computes L2 and cosine distance from each query to ALL entries
#   4. Outputs raw CSV: query_id, entry_id, l2_dist, cosine_dist, relevant
#   5. Prints per-scale and cross-scale summary statistics
#
# Usage:
#   experiment/distance-threshold.sh
#
# Output:
#   results/threshold/distances-scale1.csv
#   results/threshold/distances-scale5.csv
#   results/threshold/distances-scale10.csv
#   results/threshold/analysis.txt
#
# Dependencies: crib, ollama, sqlite3 (with sqlite-vec), jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRIB_DIR="$(cd "$SCRIPT_DIR/../../crib" && pwd)"
CRIB="$CRIB_DIR/bin/crib"

# sqlite3 binary (match crib's detection)
SQLITE3="${CRIB_SQLITE3:-/opt/homebrew/opt/sqlite/bin/sqlite3}"

# sqlite-vec extension
VEC_EXTENSION="${CRIB_VEC_EXTENSION:-$(python3 -c 'import sqlite_vec; print(sqlite_vec.loadable_path())' 2>/dev/null || echo 'vec0')}"

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
EMBEDDING_MODEL="${CRIB_EMBEDDING_MODEL:-nomic-embed-text}"

GROUND_TRUTH="$SCRIPT_DIR/ground-truth.txt"
CORPUS_SCRIPT="$SCRIPT_DIR/corpus.sh"
RESULTS="$SCRIPT_DIR/results/threshold"

if [[ ! -x "$CRIB" ]]; then
  echo "error: crib not found at $CRIB" >&2
  exit 1
fi

if [[ ! -f "$GROUND_TRUTH" ]]; then
  echo "error: ground-truth.txt not found at $GROUND_TRUTH" >&2
  exit 1
fi

if [[ ! -x "$CORPUS_SCRIPT" ]]; then
  echo "error: corpus.sh not found or not executable at $CORPUS_SCRIPT" >&2
  exit 1
fi

mkdir -p "$RESULTS"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sql_vec() {
  local db="$1"
  shift
  "$SQLITE3" -cmd ".load $VEC_EXTENSION" "$db" "$@"
}

sql_vec_json() {
  local db="$1"
  shift
  "$SQLITE3" -json -cmd ".load $VEC_EXTENSION" "$db" "$@"
}

embed_query() {
  local text="$1"
  local response
  response=$(curl -s "$OLLAMA_HOST/api/embed" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$EMBEDDING_MODEL" --arg input "$text" \
      '{model: $model, input: $input}')")
  echo "$response" | jq -c '.embeddings[0]'
}

# Load queries from ground truth
load_queries() {
  grep -v '^#' "$GROUND_TRUTH" | grep -v '^$' | while IFS=$'\t' read -r qid qtype clusters query_text; do
    printf '%s\t%s\t%s\t%s\n' "$qid" "$qtype" "$clusters" "$query_text"
  done
}

# Load cluster map and determine if entry is relevant to a query's clusters
is_relevant() {
  local entry_id="$1"
  local relevant_clusters="$2"
  local cluster_map_file="$3"

  if [[ -z "$relevant_clusters" || "$relevant_clusters" == "none" ]]; then
    echo "0"
    return
  fi

  local entry_cluster
  entry_cluster=$(grep "^${entry_id}	" "$cluster_map_file" | cut -f2)

  if [[ -z "$entry_cluster" ]]; then
    echo "0"
    return
  fi

  # Check if entry's cluster is in the comma-separated relevant list
  IFS=',' read -ra rel_arr <<< "$relevant_clusters"
  for c in "${rel_arr[@]}"; do
    if [[ "$entry_cluster" == "$c" ]]; then
      echo "1"
      return
    fi
  done
  echo "0"
}

# ---------------------------------------------------------------------------
# Run one scale
# ---------------------------------------------------------------------------

run_scale() {
  local scale="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  local db="$tmpdir/experiment.db"
  local cluster_map="$tmpdir/cluster-map.txt"
  local csv="$RESULTS/distances-scale${scale}.csv"

  printf "\n\033[1m========================================\033[0m\n"
  printf "\033[1m  Scale %s — seeding corpus\033[0m\n" "$scale"
  printf "\033[1m========================================\033[0m\n\n"

  # Seed corpus
  local entry_count
  entry_count=$(CRIB_DB="$db" "$CORPUS_SCRIPT" --scale "$scale")
  printf "\nSeeded %s entries at scale %s\n" "$entry_count" "$scale"

  if [[ ! -f "$cluster_map" ]]; then
    echo "error: cluster-map.txt not generated at $cluster_map" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  # Verify entry count
  local db_count
  db_count=$("$SQLITE3" "$db" "SELECT COUNT(*) FROM entries;")
  printf "Database contains %s entries\n" "$db_count"

  # Write CSV header
  echo "query_id,entry_id,l2_dist,cosine_dist,relevant" > "$csv"

  printf "\n\033[1mRunning queries at scale %s...\033[0m\n" "$scale"

  local query_num=0
  while IFS=$'\t' read -r qid qtype clusters query_text; do
    query_num=$((query_num + 1))
    printf "  [%2d/20] %s: %s\n" "$query_num" "$qid" "$query_text"

    # Embed the query
    local query_vec
    query_vec=$(embed_query "$query_text")
    if [[ -z "$query_vec" || "$query_vec" == "null" ]]; then
      printf "    SKIPPED (embedding failed)\n"
      continue
    fi

    # Escape the vector JSON for SQL (single quotes)
    local escaped_vec
    escaped_vec=$(echo "$query_vec" | sed "s/'/''/g")

    # Query all entries with both L2 and cosine distances
    # Use sqlite-vec scalar functions on the vec0 table
    local distance_results
    distance_results=$(sql_vec_json "$db" "
      SELECT
        e.rowid as entry_id,
        vec_distance_L2(e.embedding, '${escaped_vec}') as l2_dist,
        vec_distance_cosine(e.embedding, '${escaped_vec}') as cosine_dist
      FROM entries_vec e
      ORDER BY l2_dist;
    " 2>/dev/null)

    if [[ -z "$distance_results" || "$distance_results" == "[]" ]]; then
      printf "    WARNING: no distance results returned\n"
      continue
    fi

    # Parse results and write CSV rows
    local row_count=0
    echo "$distance_results" | jq -c '.[]' | while read -r row; do
      local eid l2 cos
      eid=$(echo "$row" | jq -r '.entry_id')
      l2=$(echo "$row" | jq -r '.l2_dist')
      cos=$(echo "$row" | jq -r '.cosine_dist')

      local rel
      rel=$(is_relevant "$eid" "$clusters" "$cluster_map")

      echo "${qid},${eid},${l2},${cos},${rel}" >> "$csv"
      row_count=$((row_count + 1))
    done

    printf "    %s distance pairs recorded\n" "$(echo "$distance_results" | jq 'length')"

  done < <(load_queries)

  # Print per-scale summary using SQLite for analysis
  printf "\n\033[1mScale %s summary:\033[0m\n" "$scale"
  analyze_scale "$csv" "$scale"

  # Cleanup temp database
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

analyze_scale() {
  local csv="$1"
  local scale="$2"

  # Load CSV into a temp SQLite database for analysis
  local analysis_db
  analysis_db=$(mktemp /tmp/analysis-XXXXXX.db)

  "$SQLITE3" "$analysis_db" <<SQL
CREATE TABLE distances (
  query_id TEXT,
  entry_id INTEGER,
  l2_dist REAL,
  cosine_dist REAL,
  relevant INTEGER
);
.mode csv
.import ${csv} distances
DELETE FROM distances WHERE query_id = 'query_id';
SQL

  printf "\n  --- L2 Distance ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT
  CASE WHEN relevant = 1 THEN 'relevant' ELSE 'irrelevant' END as class,
  COUNT(*) as n,
  ROUND(MIN(l2_dist), 4) as min_l2,
  ROUND(AVG(l2_dist), 4) as mean_l2,
  ROUND(MAX(l2_dist), 4) as max_l2
FROM distances
WHERE l2_dist IS NOT NULL
GROUP BY relevant
ORDER BY relevant DESC;
SQL

  printf "\n  --- Cosine Distance ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT
  CASE WHEN relevant = 1 THEN 'relevant' ELSE 'irrelevant' END as class,
  COUNT(*) as n,
  ROUND(MIN(cosine_dist), 4) as min_cos,
  ROUND(AVG(cosine_dist), 4) as mean_cos,
  ROUND(MAX(cosine_dist), 4) as max_cos
FROM distances
WHERE cosine_dist IS NOT NULL
GROUP BY relevant
ORDER BY relevant DESC;
SQL

  # Find separation point: max relevant distance vs min irrelevant distance
  printf "\n  --- Separation ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT
  'L2' as metric,
  ROUND((SELECT MAX(l2_dist) FROM distances WHERE relevant = 1), 4) as max_relevant,
  ROUND((SELECT MIN(l2_dist) FROM distances WHERE relevant = 0 AND l2_dist IS NOT NULL), 4) as min_irrelevant,
  CASE
    WHEN (SELECT MAX(l2_dist) FROM distances WHERE relevant = 1) <
         (SELECT MIN(l2_dist) FROM distances WHERE relevant = 0 AND l2_dist IS NOT NULL)
    THEN 'clean'
    ELSE 'overlap'
  END as separation
UNION ALL
SELECT
  'cosine' as metric,
  ROUND((SELECT MAX(cosine_dist) FROM distances WHERE relevant = 1), 4) as max_relevant,
  ROUND((SELECT MIN(cosine_dist) FROM distances WHERE relevant = 0 AND cosine_dist IS NOT NULL), 4) as min_irrelevant,
  CASE
    WHEN (SELECT MAX(cosine_dist) FROM distances WHERE relevant = 1) <
         (SELECT MIN(cosine_dist) FROM distances WHERE relevant = 0 AND cosine_dist IS NOT NULL)
    THEN 'clean'
    ELSE 'overlap'
  END as separation;
SQL

  # Find candidate thresholds (midpoint of overlap region)
  printf "\n  --- Candidate Thresholds ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT
  'L2' as metric,
  ROUND(
    ((SELECT MAX(l2_dist) FROM distances WHERE relevant = 1) +
     (SELECT MIN(l2_dist) FROM distances WHERE relevant = 0 AND l2_dist IS NOT NULL)) / 2.0
  , 4) as midpoint_threshold
UNION ALL
SELECT
  'cosine' as metric,
  ROUND(
    ((SELECT MAX(cosine_dist) FROM distances WHERE relevant = 1) +
     (SELECT MIN(cosine_dist) FROM distances WHERE relevant = 0 AND cosine_dist IS NOT NULL)) / 2.0
  , 4) as midpoint_threshold;
SQL

  # Per-query type breakdown
  printf "\n  --- By Query Type (cosine) ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT
  CASE
    WHEN query_id IN ('Q01','Q02','Q03','Q04','Q05','Q06','Q07','Q08','Q09','Q10') THEN 'single'
    WHEN query_id IN ('Q11','Q12','Q13','Q14','Q15') THEN 'paraphrase'
    ELSE 'negative'
  END as qtype,
  CASE WHEN relevant = 1 THEN 'relevant' ELSE 'irrelevant' END as class,
  COUNT(*) as n,
  ROUND(AVG(cosine_dist), 4) as mean_cos,
  ROUND(MIN(cosine_dist), 4) as min_cos,
  ROUND(MAX(cosine_dist), 4) as max_cos
FROM distances
WHERE cosine_dist IS NOT NULL
GROUP BY qtype, relevant
ORDER BY qtype, relevant DESC;
SQL

  rm -f "$analysis_db"
}

cross_scale_analysis() {
  printf "\n\033[1m========================================\033[0m\n"
  printf "\033[1m  Cross-Scale Analysis\033[0m\n"
  printf "\033[1m========================================\033[0m\n"

  local analysis_db
  analysis_db=$(mktemp /tmp/cross-analysis-XXXXXX.db)

  "$SQLITE3" "$analysis_db" <<SQL
CREATE TABLE d1 (query_id TEXT, entry_id INTEGER, l2_dist REAL, cosine_dist REAL, relevant INTEGER);
CREATE TABLE d5 (query_id TEXT, entry_id INTEGER, l2_dist REAL, cosine_dist REAL, relevant INTEGER);
CREATE TABLE d10 (query_id TEXT, entry_id INTEGER, l2_dist REAL, cosine_dist REAL, relevant INTEGER);

.mode csv
.import ${RESULTS}/distances-scale1.csv d1
.import ${RESULTS}/distances-scale5.csv d5
.import ${RESULTS}/distances-scale10.csv d10

DELETE FROM d1 WHERE query_id = 'query_id';
DELETE FROM d5 WHERE query_id = 'query_id';
DELETE FROM d10 WHERE query_id = 'query_id';
SQL

  printf "\n  --- Cosine: Mean Distance by Scale and Relevance ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT 'scale1' as scale,
       CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END as class,
       COUNT(*) as n,
       ROUND(AVG(cosine_dist), 4) as mean_cos,
       ROUND(MIN(cosine_dist), 4) as min_cos,
       ROUND(MAX(cosine_dist), 4) as max_cos
FROM d1 WHERE cosine_dist IS NOT NULL GROUP BY relevant
UNION ALL
SELECT 'scale5', CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END,
       COUNT(*), ROUND(AVG(cosine_dist),4), ROUND(MIN(cosine_dist),4), ROUND(MAX(cosine_dist),4)
FROM d5 WHERE cosine_dist IS NOT NULL GROUP BY relevant
UNION ALL
SELECT 'scale10', CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END,
       COUNT(*), ROUND(AVG(cosine_dist),4), ROUND(MIN(cosine_dist),4), ROUND(MAX(cosine_dist),4)
FROM d10 WHERE cosine_dist IS NOT NULL GROUP BY relevant
ORDER BY scale, class DESC;
SQL

  printf "\n  --- L2: Mean Distance by Scale and Relevance ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT 'scale1' as scale,
       CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END as class,
       COUNT(*) as n,
       ROUND(AVG(l2_dist), 4) as mean_l2,
       ROUND(MIN(l2_dist), 4) as min_l2,
       ROUND(MAX(l2_dist), 4) as max_l2
FROM d1 WHERE l2_dist IS NOT NULL GROUP BY relevant
UNION ALL
SELECT 'scale5', CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END,
       COUNT(*), ROUND(AVG(l2_dist),4), ROUND(MIN(l2_dist),4), ROUND(MAX(l2_dist),4)
FROM d5 WHERE l2_dist IS NOT NULL GROUP BY relevant
UNION ALL
SELECT 'scale10', CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END,
       COUNT(*), ROUND(AVG(l2_dist),4), ROUND(MIN(l2_dist),4), ROUND(MAX(l2_dist),4)
FROM d10 WHERE l2_dist IS NOT NULL GROUP BY relevant
ORDER BY scale, class DESC;
SQL

  printf "\n  --- Candidate Thresholds by Scale ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT 'scale1' as scale,
  ROUND(((SELECT MAX(cosine_dist) FROM d1 WHERE relevant=1) +
         (SELECT MIN(cosine_dist) FROM d1 WHERE relevant=0 AND cosine_dist IS NOT NULL))/2.0, 4) as cos_threshold,
  ROUND(((SELECT MAX(l2_dist) FROM d1 WHERE relevant=1) +
         (SELECT MIN(l2_dist) FROM d1 WHERE relevant=0 AND l2_dist IS NOT NULL))/2.0, 4) as l2_threshold
UNION ALL
SELECT 'scale5',
  ROUND(((SELECT MAX(cosine_dist) FROM d5 WHERE relevant=1) +
         (SELECT MIN(cosine_dist) FROM d5 WHERE relevant=0 AND cosine_dist IS NOT NULL))/2.0, 4),
  ROUND(((SELECT MAX(l2_dist) FROM d5 WHERE relevant=1) +
         (SELECT MIN(l2_dist) FROM d5 WHERE relevant=0 AND l2_dist IS NOT NULL))/2.0, 4)
UNION ALL
SELECT 'scale10',
  ROUND(((SELECT MAX(cosine_dist) FROM d10 WHERE relevant=1) +
         (SELECT MIN(cosine_dist) FROM d10 WHERE relevant=0 AND cosine_dist IS NOT NULL))/2.0, 4),
  ROUND(((SELECT MAX(l2_dist) FROM d10 WHERE relevant=1) +
         (SELECT MIN(l2_dist) FROM d10 WHERE relevant=0 AND l2_dist IS NOT NULL))/2.0, 4);
SQL

  # Test threshold at each scale: use the scale1 midpoint as a candidate
  printf "\n  --- Threshold Test (using scale1 cosine midpoint) ---\n"

  local cos_threshold
  cos_threshold=$("$SQLITE3" "$analysis_db" "
    SELECT ROUND(((SELECT MAX(cosine_dist) FROM d1 WHERE relevant=1) +
                   (SELECT MIN(cosine_dist) FROM d1 WHERE relevant=0 AND cosine_dist IS NOT NULL))/2.0, 4);
  ")

  if [[ -n "$cos_threshold" && "$cos_threshold" != "" ]]; then
    printf "  Candidate cosine threshold: %s\n\n" "$cos_threshold"

    for tbl in d1 d5 d10; do
      local scale_label
      case "$tbl" in
        d1) scale_label="scale1" ;;
        d5) scale_label="scale5" ;;
        d10) scale_label="scale10" ;;
      esac

      printf "  %s at threshold %s:\n" "$scale_label" "$cos_threshold"
      "$SQLITE3" -header -column "$analysis_db" "
        SELECT
          SUM(CASE WHEN relevant=1 AND cosine_dist <= ${cos_threshold} THEN 1 ELSE 0 END) as true_pos,
          SUM(CASE WHEN relevant=1 AND cosine_dist > ${cos_threshold} THEN 1 ELSE 0 END) as false_neg,
          SUM(CASE WHEN relevant=0 AND cosine_dist > ${cos_threshold} THEN 1 ELSE 0 END) as true_neg,
          SUM(CASE WHEN relevant=0 AND cosine_dist <= ${cos_threshold} THEN 1 ELSE 0 END) as false_pos,
          ROUND(
            CAST(SUM(CASE WHEN relevant=1 AND cosine_dist <= ${cos_threshold} THEN 1 ELSE 0 END) AS REAL) /
            NULLIF(SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END), 0), 4
          ) as recall,
          ROUND(
            CAST(SUM(CASE WHEN relevant=1 AND cosine_dist <= ${cos_threshold} THEN 1 ELSE 0 END) AS REAL) /
            NULLIF(SUM(CASE WHEN cosine_dist <= ${cos_threshold} THEN 1 ELSE 0 END), 0), 4
          ) as precision
        FROM ${tbl}
        WHERE cosine_dist IS NOT NULL;
      "
      printf "\n"
    done
  fi

  # Also test with L2
  local l2_threshold
  l2_threshold=$("$SQLITE3" "$analysis_db" "
    SELECT ROUND(((SELECT MAX(l2_dist) FROM d1 WHERE relevant=1) +
                   (SELECT MIN(l2_dist) FROM d1 WHERE relevant=0 AND l2_dist IS NOT NULL))/2.0, 4);
  ")

  if [[ -n "$l2_threshold" && "$l2_threshold" != "" ]]; then
    printf "  --- Threshold Test (using scale1 L2 midpoint: %s) ---\n\n" "$l2_threshold"

    for tbl in d1 d5 d10; do
      local scale_label
      case "$tbl" in
        d1) scale_label="scale1" ;;
        d5) scale_label="scale5" ;;
        d10) scale_label="scale10" ;;
      esac

      printf "  %s at threshold %s:\n" "$scale_label" "$l2_threshold"
      "$SQLITE3" -header -column "$analysis_db" "
        SELECT
          SUM(CASE WHEN relevant=1 AND l2_dist <= ${l2_threshold} THEN 1 ELSE 0 END) as true_pos,
          SUM(CASE WHEN relevant=1 AND l2_dist > ${l2_threshold} THEN 1 ELSE 0 END) as false_neg,
          SUM(CASE WHEN relevant=0 AND l2_dist > ${l2_threshold} THEN 1 ELSE 0 END) as true_neg,
          SUM(CASE WHEN relevant=0 AND l2_dist <= ${l2_threshold} THEN 1 ELSE 0 END) as false_pos,
          ROUND(
            CAST(SUM(CASE WHEN relevant=1 AND l2_dist <= ${l2_threshold} THEN 1 ELSE 0 END) AS REAL) /
            NULLIF(SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END), 0), 4
          ) as recall,
          ROUND(
            CAST(SUM(CASE WHEN relevant=1 AND l2_dist <= ${l2_threshold} THEN 1 ELSE 0 END) AS REAL) /
            NULLIF(SUM(CASE WHEN l2_dist <= ${l2_threshold} THEN 1 ELSE 0 END), 0), 4
          ) as precision
        FROM ${tbl}
        WHERE l2_dist IS NOT NULL;
      "
      printf "\n"
    done
  fi

  # Negative query analysis: what distances do negative queries produce?
  printf "  --- Negative Query Distance Range ---\n"
  "$SQLITE3" -header -column "$analysis_db" <<'SQL'
SELECT 'scale1' as scale,
  ROUND(MIN(cosine_dist), 4) as min_cos,
  ROUND(AVG(cosine_dist), 4) as mean_cos,
  ROUND(MAX(cosine_dist), 4) as max_cos
FROM d1
WHERE query_id IN ('Q16','Q17','Q18','Q19','Q20')
  AND cosine_dist IS NOT NULL
UNION ALL
SELECT 'scale5',
  ROUND(MIN(cosine_dist), 4), ROUND(AVG(cosine_dist), 4), ROUND(MAX(cosine_dist), 4)
FROM d5
WHERE query_id IN ('Q16','Q17','Q18','Q19','Q20')
  AND cosine_dist IS NOT NULL
UNION ALL
SELECT 'scale10',
  ROUND(MIN(cosine_dist), 4), ROUND(AVG(cosine_dist), 4), ROUND(MAX(cosine_dist), 4)
FROM d10
WHERE query_id IN ('Q16','Q17','Q18','Q19','Q20')
  AND cosine_dist IS NOT NULL;
SQL

  rm -f "$analysis_db"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf "\033[1m=== Vector Distance Threshold Experiment ===\033[0m\n"
printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
printf "Scales: 1, 5, 10\n"
printf "Queries: 20 (10 single-cluster, 5 paraphrase, 5 negative)\n"

STARTED_AT=$(date +%s)

# Run each scale
for scale in 1 5 10; do
  scale_start=$(date +%s)
  run_scale "$scale"
  scale_end=$(date +%s)
  printf "\nScale %s completed in %d seconds\n" "$scale" "$((scale_end - scale_start))"
done

# Cross-scale analysis
cross_scale_analysis

ENDED_AT=$(date +%s)
ELAPSED=$((ENDED_AT - STARTED_AT))

printf "\n\033[1m========================================\033[0m\n"
printf "\033[1m  Experiment complete (%d minutes %d seconds)\033[0m\n" "$((ELAPSED / 60))" "$((ELAPSED % 60))"
printf "\033[1m========================================\033[0m\n"
printf "\nResults:\n"
for scale in 1 5 10; do
  if [[ -f "$RESULTS/distances-scale${scale}.csv" ]]; then
    local_count=$(wc -l < "$RESULTS/distances-scale${scale}.csv")
    printf "  distances-scale%s.csv: %s rows\n" "$scale" "$((local_count - 1))"
  fi
done

# Save analysis to file
printf "\nSaving analysis to %s/analysis.txt\n" "$RESULTS"
{
  printf "=== Vector Distance Threshold Analysis ===\n"
  printf "Date: %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
  printf "Elapsed: %d minutes %d seconds\n\n" "$((ELAPSED / 60))" "$((ELAPSED % 60))"
  cross_scale_analysis 2>/dev/null
} > "$RESULTS/analysis.txt"

printf "\nDone.\n"
