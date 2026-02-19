#!/usr/bin/env bash

# rrf-scale.sh — measure RRF vs union merge across corpus sizes
#
# Tests whether dual-channel overlap strengthens or weakens as the corpus
# grows from 120 to 10,000 entries. Uses the same 20 queries and 10 topical
# clusters as rrf.sh but adds background entries to increase scale.
#
# Usage:
#   experiment/rrf-scale.sh                         # run all scales
#   experiment/rrf-scale.sh --scales 120,1000       # specific scales
#
# Output:
#   experiment/results/rrf-scale/scale-N/           — per-query TSV files
#   experiment/results/rrf-scale/summary.md         — cross-scale comparison
#
# Dependencies: ollama (nomic-embed-text, gemma3:1b), sqlite3 (with sqlite-vec), jq, ruby

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SQLITE3="${CRIB_SQLITE3:-/opt/homebrew/opt/sqlite/bin/sqlite3}"
VEC_EXTENSION="${CRIB_VEC_EXTENSION:-$(python3 -c 'import sqlite_vec; print(sqlite_vec.loadable_path())' 2>/dev/null || echo 'vec0')}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
EMBEDDING_MODEL="${CRIB_EMBEDDING_MODEL:-nomic-embed-text}"
GENERATION_MODEL="${CRIB_GENERATION_MODEL:-gemma3:1b}"
VECTOR_DISTANCE_THRESHOLD="${CRIB_VECTOR_THRESHOLD:-0.5}"
RRF_K=60

GROUND_TRUTH="$SCRIPT_DIR/ground-truth.txt"
RESULTS="$SCRIPT_DIR/results/rrf-scale"
ENTRY_CACHE="$SCRIPT_DIR/results/sensitivity/background-entries.txt"

# Default scales
SCALES=(120 1000 10000)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scales) IFS=',' read -ra SCALES <<< "$2"; shift 2 ;;
    *) echo "error: unknown flag $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$RESULTS"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sql_vec() {
  local db="$1"; shift
  "$SQLITE3" -cmd ".load $VEC_EXTENSION" "$db" "$@"
}

sql_vec_json() {
  local db="$1"; shift
  "$SQLITE3" -json -cmd ".load $VEC_EXTENSION" "$db" "$@"
}

sql_json() {
  local db="$1"; shift
  "$SQLITE3" -json "$db" "$@"
}

embed_query() {
  local text="$1"
  curl -s "$OLLAMA_HOST/api/embed" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$EMBEDDING_MODEL" --arg input "$text" \
      '{model: $model, input: $input}')" \
    | jq -c '.embeddings[0]'
}

embed_batch() {
  local texts_json="$1"
  curl -s "$OLLAMA_HOST/api/embed" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$EMBEDDING_MODEL" --argjson input "$texts_json" \
      '{model: $model, input: $input}')" \
    | jq -c '.embeddings'
}

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

load_queries() {
  grep -v '^#' "$GROUND_TRUTH" | grep -v '^$'
}

# Load base entries from corpus.sh heredoc
load_base_entries() {
  sed -n "/^corpus_entries()/,/^ENTRIES$/p" "$SCRIPT_DIR/corpus.sh" \
    | sed '1,2d;$d'
}

entry_cluster() {
  local entry_id="$1"
  local cluster_map="$2"
  grep "^${entry_id}	" "$cluster_map" | cut -f2
}

is_relevant() {
  local entry_cluster="$1"
  local target_clusters="$2"
  if [[ -z "$target_clusters" || "$target_clusters" == "none" ]]; then
    echo "0"; return
  fi
  IFS=',' read -ra targets <<< "$target_clusters"
  for c in "${targets[@]}"; do
    if [[ "$entry_cluster" == "$c" ]]; then
      echo "1"; return
    fi
  done
  echo "0"
}

truncate_content() {
  echo "$1" | cut -c1-80 | tr '\t\n' '  '
}

# ---------------------------------------------------------------------------
# Database creation — entries + FTS + vec
# ---------------------------------------------------------------------------

