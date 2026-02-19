#!/usr/bin/env bash

# rerank.sh — measure the effect of cross-encoder reranking after RRF
#
# Seeds a 120-entry corpus, runs 20 test queries, and for each query:
#   1. Retrieves via FTS and vector independently (top 20 each)
#   2. Computes RRF scores → top 20 candidates (expanded from 10)
#   3. Reranks each candidate via gemma3:1b logprobs (yes/no scoring)
#   4. Compares precision@10 between RRF-only and RRF+rerank
#
# The reranker reads query and document together and produces a continuous
# relevance score from 0.0 to 1.0, extracted from the logprobs of the
# first generated token.
#
# Usage:
#   experiment/rerank.sh                   # scale 1 (120 entries)
#   experiment/rerank.sh --scale 5         # scale 5 (~480 entries)
#   experiment/rerank.sh --scale 10        # scale 10 (~960 entries)
#
# Output:
#   experiment/results/rerank/*.tsv  — per-query retrieval details (scale 1)
#   experiment/results/rerank-s5/*.tsv — per-query retrieval details (scale 5)
#   experiment/results/rerank/summary.md — markdown summary table
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
RERANK_CANDIDATES=20
RERANK_MODEL="${CRIB_RERANK_MODEL:-gemma3:1b}"

# Parse --scale flag
SCALE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale) SCALE="$2"; shift 2 ;;
    *) echo "error: unknown flag $1" >&2; exit 1 ;;
  esac
done

GROUND_TRUTH="$SCRIPT_DIR/ground-truth.txt"
CORPUS_SCRIPT="$SCRIPT_DIR/corpus.sh"
if [[ "$SCALE" -eq 1 ]]; then
  RESULTS="$SCRIPT_DIR/results/rerank"
else
  RESULTS="$SCRIPT_DIR/results/rerank-s${SCALE}"
fi

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

# Extract keywords — replicate crib's extraction exactly
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
# Reranker — score a (query, document) pair via logprobs
# ---------------------------------------------------------------------------

rerank_score() {
  local query="$1"
  local document="$2"

  local prompt
  prompt=$(jq -n \
    --arg query "$query" \
    --arg document "$document" \
    '"Judge whether the Document is relevant to the Query. Answer exactly \"yes\" or \"no\", nothing else.\n\nQuery: " + $query + "\n\nDocument: " + $document')

  local response
  response=$(curl -s "$OLLAMA_HOST/api/chat" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --arg model "$RERANK_MODEL" \
      --argjson content "$prompt" \
      '{
        model: $model,
        messages: [{role: "user", content: $content}],
        stream: false,
        logprobs: true,
        top_logprobs: 10,
        options: {temperature: 0.0, num_predict: 1}
      }')")

  # Extract yes/no logprobs and compute P(yes) as the relevance score
  echo "$response" | ruby -e '
    require "json"
    data = JSON.parse($stdin.read) rescue nil
    unless data && data["logprobs"] && data["logprobs"][0]
      puts "0.0"
      exit
    end

    top = data["logprobs"][0]["top_logprobs"]
    yes_lp = nil
    no_lp = nil

    top.each do |t|
      token = t["token"].strip.downcase
      if token == "yes" && yes_lp.nil?
        yes_lp = t["logprob"]
      elsif token == "no" && no_lp.nil?
        no_lp = t["logprob"]
      end
    end

    if yes_lp && no_lp
      # softmax over yes/no
      yes_p = Math.exp(yes_lp)
      no_p = Math.exp(no_lp)
      score = yes_p / (yes_p + no_p)
    elsif yes_lp
      # yes found but no was not in top — very high confidence yes
      score = 1.0
    elsif no_lp
      # no found but yes was not in top — very high confidence no
      score = 0.0
    else
      # neither found — treat as unknown
      score = 0.0
    end

    printf "%.6f\n", score
  '
}

# ---------------------------------------------------------------------------
# Phase 1 — Seed corpus
# ---------------------------------------------------------------------------

printf "\033[1m=== Reranking Experiment (scale %s) ===\033[0m\n" "$SCALE"
printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
printf "Distance threshold: %s\n" "$VECTOR_DISTANCE_THRESHOLD"
printf "RRF k: %d\n" "$RRF_K"
printf "Rerank model: %s\n" "$RERANK_MODEL"
printf "RRF candidates for reranking: %d\n" "$RERANK_CANDIDATES"
printf "Corpus scale: %s\n" "$SCALE"

