#!/usr/bin/env bash

# rrf.sh — measure the effect of Reciprocal Rank Fusion vs union merge
#
# Seeds a 120-entry corpus, runs 20 test queries, and for each query:
#   1. Retrieves via FTS and vector independently
#   2. Computes RRF scores (matching crib's implementation)
#   3. Reconstructs the old union merge (dedup by ID, sort by created_at DESC)
#   4. Compares precision@10 between RRF and union
#
# Usage:
#   experiment/rrf.sh
#
# Output:
#   experiment/results/rrf/*.tsv  — per-query retrieval details
#   experiment/results/rrf/summary.md — markdown summary table
#
# Dependencies: crib, ollama, sqlite3 (with sqlite-vec), jq, ruby

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
VECTOR_DISTANCE_THRESHOLD="${CRIB_VECTOR_THRESHOLD:-0.5}"
RRF_K=60

GROUND_TRUTH="$SCRIPT_DIR/ground-truth.txt"
CORPUS_SCRIPT="$SCRIPT_DIR/corpus.sh"
RESULTS="$SCRIPT_DIR/results/rrf"

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
# Stop words — exact copy from crib lines 423-430
# ---------------------------------------------------------------------------

STOP_WORDS="a an the is are was were be been being have has had do does did
will would shall should may might can could of in to for on with
at by from as into about between through during before after
and or but not no nor so yet both either neither each every all
any few more most other some such this that these those
i me my we our you your he him his she her it its they them their
what which who whom how when where why if then else
just also very too quite rather really"

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