create_db() {
  local db="$1"
  "$SQLITE3" "$db" "
    CREATE TABLE entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content TEXT NOT NULL,
      cluster_id INTEGER NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    );
    CREATE VIRTUAL TABLE entries_fts USING fts5(
      content,
      content=entries,
      content_rowid=id,
      tokenize='porter unicode61'
    );
    CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN
      INSERT INTO entries_fts(rowid, content) VALUES (new.id, new.content);
    END;
  "
  sql_vec "$db" "
    CREATE VIRTUAL TABLE entries_vec USING vec0(
      embedding float[768] distance_metric=cosine
    );
  "
}

# ---------------------------------------------------------------------------
# Batch insert entries + embeddings
# ---------------------------------------------------------------------------

batch_insert() {
  local db="$1" cluster_id="$2" texts="$3" embeddings_json="$4" cluster_map="$5"
  local sql_file
  sql_file=$(mktemp)

  # Insert entries (FTS trigger handles indexing)
  local i=0
  echo "BEGIN TRANSACTION;" > "$sql_file"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local escaped
    escaped=$(printf '%s' "$line" | sed "s/'/''/g")
    echo "INSERT INTO entries (content, cluster_id) VALUES ('${escaped}', ${cluster_id});" >> "$sql_file"
    i=$((i + 1))
  done <<< "$texts"
  echo "COMMIT;" >> "$sql_file"

  "$SQLITE3" "$db" < "$sql_file"

  # Get the IDs just inserted
  local ids
  ids=$("$SQLITE3" "$db" "SELECT id FROM entries ORDER BY id DESC LIMIT ${i};" | sort -n)

  # Insert embeddings
  local idx=0
  echo "BEGIN TRANSACTION;" > "$sql_file"
  while IFS= read -r entry_id; do
    [[ -z "$entry_id" ]] && continue
    local emb
    emb=$(echo "$embeddings_json" | jq -c ".[$idx]")
    echo "INSERT INTO entries_vec(rowid, embedding) VALUES (${entry_id}, '${emb}');" >> "$sql_file"
    printf "%s\t%s\n" "$entry_id" "$cluster_id" >> "$cluster_map"
    idx=$((idx + 1))
  done <<< "$ids"
  echo "COMMIT;" >> "$sql_file"

  "$SQLITE3" -cmd ".load $VEC_EXTENSION" "$db" < "$sql_file"
  rm -f "$sql_file"
  echo "$idx"
}

# ---------------------------------------------------------------------------
# Seed base entries (batch embedded)
# ---------------------------------------------------------------------------

seed_base_entries() {
  local db="$1" cluster_map="$2"

  declare -A cluster_texts

  while IFS='|' read -r cluster_id entry_text; do
    [[ -z "$cluster_id" ]] && continue
    if [[ -n "${cluster_texts[$cluster_id]:-}" ]]; then
      cluster_texts[$cluster_id]+=$'\n'"$entry_text"
    else
      cluster_texts[$cluster_id]="$entry_text"
    fi
  done < <(load_base_entries)

  local total=0
  for cid in $(echo "${!cluster_texts[@]}" | tr ' ' '\n' | sort -n); do
    local texts="${cluster_texts[$cid]}"
    local texts_json
    texts_json=$(echo "$texts" | jq -R -s 'split("\n") | map(select(length > 0))')

    local embeddings
    embeddings=$(embed_batch "$texts_json")
    if [[ -z "$embeddings" || "$embeddings" == "null" ]]; then
      printf "    SKIP cluster %s (embed failed)\n" "$cid" >&2
      continue
    fi

    local inserted
    inserted=$(batch_insert "$db" "$cid" "$texts" "$embeddings" "$cluster_map")
    total=$((total + inserted))
    printf "    base: %d entries (cluster %s)\r" "$total" "$cid" >&2
  done

  printf "    base: %d entries seeded           \n" "$total" >&2
  echo "$total"
}

# ---------------------------------------------------------------------------
# Seed background entries from cache
# ---------------------------------------------------------------------------