STARTED_AT=$(date +%s)

TMPDIR=$(mktemp -d)
DB="$TMPDIR/experiment.db"
CLUSTER_MAP="$TMPDIR/cluster-map.txt"

trap 'rm -rf "$TMPDIR"' EXIT

printf "\n\033[1mPhase 1: Seeding corpus (scale %s)...\033[0m\n" "$SCALE"
if [[ "$SCALE" -eq 1 ]]; then
  ENTRY_COUNT=$(CRIB_DB="$DB" "$CORPUS_SCRIPT")
else
  ENTRY_COUNT=$(CRIB_DB="$DB" "$CORPUS_SCRIPT" --scale "$SCALE")
fi
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

  # --- d. Compute RRF scores (top RERANK_CANDIDATES) ---
  rrf_json=$(ruby -e '
    require "json"
    fts = JSON.parse(ARGV[0])
    vec = JSON.parse(ARGV[1])
    k = ARGV[2].to_i
    limit = ARGV[3].to_i

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
    result = sorted.first(limit).map { |id, score|
      entry_by_id[id].merge("rrf_score" => score.round(6), "channels" => channels[id].join("+"))
    }
    puts JSON.generate(result)
  ' "$fts_json" "$vec_json" "$RRF_K" "$RERANK_CANDIDATES")

  rrf_count=$(echo "$rrf_json" | jq 'length')
  printf "    RRF candidates: %s\n" "$rrf_count"

  # --- e. Rerank each RRF candidate ---
  printf "    Reranking..."
  rerank_start=$(date +%s)

  reranked_json=$(echo "$rrf_json" | jq -c '.[]' | {
    results="["
    first=true
    while read -r row; do
      content=$(echo "$row" | jq -r '.content')
      score=$(rerank_score "$query_text" "$content")
      printf "." >&2

      entry_with_score=$(echo "$row" | jq -c --arg score "$score" '. + {rerank_score: ($score | tonumber)}')

      if $first; then
        first=false
      else
        results="$results,"
      fi
      results="$results$entry_with_score"
    done
    results="$results]"
    echo "$results"
  })

  rerank_end=$(date +%s)
  rerank_elapsed=$((rerank_end - rerank_start))
  printf " %ds\n" "$rerank_elapsed"

  # Sort by rerank_score descending, take top 10
  reranked_top10=$(echo "$reranked_json" | jq -c '[sort_by(-.rerank_score) | .[:10] | .[]]' 2>/dev/null || echo "[]")
  rrf_top10=$(echo "$rrf_json" | jq -c '[.[:10] | .[]]' 2>/dev/null || echo "[]")

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

  # RRF TSV (top 10 of RRF only)
  {
    printf "rank\tentry_id\tcluster\trrf_score\tchannels\tcontent\n"
    echo "$rrf_top10" | jq -c '.[]' | {
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

  # Reranked TSV (top 10 after reranking)
  {
    printf "rank\tentry_id\tcluster\trerank_score\trrf_score\tchannels\tcontent\n"
    echo "$reranked_top10" | jq -c '.[]' | {
      rank=0
      while read -r row; do
        rank=$((rank + 1))
        eid=$(echo "$row" | jq -r '.id')
        rscore=$(echo "$row" | jq -r '.rerank_score')
        rrf_s=$(echo "$row" | jq -r '.rrf_score')
        ch=$(echo "$row" | jq -r '.channels')
        content=$(echo "$row" | jq -r '.content')
        cluster=$(entry_cluster "$eid" "$CLUSTER_MAP")
        printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n" "$rank" "$eid" "${cluster:-?}" "$rscore" "$rrf_s" "$ch" "$(truncate_content "$content")"
      done
    }
  } > "$RESULTS/${qid}-rerank.tsv"

  # Full rerank scores TSV (all candidates, for score distribution analysis)
  {
    printf "rank\tentry_id\tcluster\trerank_score\trrf_score\tchannels\tcontent\n"
    echo "$reranked_json" | jq -c '[sort_by(-.rerank_score) | .[]] | .[]' 2>/dev/null | {
      rank=0
      while read -r row; do
        rank=$((rank + 1))
        eid=$(echo "$row" | jq -r '.id')
        rscore=$(echo "$row" | jq -r '.rerank_score')
        rrf_s=$(echo "$row" | jq -r '.rrf_score')
        ch=$(echo "$row" | jq -r '.channels')
        content=$(echo "$row" | jq -r '.content')
        cluster=$(entry_cluster "$eid" "$CLUSTER_MAP")
        printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n" "$rank" "$eid" "${cluster:-?}" "$rscore" "$rrf_s" "$ch" "$(truncate_content "$content")"
      done
    }
  } > "$RESULTS/${qid}-scores.tsv"

done < <(load_queries)

# ---------------------------------------------------------------------------
# Phase 3 — Analysis
# ---------------------------------------------------------------------------

printf "\n\033[1mPhase 3: Analysis...\033[0m\n"

{
  printf "# Cross-Encoder Reranking — Experiment Results (Scale %s)\n\n" "$SCALE"
  printf "Date: %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
  printf "Distance threshold: %s\n" "$VECTOR_DISTANCE_THRESHOLD"
  printf "RRF k: %d\n" "$RRF_K"
  printf "Rerank model: %s\n" "$RERANK_MODEL"
  printf "RRF candidates for reranking: %d → top 10\n" "$RERANK_CANDIDATES"
  printf "Scale: %s\n" "$SCALE"
  printf "Corpus: %s entries\n\n" "$DB_COUNT"

  # --- Per-query comparison table: direct ---
  printf "## Direct-vocabulary queries (Q01-Q10)\n\n"
  printf "| Query | RRF P@10 | Reranked P@10 | Delta |\n"
  printf "|-------|----------|---------------|-------|\n"

  total_rrf_precision=0
  total_rerank_precision=0
  direct_count=0
  best_delta=-999
  best_query=""
  worst_delta=999
  worst_query=""

  while IFS=$'\t' read -r qid qtype clusters query_text; do
    [[ "$qtype" != "single" ]] && continue
    direct_count=$((direct_count + 1))

    # RRF precision@10
    rrf_relevant=0
    if [[ -f "$RESULTS/${qid}-rrf.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster rrf_s ch content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        rrf_relevant=$((rrf_relevant + rel))
      done < "$RESULTS/${qid}-rrf.tsv"
    fi

    # Reranked precision@10
    rerank_relevant=0
    if [[ -f "$RESULTS/${qid}-rerank.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster rscore rrf_s ch content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        rerank_relevant=$((rerank_relevant + rel))
      done < "$RESULTS/${qid}-rerank.tsv"
    fi

    delta=$((rerank_relevant - rrf_relevant))

    total_rrf_precision=$((total_rrf_precision + rrf_relevant))
    total_rerank_precision=$((total_rerank_precision + rerank_relevant))

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
    if [[ $delta -lt $worst_delta ]]; then
      worst_delta=$delta
      worst_query="$qid"
    fi

    printf "| %s | %s/10 | %s/10 | %s |\n" \
      "$qid" "$rrf_relevant" "$rerank_relevant" "$delta_str"

  done < <(load_queries)

  # --- Paraphrase queries ---
  printf "\n## Paraphrase queries (Q11-Q15)\n\n"
  printf "| Query | RRF P@10 | Reranked P@10 | Delta |\n"
  printf "|-------|----------|---------------|-------|\n"

  para_rrf_total=0
  para_rerank_total=0
  para_count=0

  while IFS=$'\t' read -r qid qtype clusters query_text; do
    [[ "$qtype" != "paraphrase" ]] && continue
    para_count=$((para_count + 1))

    rrf_relevant=0
    if [[ -f "$RESULTS/${qid}-rrf.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster rrf_s ch content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        rrf_relevant=$((rrf_relevant + rel))
      done < "$RESULTS/${qid}-rrf.tsv"
    fi

    rerank_relevant=0
    if [[ -f "$RESULTS/${qid}-rerank.tsv" ]]; then
      while IFS=$'\t' read -r rank eid cluster rscore rrf_s ch content; do
        [[ "$rank" == "rank" ]] && continue
        rel=$(is_relevant "$cluster" "$clusters")
        rerank_relevant=$((rerank_relevant + rel))
      done < "$RESULTS/${qid}-rerank.tsv"
    fi

    para_rrf_total=$((para_rrf_total + rrf_relevant))
    para_rerank_total=$((para_rerank_total + rerank_relevant))

    delta=$((rerank_relevant - rrf_relevant))
    delta_str="0"
    if [[ $delta -gt 0 ]]; then
      delta_str="+${delta}"
    elif [[ $delta -lt 0 ]]; then
      delta_str="$delta"
    fi

    printf "| %s | %s/10 | %s/10 | %s |\n" \
      "$qid" "$rrf_relevant" "$rerank_relevant" "$delta_str"

  done < <(load_queries)

  # --- Negative queries: score distribution ---
  printf "\n## Negative queries (Q16-Q20): rerank score distribution\n\n"
  printf "| Query | Candidates | Mean Score | Max Score | Scores > 0.5 |\n"
  printf "|-------|------------|------------|-----------|-------------|\n"

  while IFS=$'\t' read -r qid qtype clusters query_text; do
    [[ "$qtype" != "negative" ]] && continue

    if [[ -f "$RESULTS/${qid}-scores.tsv" ]]; then
      stats=$(tail -n +2 "$RESULTS/${qid}-scores.tsv" | ruby -e '
        scores = $stdin.readlines.map { |l| l.split("\t")[3].to_f }
        if scores.empty?
          puts "0\t0.000\t0.000\t0"
        else
          mean = scores.sum / scores.size
          max = scores.max
          above = scores.count { |s| s > 0.5 }
          printf "%d\t%.3f\t%.3f\t%d\n", scores.size, mean, max, above
        end
      ')
      IFS=$'\t' read -r n_cand mean_score max_score above_half <<< "$stats"
      printf "| %s | %s | %s | %s | %s |\n" \
        "$qid" "$n_cand" "$mean_score" "$max_score" "$above_half"
    fi

  done < <(load_queries)

  # --- Aggregate ---
  printf "\n## Aggregate\n\n"
  printf "| Query type | N | Mean RRF P@10 | Mean Reranked P@10 | Mean Delta |\n"
  printf "|------------|---|---------------|--------------------|-----------|\n"

  if [[ $direct_count -gt 0 ]]; then
    mean_rrf=$(ruby -e "printf '%.2f', ${total_rrf_precision}.to_f / ${direct_count}")
    mean_rerank=$(ruby -e "printf '%.2f', ${total_rerank_precision}.to_f / ${direct_count}")
    mean_delta=$(ruby -e "printf '%+.2f', (${total_rerank_precision}.to_f - ${total_rrf_precision}.to_f) / ${direct_count}")
    printf "| Direct (Q01-Q10) | %d | %s/10 | %s/10 | %s |\n" "$direct_count" "$mean_rrf" "$mean_rerank" "$mean_delta"
  fi

  if [[ $para_count -gt 0 ]]; then
    mean_p_rrf=$(ruby -e "printf '%.2f', ${para_rrf_total}.to_f / ${para_count}")
    mean_p_rerank=$(ruby -e "printf '%.2f', ${para_rerank_total}.to_f / ${para_count}")
    mean_p_delta=$(ruby -e "printf '%+.2f', (${para_rerank_total}.to_f - ${para_rrf_total}.to_f) / ${para_count}")
    printf "| Paraphrase (Q11-Q15) | %d | %s/10 | %s/10 | %s |\n" "$para_count" "$mean_p_rrf" "$mean_p_rerank" "$mean_p_delta"
  fi

  # --- Hero example ---
  if [[ -n "$best_query" && $best_delta -gt 0 ]]; then
    printf "\n## Hero example: %s\n\n" "$best_query"
    printf "Largest precision improvement: +%d entries\n\n" "$best_delta"

    printf "### RRF ranking (top 10)\n\n"
    printf '~~~\n'
    cat "$RESULTS/${best_query}-rrf.tsv"
    printf '~~~\n\n'

    printf "### Reranked (top 10)\n\n"
    printf '~~~\n'
    cat "$RESULTS/${best_query}-rerank.tsv"
    printf '~~~\n'
  fi

  # --- Regression example ---
  if [[ -n "$worst_query" && $worst_delta -lt 0 ]]; then
    printf "\n## Regression: %s\n\n" "$worst_query"
    printf "Largest precision regression: %d entries\n\n" "$worst_delta"

    printf "### RRF ranking (top 10)\n\n"
    printf '~~~\n'
    cat "$RESULTS/${worst_query}-rrf.tsv"
    printf '~~~\n\n'

    printf "### Reranked (top 10)\n\n"
    printf '~~~\n'
    cat "$RESULTS/${worst_query}-rerank.tsv"
    printf '~~~\n'
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