sql_json() {
  local db="$1"
  shift
  "$SQLITE3" -json "$db" "$@"
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

# Extract keywords — replicate crib's extraction exactly:
# downcase, strip non-word chars, split, reject length < 3, reject stop words, dedup
extract_keywords() {
  local prompt="$1"
  echo "$prompt" | ruby -e '
    stop = %w[a an the is are was were be been being have has had do does did
              will would shall should may might can could of in to for on with
              at by from as into about between through during before after
              and or but not no nor so yet both either neither each every all
              any few more most other some such this that these those
              i me my we our you your he him his she her it its they them their
              what which who whom how when where why if then else
              just also very too quite rather really]
    words = $stdin.read.downcase.gsub(/[^\w\s]/, "").split
    puts words.reject { |w| w.length < 3 || stop.include?(w) }.uniq.join(" ")
  '
}

# Load queries from ground truth
load_queries() {
  grep -v '^#' "$GROUND_TRUTH" | grep -v '^$'
}

# Resolve cluster for an entry ID from cluster-map.txt
entry_cluster() {
  local entry_id="$1"
  local cluster_map="$2"
  grep "^${entry_id}	" "$cluster_map" | cut -f2
}

# Check if entry is relevant to query's target clusters
is_relevant() {
  local entry_cluster="$1"
  local target_clusters="$2"

  if [[ -z "$target_clusters" || "$target_clusters" == "none" ]]; then
    echo "0"
    return
  fi

  IFS=',' read -ra targets <<< "$target_clusters"
  for c in "${targets[@]}"; do
    if [[ "$entry_cluster" == "$c" ]]; then
      echo "1"
      return
    fi
  done
  echo "0"
}

# Truncate content for TSV output
truncate_content() {
  echo "$1" | cut -c1-80 | tr '\t\n' '  '
}

# ---------------------------------------------------------------------------
# Phase 1 — Seed corpus
# ---------------------------------------------------------------------------

printf "\033[1m=== RRF Experiment ===\033[0m\n"
printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
printf "Distance threshold: %s\n" "$VECTOR_DISTANCE_THRESHOLD"
printf "RRF k: %d\n" "$RRF_K"

STARTED_AT=$(date +%s)

TMPDIR=$(mktemp -d)
DB="$TMPDIR/experiment.db"
CLUSTER_MAP="$TMPDIR/cluster-map.txt"

trap 'rm -rf "$TMPDIR"' EXIT

printf "\n\033[1mPhase 1: Seeding corpus...\033[0m\n"
ENTRY_COUNT=$(CRIB_DB="$DB" "$CORPUS_SCRIPT")
printf "Seeded %s entries\n" "$ENTRY_COUNT"

if [[ ! -f "$CLUSTER_MAP" ]]; then
  echo "error: cluster-map.txt not generated at $CLUSTER_MAP" >&2
  exit 1
fi

DB_COUNT=$("$SQLITE3" "$DB" "SELECT COUNT(*) FROM entries;")
printf "Database contains %s entries\n" "$DB_COUNT"

# ---------------------------------------------------------------------------
# Phase 2 — Per-query data collection
# ---------------------------------------------------------------------------

printf "\n\033[1mPhase 2: Running queries...\033[0m\n"

query_num=0
while IFS=$'\t' read -r qid qtype clusters query_text; do
  query_num=$((query_num + 1))
  printf "\n  [%2d/20] %s (%s): %s\n" "$query_num" "$qid" "$qtype" "$query_text"

  # --- a. Extract keywords ---
  keywords=$(extract_keywords "$query_text")
  printf "    Keywords: %s\n" "${keywords:-<none>}"

  # --- b. FTS retrieval ---
  fts_json="[]"
  if [[ -n "$keywords" ]]; then
    fts_query=$(echo "$keywords" | tr ' ' '\n' | paste -sd' ' - | sed 's/ / OR /g')
    fts_json=$(sql_json "$DB" "
      SELECT e.id, e.type, e.content, e.created_at
      FROM entries e
      JOIN entries_fts f ON e.id = f.rowid
      WHERE entries_fts MATCH '$(echo "$fts_query" | sed "s/'/''/g")'
      ORDER BY e.created_at DESC
      LIMIT 20;
    " 2>/dev/null || echo "[]")
  fi
  fts_count=$(echo "$fts_json" | jq 'length')
  printf "    FTS results: %s\n" "$fts_count"

  # --- c. Vector retrieval ---
  vec_json="[]"
  query_vec=$(embed_query "$query_text")
  if [[ -n "$query_vec" && "$query_vec" != "null" ]]; then
    escaped_vec=$(echo "$query_vec" | sed "s/'/''/g")
    raw_vec_json=$(sql_vec_json "$DB" "
      SELECT rowid, distance
      FROM entries_vec
      WHERE embedding MATCH '${escaped_vec}'
      ORDER BY distance
      LIMIT 20;
    " 2>/dev/null || echo "[]")

    # Filter by distance threshold and resolve entry metadata
    filtered_ids=$(echo "$raw_vec_json" | jq -r --argjson thresh "$VECTOR_DISTANCE_THRESHOLD" \
      '[.[] | select(.distance <= $thresh)] | .[].rowid' 2>/dev/null)

    if [[ -n "$filtered_ids" ]]; then
      id_list=$(echo "$filtered_ids" | paste -sd',' -)
      entries_json=$(sql_json "$DB" "SELECT id, type, content, created_at FROM entries WHERE id IN ($id_list);")

      # Merge distance into entry records and sort by distance
      vec_json=$(echo "$raw_vec_json" | jq -c --argjson thresh "$VECTOR_DISTANCE_THRESHOLD" \
        --argjson entries "$entries_json" '
        [.[] | select(.distance <= $thresh)] as $vecs |
        [$vecs[] |
          . as $v |
          ($entries | map(select(.id == $v.rowid)) | .[0]) as $e |
          if $e then ($e + {distance: $v.distance}) else empty end
        ] | sort_by(.distance)
      ')
    fi
  fi
  vec_count=$(echo "$vec_json" | jq 'length')
  printf "    Vector results: %s\n" "$vec_count"

  # --- d. Compute RRF scores ---
  rrf_json=$(ruby -e '
    require "json"
    fts = JSON.parse(ARGV[0])
    vec = JSON.parse(ARGV[1])
    k = ARGV[2].to_i

    scores = Hash.new(0.0)
    entry_by_id = {}
    channels = Hash.new { |h,k| h[k] = [] }

    fts.each_with_index do |entry, rank|
      id = entry["id"]
      scores[id] += 1.0 / (k + rank + 1)
      entry_by_id[id] = entry
      channels[id] << "fts"
    end

    vec.each_with_index do |entry, rank|
      id = entry["id"]
      scores[id] += 1.0 / (k + rank + 1)
      entry_by_id[id] ||= entry
      channels[id] << "vec"
    end

    sorted = scores.sort_by { |_id, score| -score }
    result = sorted.first(10).map { |id, score|
      entry_by_id[id].merge("rrf_score" => score.round(6), "channels" => channels[id].join("+"))
    }
    puts JSON.generate(result)
  ' "$fts_json" "$vec_json" "$RRF_K")

  rrf_count=$(echo "$rrf_json" | jq 'length')
  printf "    RRF results: %s\n" "$rrf_count"

  # --- e. Reconstruct union merge ---
  union_json=$(ruby -e '
    require "json"
    fts = JSON.parse(ARGV[0])
    vec = JSON.parse(ARGV[1])

    seen = {}
    combined = []
    (fts + vec).each do |entry|
      id = entry["id"]
      next if seen[id]
      seen[id] = true
      combined << entry
    end

    # Sort by created_at DESC (old behavior)
    combined.sort_by! { |e| e["created_at"] || "" }.reverse!
    puts JSON.generate(combined.first(10))
  ' "$fts_json" "$vec_json")

  union_count=$(echo "$union_json" | jq 'length')
  printf "    Union results: %s\n" "$union_count"

  # --- f. Write per-query TSV files ---

  # FTS TSV
  {
    printf "rank\tentry_id\tcluster\tcontent\n"
    echo "$fts_json" | jq -c '.[]' | {
      rank=0
      while read -r row; do
        rank=$((rank + 1))
        eid=$(echo "$row" | jq -r '.id')
        content=$(echo "$row" | jq -r '.content')
        cluster=$(entry_cluster "$eid" "$CLUSTER_MAP")
        printf "%d\t%s\t%s\t%s\n" "$rank" "$eid" "${cluster:-?}" "$(truncate_content "$content")"
      done
    }
  } > "$RESULTS/${qid}-fts.tsv"

  # Vector TSV
  {
    printf "rank\tentry_id\tcluster\tdistance\tcontent\n"
    echo "$vec_json" | jq -c '.[]' | {
      rank=0
      while read -r row; do
        rank=$((rank + 1))
        eid=$(echo "$row" | jq -r '.id')
        dist=$(echo "$row" | jq -r '.distance')
        content=$(echo "$row" | jq -r '.content')
        cluster=$(entry_cluster "$eid" "$CLUSTER_MAP")
        printf "%d\t%s\t%s\t%s\t%s\n" "$rank" "$eid" "${cluster:-?}" "$dist" "$(truncate_content "$content")"
      done
    }
  } > "$RESULTS/${qid}-vector.tsv"

  # RRF TSV
  {
    printf "rank\tentry_id\tcluster\tscore\tchannels\tcontent\n"
    echo "$rrf_json" | jq -c '.[]' | {
      rank=0
      while read -r row; do
        rank=$((rank + 1))
        eid=$(echo "$row" | jq -r '.id')
        score=$(echo "$row" | jq -r '.rrf_score')
        ch=$(echo "$row" | jq -r '.channels')
        content=$(echo "$row" | jq -r '.content')
        cluster=$(entry_cluster "$eid" "$CLUSTER_MAP")
        printf "%d\t%s\t%s\t%s\t%s\t%s\n" "$rank" "$eid" "${cluster:-?}" "$score" "$ch" "$(truncate_content "$content")"
      done
    }
  } > "$RESULTS/${qid}-rrf.tsv"

  # Union TSV
  {
    printf "rank\tentry_id\tcluster\tcontent\n"
    echo "$union_json" | jq -c '.[]' | {
      rank=0
      while read -r row; do
        rank=$((rank + 1))
        eid=$(echo "$row" | jq -r '.id')
        content=$(echo "$row" | jq -r '.content')
        cluster=$(entry_cluster "$eid" "$CLUSTER_MAP")
        printf "%d\t%s\t%s\t%s\n" "$rank" "$eid" "${cluster:-?}" "$(truncate_content "$content")"
      done
    }
  } > "$RESULTS/${qid}-union.tsv"

done < <(load_queries)

# ---------------------------------------------------------------------------
# Phase 3 — Analysis
# ---------------------------------------------------------------------------

printf "\n\033[1mPhase 3: Analysis...\033[0m\n"

{
  printf "# RRF vs Union — Experiment Results\n\n"
  printf "Date: %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
  printf "Distance threshold: %s\n" "$VECTOR_DISTANCE_THRESHOLD"
  printf "RRF k: %d\n" "$RRF_K"
  printf "Corpus: %s entries\n\n" "$DB_COUNT"

  # --- Per-query comparison table ---
  printf "## Per-query results (Q01-Q10: direct vocabulary)\n\n"
  printf "| Query | FTS | Vec | Both | Union P@10 | RRF P@10 | Delta |\n"
  printf "|-------|-----|-----|------|------------|----------|-------|\n"

  total_union_precision=0
  total_rrf_precision=0
  direct_count=0
  best_delta=0
  best_query=""

  while IFS=$'\t' read -r qid qtype clusters query_text; do
    [[ "$qtype" != "single" ]] && continue
    direct_count=$((direct_count + 1))

    # Count FTS hits, vector hits for this query
    fts_ids=""
    if [[ -f "$RESULTS/${qid}-fts.tsv" ]]; then
      fts_ids=$(tail -n +2 "$RESULTS/${qid}-fts.tsv" | cut -f2 | sort)
    fi
    vec_ids=""
    if [[ -f "$RESULTS/${qid}-vector.tsv" ]]; then
      vec_ids=$(tail -n +2 "$RESULTS/${qid}-vector.tsv" | cut -f2 | sort)
    fi

    fts_n=$(echo "$fts_ids" | grep -c . || true)
    vec_n=$(echo "$vec_ids" | grep -c . || true)

    # Count entries in both channels
    both_n=0
    if [[ -n "$fts_ids" && -n "$vec_ids" ]]; then
      both_n=$(comm -12 <(echo "$fts_ids") <(echo "$vec_ids") | grep -c . || true)
    fi

    # Union precision@10
    union_relevant=0
    if [[ -f "$RESULTS/${qid}-union.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        union_relevant=$((union_relevant + rel))
      done < "$RESULTS/${qid}-union.tsv"
    fi

    # RRF precision@10
    rrf_relevant=0
    if [[ -f "$RESULTS/${qid}-rrf.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster score ch content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        rrf_relevant=$((rrf_relevant + rel))
      done < "$RESULTS/${qid}-rrf.tsv"
    fi

    union_p=$(ruby -e "printf '%.1f', ${union_relevant}.to_f / 10 * 10")
    rrf_p=$(ruby -e "printf '%.1f', ${rrf_relevant}.to_f / 10 * 10")
    delta=$((rrf_relevant - union_relevant))

    total_union_precision=$((total_union_precision + union_relevant))
    total_rrf_precision=$((total_rrf_precision + rrf_relevant))

    delta_str="0"
    if [[ $delta -gt 0 ]]; then
      delta_str="+${delta}"
    elif [[ $delta -lt 0 ]]; then
      delta_str="$delta"
    fi

    if [[ $delta -gt $best_delta ]]; then
      best_delta=$delta
      best_query="$qid"
    fi

    printf "| %s | %s | %s | %s | %s/10 | %s/10 | %s |\n" \
      "$qid" "$fts_n" "$vec_n" "$both_n" "$union_relevant" "$rrf_relevant" "$delta_str"

  done < <(load_queries)

  # --- Paraphrase queries ---
  printf "\n## Paraphrase queries (Q11-Q15: vector-only)\n\n"
  printf "| Query | FTS | Vec | Union P@10 | RRF P@10 | Notes |\n"
  printf "|-------|-----|-----|------------|----------|-------|\n"

  para_union_total=0
  para_rrf_total=0
  para_count=0

  while IFS=$'\t' read -r qid qtype clusters query_text; do
    [[ "$qtype" != "paraphrase" ]] && continue
    para_count=$((para_count + 1))

    fts_n=0
    if [[ -f "$RESULTS/${qid}-fts.tsv" ]]; then
      fts_n=$(( $(wc -l < "$RESULTS/${qid}-fts.tsv") - 1 ))
      [[ $fts_n -lt 0 ]] && fts_n=0
    fi
    vec_n=0
    if [[ -f "$RESULTS/${qid}-vector.tsv" ]]; then
      vec_n=$(( $(wc -l < "$RESULTS/${qid}-vector.tsv") - 1 ))
      [[ $vec_n -lt 0 ]] && vec_n=0
    fi

    union_relevant=0
    if [[ -f "$RESULTS/${qid}-union.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        union_relevant=$((union_relevant + rel))
      done < "$RESULTS/${qid}-union.tsv"
    fi

    rrf_relevant=0
    if [[ -f "$RESULTS/${qid}-rrf.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster score ch content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        rrf_relevant=$((rrf_relevant + rel))
      done < "$RESULTS/${qid}-rrf.tsv"
    fi

    para_union_total=$((para_union_total + union_relevant))
    para_rrf_total=$((para_rrf_total + rrf_relevant))

    notes="vector-only passthrough"
    [[ $fts_n -gt 0 ]] && notes="unexpected FTS hits"

    printf "| %s | %s | %s | %s/10 | %s/10 | %s |\n" \
      "$qid" "$fts_n" "$vec_n" "$union_relevant" "$rrf_relevant" "$notes"

  done < <(load_queries)

  # --- Negative queries ---
  printf "\n## Negative queries (Q16-Q20: nothing relevant)\n\n"
  printf "| Query | FTS | Vec | Notes |\n"
  printf "|-------|-----|-----|-------|\n"

  while IFS=$'\t' read -r qid qtype clusters query_text; do
    [[ "$qtype" != "negative" ]] && continue

    fts_n=0
    if [[ -f "$RESULTS/${qid}-fts.tsv" ]]; then
      fts_n=$(( $(wc -l < "$RESULTS/${qid}-fts.tsv") - 1 ))
      [[ $fts_n -lt 0 ]] && fts_n=0
    fi
    vec_n=0
    if [[ -f "$RESULTS/${qid}-vector.tsv" ]]; then
      vec_n=$(( $(wc -l < "$RESULTS/${qid}-vector.tsv") - 1 ))
      [[ $vec_n -lt 0 ]] && vec_n=0
    fi

    notes=""
    [[ $fts_n -eq 0 && $vec_n -eq 0 ]] && notes="correctly empty"
    [[ $fts_n -gt 0 ]] && notes="unexpected FTS hits"
    [[ $vec_n -gt 0 ]] && notes="${notes:+$notes; }vector returned results (below threshold?)"

    printf "| %s | %s | %s | %s |\n" "$qid" "$fts_n" "$vec_n" "$notes"

  done < <(load_queries)

  # --- Aggregate ---
  printf "\n## Aggregate\n\n"
  printf "| Query type | N | Mean Union P@10 | Mean RRF P@10 | Mean Delta |\n"
  printf "|------------|---|-----------------|---------------|------------|\n"

  if [[ $direct_count -gt 0 ]]; then
    mean_union=$(ruby -e "printf '%.2f', ${total_union_precision}.to_f / ${direct_count}")
    mean_rrf=$(ruby -e "printf '%.2f', ${total_rrf_precision}.to_f / ${direct_count}")
    mean_delta=$(ruby -e "printf '%+.2f', (${total_rrf_precision}.to_f - ${total_union_precision}.to_f) / ${direct_count}")
    printf "| Direct (Q01-Q10) | %d | %s/10 | %s/10 | %s |\n" "$direct_count" "$mean_union" "$mean_rrf" "$mean_delta"
  fi

  if [[ $para_count -gt 0 ]]; then
    mean_p_union=$(ruby -e "printf '%.2f', ${para_union_total}.to_f / ${para_count}")
    mean_p_rrf=$(ruby -e "printf '%.2f', ${para_rrf_total}.to_f / ${para_count}")
    mean_p_delta=$(ruby -e "printf '%+.2f', (${para_rrf_total}.to_f - ${para_union_total}.to_f) / ${para_count}")
    printf "| Paraphrase (Q11-Q15) | %d | %s/10 | %s/10 | %s |\n" "$para_count" "$mean_p_union" "$mean_p_rrf" "$mean_p_delta"
  fi

  # --- Hero example ---
  if [[ -n "$best_query" && $best_delta -gt 0 ]]; then
    printf "\n## Hero example: %s\n\n" "$best_query"
    printf "Largest precision improvement: +%d entries\n\n" "$best_delta"

    printf "### FTS ranking\n\n"
    printf '```\n'
    cat "$RESULTS/${best_query}-fts.tsv"
    printf '```\n\n'

    printf "### Vector ranking\n\n"
    printf '```\n'
    cat "$RESULTS/${best_query}-vector.tsv"
    printf '```\n\n'

    printf "### RRF ranking\n\n"
    printf '```\n'
    cat "$RESULTS/${best_query}-rrf.tsv"
    printf '```\n\n'

    printf "### Union ranking\n\n"
    printf '```\n'
    cat "$RESULTS/${best_query}-union.tsv"
    printf '```\n'
  elif [[ $best_delta -eq 0 ]]; then
    printf "\n## Hero example\n\n"
    printf "No query showed a precision improvement from RRF over union.\n"
    printf "This may indicate the corpus is too small for dual-channel agreement to help.\n"

    # Still show the query with the most dual-channel overlap as a detailed example
    most_both=0
    most_both_query=""
    while IFS=$'\t' read -r qid qtype clusters query_text; do
      [[ "$qtype" != "single" ]] && continue
      if [[ -f "$RESULTS/${qid}-rrf.tsv" ]]; then
        both_count=$(tail -n +2 "$RESULTS/${qid}-rrf.tsv" | awk -F'\t' '$5 == "fts+vec" {n++} END {print n+0}')
        if [[ $both_count -gt $most_both ]]; then
          most_both=$both_count
          most_both_query="$qid"
        fi
      fi
    done < <(load_queries)

    if [[ -n "$most_both_query" ]]; then
      printf "\nMost dual-channel entries: %s (%d entries in both channels)\n\n" "$most_both_query" "$most_both"
      printf "### RRF ranking for %s\n\n" "$most_both_query"
      printf '```\n'
      cat "$RESULTS/${most_both_query}-rrf.tsv"
      printf '```\n\n'
      printf "### Union ranking for %s\n\n" "$most_both_query"
      printf '```\n'
      cat "$RESULTS/${most_both_query}-union.tsv"
      printf '```\n'
    fi
  fi

} > "$RESULTS/summary.md"

# Print summary to stdout too
cat "$RESULTS/summary.md"

ENDED_AT=$(date +%s)
ELAPSED=$((ENDED_AT - STARTED_AT))

printf "\n\033[1m========================================\033[0m\n"
printf "\033[1m  Experiment complete (%d minutes %d seconds)\033[0m\n" "$((ELAPSED / 60))" "$((ELAPSED % 60))"
printf "\033[1m========================================\033[0m\n"
printf "\nResults in: %s\n" "$RESULTS"
printf "Summary: %s/summary.md\n" "$RESULTS"