seed_background_entries() {
  local db="$1" target_count="$2" cluster_map="$3"

  if [[ ! -f "$ENTRY_CACHE" ]]; then
    printf "    error: no cached background entries at %s\n" "$ENTRY_CACHE" >&2
    echo "0"
    return
  fi

  local have
  have=$(wc -l < "$ENTRY_CACHE" | tr -d ' ')
  if [[ "$have" -lt "$target_count" ]]; then
    printf "    warn: cache has %d entries, need %d\n" "$have" "$target_count" >&2
    target_count=$have
  fi

  local total=0
  local batch_size=20
  local batch_texts=""
  local batch_count=0
  local seed_start
  seed_start=$(date +%s)

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ -n "$batch_texts" ]]; then
      batch_texts+=$'\n'"$line"
    else
      batch_texts="$line"
    fi
    batch_count=$((batch_count + 1))

    if [[ "$batch_count" -ge "$batch_size" ]]; then
      local texts_json
      texts_json=$(echo "$batch_texts" | jq -R -s 'split("\n") | map(select(length > 0))')

      local embeddings
      embeddings=$(embed_batch "$texts_json")
      if [[ -n "$embeddings" && "$embeddings" != "null" ]]; then
        local inserted
        inserted=$(batch_insert "$db" "-1" "$batch_texts" "$embeddings" "$cluster_map")
        total=$((total + inserted))
      fi

      batch_texts=""
      batch_count=0

      local pct=$((total * 100 / target_count))
      local elapsed=$(($(date +%s) - seed_start))
      local rate=0
      if [[ "$elapsed" -gt 0 ]]; then
        rate=$((total * 10 / elapsed))
      fi
      printf "    background: %d/%d (%d%%) — %d.%d entries/sec\r" \
        "$total" "$target_count" "$pct" "$((rate/10))" "$((rate%10))" >&2
    fi

    if [[ "$total" -ge "$target_count" ]]; then
      break
    fi
  done < <(head -n "$target_count" "$ENTRY_CACHE")

  # Flush remaining
  if [[ -n "$batch_texts" && "$total" -lt "$target_count" ]]; then
    local texts_json
    texts_json=$(echo "$batch_texts" | jq -R -s 'split("\n") | map(select(length > 0))')
    local embeddings
    embeddings=$(embed_batch "$texts_json")
    if [[ -n "$embeddings" && "$embeddings" != "null" ]]; then
      local inserted
      inserted=$(batch_insert "$db" "-1" "$batch_texts" "$embeddings" "$cluster_map")
      total=$((total + inserted))
    fi
  fi

  printf "    background: %d entries seeded              \n" "$total" >&2
  echo "$total"
}

# ---------------------------------------------------------------------------
# Run one scale
# ---------------------------------------------------------------------------

run_scale() {
  local scale="$1"
  local scale_dir="$RESULTS/scale-${scale}"
  mkdir -p "$scale_dir"

  local tmpdir
  tmpdir=$(mktemp -d)
  local db="$tmpdir/rrf-scale.db"
  local cluster_map="$tmpdir/cluster-map.txt"
  > "$cluster_map"

  printf "\n\033[1m========================================\033[0m\n"
  printf "\033[1m  Scale %s\033[0m\n" "$scale"
  printf "\033[1m========================================\033[0m\n"

  # Create database
  create_db "$db"

  # Seed base entries (120)
  printf "\n  Seeding base entries...\n" >&2
  local base_count
  base_count=$(seed_base_entries "$db" "$cluster_map")

  # Add background entries if needed
  local bg_count=0
  if [[ "$scale" -gt "$base_count" ]]; then
    local needed=$((scale - base_count))
    printf "\n  Seeding %d background entries...\n" "$needed" >&2
    bg_count=$(seed_background_entries "$db" "$needed" "$cluster_map")
  fi

  local total=$((base_count + bg_count))
  local db_count
  db_count=$("$SQLITE3" "$db" "SELECT COUNT(*) FROM entries;")
  printf "\n  Total entries: %d (base: %d, background: %d, db: %s)\n" "$total" "$base_count" "$bg_count" "$db_count" >&2

  # --- Run queries ---
  printf "\n  Running queries...\n" >&2

  # Per-query data for summary
  local query_data=""

  local query_num=0
  while IFS=$'\t' read -r qid qtype clusters query_text; do
    query_num=$((query_num + 1))
    printf "    [%2d/20] %s (%s): %s\n" "$query_num" "$qid" "$qtype" "$query_text" >&2

    # --- FTS retrieval ---
    local keywords fts_json
    keywords=$(extract_keywords "$query_text")
    fts_json="[]"
    if [[ -n "$keywords" ]]; then
      local fts_query
      fts_query=$(echo "$keywords" | tr ' ' '\n' | paste -sd' ' - | sed 's/ / OR /g')
      fts_json=$(sql_json "$db" "
        SELECT e.id, e.content, e.created_at
        FROM entries e
        JOIN entries_fts f ON e.id = f.rowid
        WHERE entries_fts MATCH '$(echo "$fts_query" | sed "s/'/''/g")'
        ORDER BY e.created_at DESC
        LIMIT 20;
      " 2>/dev/null || echo "[]")
    fi
    local fts_count
    fts_count=$(echo "$fts_json" | jq 'length')

    # --- Vector retrieval ---
    local vec_json="[]"
    local query_vec
    query_vec=$(embed_query "$query_text")
    if [[ -n "$query_vec" && "$query_vec" != "null" ]]; then
      local escaped_vec
      escaped_vec=$(echo "$query_vec" | sed "s/'/''/g")
      local raw_vec_json
      raw_vec_json=$(sql_vec_json "$db" "
        SELECT rowid, distance
        FROM entries_vec
        WHERE embedding MATCH '${escaped_vec}'
        ORDER BY distance
        LIMIT 20;
      " 2>/dev/null || echo "[]")

      local filtered_ids
      filtered_ids=$(echo "$raw_vec_json" | jq -r --argjson thresh "$VECTOR_DISTANCE_THRESHOLD" \
        '[.[] | select(.distance <= $thresh)] | .[].rowid' 2>/dev/null)

      if [[ -n "$filtered_ids" ]]; then
        local id_list
        id_list=$(echo "$filtered_ids" | paste -sd',' -)
        local entries_json
        entries_json=$(sql_json "$db" "SELECT id, content, created_at FROM entries WHERE id IN ($id_list);")

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
    local vec_count
    vec_count=$(echo "$vec_json" | jq 'length')

    # --- Dual-channel overlap ---
    local fts_ids vec_ids both_n=0
    fts_ids=$(echo "$fts_json" | jq -r '.[].id' | sort -n)
    vec_ids=$(echo "$vec_json" | jq -r '.[].id' | sort -n)
    if [[ -n "$fts_ids" && -n "$vec_ids" ]]; then
      both_n=$(comm -12 <(echo "$fts_ids") <(echo "$vec_ids") | grep -c . || true)
    fi

    # --- RRF ---
    local rrf_json
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

    # --- Union merge ---
    local union_json
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

      combined.sort_by! { |e| e["created_at"] || "" }.reverse!
      puts JSON.generate(combined.first(10))
    ' "$fts_json" "$vec_json")

    # --- Precision ---
    local union_relevant=0 rrf_relevant=0

    for row in $(echo "$union_json" | jq -r '.[].id'); do
      local c
      c=$(entry_cluster "$row" "$cluster_map")
      local rel
      rel=$(is_relevant "${c:-}" "$clusters")
      union_relevant=$((union_relevant + rel))
    done

    for row in $(echo "$rrf_json" | jq -r '.[].id'); do
      local c
      c=$(entry_cluster "$row" "$cluster_map")
      local rel
      rel=$(is_relevant "${c:-}" "$clusters")
      rrf_relevant=$((rrf_relevant + rel))
    done

    # --- Count dual-channel entries in RRF top 10 ---
    local rrf_both
    rrf_both=$(echo "$rrf_json" | jq '[.[] | select(.channels == "fts+vec")] | length')

    printf "      FTS: %s  Vec: %s  Both: %s  Union: %s/10  RRF: %s/10  RRF-both-in-top10: %s\n" \
      "$fts_count" "$vec_count" "$both_n" "$union_relevant" "$rrf_relevant" "$rrf_both" >&2

    # Store per-query data
    query_data+="${qid}\t${qtype}\t${clusters}\t${fts_count}\t${vec_count}\t${both_n}\t${union_relevant}\t${rrf_relevant}\t${rrf_both}\n"

    # Write per-query TSV files
    {
      printf "rank\tentry_id\tcluster\tscore\tchannels\tcontent\n"
      echo "$rrf_json" | jq -c '.[]' | {
        rank=0
        while read -r row; do
          rank=$((rank + 1))
          local eid score ch content cluster
          eid=$(echo "$row" | jq -r '.id')
          score=$(echo "$row" | jq -r '.rrf_score')
          ch=$(echo "$row" | jq -r '.channels')
          content=$(echo "$row" | jq -r '.content')
          cluster=$(entry_cluster "$eid" "$cluster_map")
          printf "%d\t%s\t%s\t%s\t%s\t%s\n" "$rank" "$eid" "${cluster:-?}" "$score" "$ch" "$(truncate_content "$content")"
        done
      }
    } > "$scale_dir/${qid}-rrf.tsv"

  done < <(load_queries)

  # Write scale summary
  printf "%b" "$query_data" > "$scale_dir/query-data.tsv"

  # Cleanup
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Cross-scale analysis
# ---------------------------------------------------------------------------

cross_scale_analysis() {
  printf "\n\033[1m========================================\033[0m\n"
  printf "\033[1m  Cross-Scale Analysis\033[0m\n"
  printf "\033[1m========================================\033[0m\n\n"

  {
    printf "# RRF Scale Experiment — Cross-Scale Comparison\n\n"
    printf "Date: %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
    printf "Distance threshold: %s\n" "$VECTOR_DISTANCE_THRESHOLD"
    printf "RRF k: %d\n" "$RRF_K"
    printf "Scales: %s\n\n" "${SCALES[*]}"

    # --- Per-scale summary ---
    printf "## Per-Scale Summary\n\n"
    printf "| Scale | Direct Union P@10 | Direct RRF P@10 | Delta | Mean Both (top20) | Mean Both (RRF top10) |\n"
    printf "|-------|-------------------|-----------------|-------|-------------------|-----------------------|\n"

    for scale in "${SCALES[@]}"; do
      local data_file="$RESULTS/scale-${scale}/query-data.tsv"
      if [[ ! -f "$data_file" ]]; then
        printf "| %s | — | — | — | — | — |\n" "$scale"
        continue
      fi

      # Parse: qid type clusters fts_count vec_count both_n union_rel rrf_rel rrf_both
      local direct_union=0 direct_rrf=0 direct_count=0
      local total_both=0 total_rrf_both=0

      while IFS=$'\t' read -r qid qtype clusters fts_count vec_count both_n union_rel rrf_rel rrf_both; do
        [[ -z "$qid" ]] && continue
        if [[ "$qtype" == "single" ]]; then
          direct_count=$((direct_count + 1))
          direct_union=$((direct_union + union_rel))
          direct_rrf=$((direct_rrf + rrf_rel))
          total_both=$((total_both + both_n))
          total_rrf_both=$((total_rrf_both + rrf_both))
        fi
      done < "$data_file"

      if [[ "$direct_count" -gt 0 ]]; then
        local mean_union mean_rrf mean_delta mean_both mean_rrf_both
        mean_union=$(ruby -e "printf '%.2f', ${direct_union}.to_f / ${direct_count}")
        mean_rrf=$(ruby -e "printf '%.2f', ${direct_rrf}.to_f / ${direct_count}")
        mean_delta=$(ruby -e "printf '%+.2f', (${direct_rrf}.to_f - ${direct_union}.to_f) / ${direct_count}")
        mean_both=$(ruby -e "printf '%.1f', ${total_both}.to_f / ${direct_count}")
        mean_rrf_both=$(ruby -e "printf '%.1f', ${total_rrf_both}.to_f / ${direct_count}")
        printf "| %s | %s/10 | %s/10 | %s | %s | %s |\n" \
          "$scale" "$mean_union" "$mean_rrf" "$mean_delta" "$mean_both" "$mean_rrf_both"
      fi
    done

    # --- Per-query detail across scales ---
    printf "\n## Per-Query Detail (Direct Vocabulary Q01-Q10)\n\n"
    printf "| Query |"
    for scale in "${SCALES[@]}"; do
      printf " Both@%s |" "$scale"
    done
    for scale in "${SCALES[@]}"; do
      printf " RRF@%s |" "$scale"
    done
    for scale in "${SCALES[@]}"; do
      printf " Union@%s |" "$scale"
    done
    printf "\n|-------|"
    for scale in "${SCALES[@]}"; do printf "--------|"; done
    for scale in "${SCALES[@]}"; do printf "--------|"; done
    for scale in "${SCALES[@]}"; do printf "---------|"; done
    printf "\n"

    # Collect per-query data across scales
    while IFS=$'\t' read -r qid qtype clusters query_text; do
      [[ "$qtype" != "single" ]] && continue
      printf "| %s |" "$qid"

      # Both counts
      for scale in "${SCALES[@]}"; do
        local data_file="$RESULTS/scale-${scale}/query-data.tsv"
        if [[ -f "$data_file" ]]; then
          local both_n
          both_n=$(grep "^${qid}	" "$data_file" | cut -f6)
          printf " %s |" "${both_n:-—}"
        else
          printf " — |"
        fi
      done

      # RRF precision
      for scale in "${SCALES[@]}"; do
        local data_file="$RESULTS/scale-${scale}/query-data.tsv"
        if [[ -f "$data_file" ]]; then
          local rrf_rel
          rrf_rel=$(grep "^${qid}	" "$data_file" | cut -f8)
          printf " %s/10 |" "${rrf_rel:-—}"
        else
          printf " — |"
        fi
      done

      # Union precision
      for scale in "${SCALES[@]}"; do
        local data_file="$RESULTS/scale-${scale}/query-data.tsv"
        if [[ -f "$data_file" ]]; then
          local union_rel
          union_rel=$(grep "^${qid}	" "$data_file" | cut -f7)
          printf " %s/10 |" "${union_rel:-—}"
        else
          printf " — |"
        fi
      done

      printf "\n"
    done < <(load_queries)

    # --- Paraphrase queries ---
    printf "\n## Paraphrase Queries (Q11-Q15)\n\n"
    printf "| Scale | Mean Union P@10 | Mean RRF P@10 | Mean Both |\n"
    printf "|-------|-----------------|---------------|----------|\n"

    for scale in "${SCALES[@]}"; do
      local data_file="$RESULTS/scale-${scale}/query-data.tsv"
      if [[ ! -f "$data_file" ]]; then continue; fi

      local p_union=0 p_rrf=0 p_both=0 p_count=0
      while IFS=$'\t' read -r qid qtype clusters fts_count vec_count both_n union_rel rrf_rel rrf_both; do
        [[ "$qtype" != "paraphrase" ]] && continue
        p_count=$((p_count + 1))
        p_union=$((p_union + union_rel))
        p_rrf=$((p_rrf + rrf_rel))
        p_both=$((p_both + both_n))
      done < "$data_file"

      if [[ "$p_count" -gt 0 ]]; then
        local m_u m_r m_b
        m_u=$(ruby -e "printf '%.2f', ${p_union}.to_f / ${p_count}")
        m_r=$(ruby -e "printf '%.2f', ${p_rrf}.to_f / ${p_count}")
        m_b=$(ruby -e "printf '%.1f', ${p_both}.to_f / ${p_count}")
        printf "| %s | %s/10 | %s/10 | %s |\n" "$scale" "$m_u" "$m_r" "$m_b"
      fi
    done

  } | tee "$RESULTS/summary.md"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf "\033[1m=== RRF Scale Experiment ===\033[0m\n"
printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
printf "Distance threshold: %s\n" "$VECTOR_DISTANCE_THRESHOLD"
printf "RRF k: %d\n" "$RRF_K"
printf "Scales: %s\n" "${SCALES[*]}"
printf "Background entry cache: %s\n\n" "$ENTRY_CACHE"

STARTED_AT=$(date +%s)

for scale in "${SCALES[@]}"; do
  scale_start=$(date +%s)
  run_scale "$scale"
  scale_end=$(date +%s)
  elapsed=$((scale_end - scale_start))
  printf "\n  Scale %s completed in %dm %ds\n" "$scale" "$((elapsed/60))" "$((elapsed%60))"
done

# Cross-scale analysis
cross_scale_analysis

ENDED_AT=$(date +%s)
ELAPSED=$((ENDED_AT - STARTED_AT))
printf "\n\033[1mExperiment complete (%dm %ds)\033[0m\n" "$((ELAPSED/60))" "$((ELAPSED%60))"
printf "Results in %s/\n" "$RESULTS"
