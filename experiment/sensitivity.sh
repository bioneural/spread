#!/usr/bin/env bash

# sensitivity.sh — test distance threshold stability across 5 orders of magnitude
#
# Measures cosine distance distributions at corpus sizes of 10, 100, 1000,
# 10000, and 100000 entries. The 120 base entries (from corpus.sh) provide
# ground truth; additional entries are generated via gemma3:1b to fill each
# scale. This bypasses crib and inserts directly into sqlite-vec for speed.
#
# Usage:
#   experiment/sensitivity.sh                    # run all 5 scales
#   experiment/sensitivity.sh --scales 10,100    # run specific scales
#
# Output:
#   results/sensitivity/distances-N.csv     (per-scale raw data)
#   results/sensitivity/analysis.txt        (cross-scale summary)
#
# Time estimates:
#   10, 100      — seconds
#   1,000        — ~10 minutes
#   10,000       — ~2 hours
#   100,000      — ~14 hours
#
# Dependencies: ollama (nomic-embed-text, gemma3:1b), sqlite3 (with sqlite-vec), jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SQLITE3="${CRIB_SQLITE3:-/opt/homebrew/opt/sqlite/bin/sqlite3}"
VEC_EXTENSION="${CRIB_VEC_EXTENSION:-$(python3 -c 'import sqlite_vec; print(sqlite_vec.loadable_path())' 2>/dev/null || echo 'vec0')}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
EMBEDDING_MODEL="${CRIB_EMBEDDING_MODEL:-nomic-embed-text}"
GENERATION_MODEL="${CRIB_GENERATION_MODEL:-gemma3:1b}"

GROUND_TRUTH="$SCRIPT_DIR/ground-truth.txt"
RESULTS="$SCRIPT_DIR/results/sensitivity"

# Default scales
SCALES=(10 100 1000 10000 100000)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scales) IFS=',' read -ra SCALES <<< "$2"; shift 2 ;;
    *) echo "error: unknown flag $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$RESULTS"

# ---------------------------------------------------------------------------
# 200 diverse topics for background entry generation
# ---------------------------------------------------------------------------

TOPICS=(
  "quantum mechanics and particle physics"
  "organic chemistry reactions and synthesis"
  "cellular biology and mitosis"
  "stellar evolution and supernovae"
  "plate tectonics and earthquake mechanics"
  "marine ecology and coral reef systems"
  "tropical meteorology and hurricane formation"
  "deep ocean exploration and hydrothermal vents"
  "human genetics and DNA sequencing methods"
  "cognitive neuroscience and brain imaging"
  "materials science and polymer engineering"
  "thermodynamics and heat transfer"
  "microbiology and bacterial resistance"
  "paleontology and dinosaur fossil dating"
  "volcanology and magma chamber dynamics"
  "botany and plant hormone signaling"
  "animal behavior and migration ethology"
  "nuclear physics and radioactive decay"
  "fluid dynamics and turbulence modeling"
  "electromagnetic wave propagation and optics"
  "cardiology and coronary bypass surgery"
  "dermatology and autoimmune skin conditions"
  "oncology and immunotherapy cancer treatment"
  "pediatric developmental milestones"
  "orthopedic joint replacement procedures"
  "pharmacology and drug metabolism pathways"
  "epidemiology and infectious disease modeling"
  "immunology and vaccine development"
  "psychiatric medication management"
  "emergency trauma response protocols"
  "bridge and dam structural engineering"
  "aerospace rocket propulsion design"
  "chemical plant safety operations"
  "biomedical prosthetic device design"
  "environmental soil remediation"
  "nuclear reactor coolant systems"
  "industrial robotic assembly lines"
  "electrical power grid load balancing"
  "internal combustion engine thermodynamics"
  "municipal water treatment processes"
  "ancient Greek philosophical schools"
  "medieval European feudal governance"
  "Victorian novel narrative techniques"
  "Indo-European language family evolution"
  "Pacific Island cultural anthropology"
  "Mesoamerican archaeological excavations"
  "Buddhist and Hindu comparative theology"
  "Italian Renaissance painting techniques"
  "ancient Latin grammatical structures"
  "trolley problem and utilitarian ethics"
  "macroeconomic monetary policy tools"
  "childhood developmental psychology stages"
  "urban gentrification sociology"
  "parliamentary versus presidential systems"
  "glacial landform geomorphology"
  "global population demographic transitions"
  "forensic evidence collection procedures"
  "Montessori educational pedagogy"
  "United Nations peacekeeping operations"
  "behavioral economics and prospect theory"
  "oil painting layering and glazing techniques"
  "marble sculpture carving methodology"
  "jazz improvisation and modal theory"
  "theatrical lighting and stage design"
  "classical ballet positions and movements"
  "long exposure landscape photography"
  "documentary film interview techniques"
  "Gothic cathedral flying buttress design"
  "Navajo textile weaving traditions"
  "Japanese raku ceramic firing"
  "French pastry lamination techniques"
  "raised bed vegetable garden planning"
  "residential plumbing repair methods"
  "motorcycle chain maintenance procedures"
  "powerlifting progressive overload programs"
  "Mediterranean diet meal planning"
  "newborn sleep training approaches"
  "positive reinforcement dog training"
  "traditional hand quilting patterns"
  "mortise and tenon joinery woodworking"
  "baseball curveball pitching physics"
  "4-3-3 soccer tactical formations"
  "tennis topspin serve biomechanics"
  "competitive freestyle swimming technique"
  "artistic gymnastics scoring deductions"
  "ice hockey power play strategies"
  "rugby lineout lifting mechanics"
  "golf driver swing plane analysis"
  "Tour de France peloton drafting tactics"
  "Brazilian jiu-jitsu submission techniques"
  "temperate deciduous forest ecosystems"
  "Arctic sea ice extent monitoring"
  "Sonoran desert plant adaptations"
  "Himalayan mountaineering route planning"
  "Mississippi river delta sedimentation"
  "Arctic tern migration tracking"
  "supercell tornado genesis conditions"
  "thermohaline ocean circulation patterns"
  "autumn leaf color change biochemistry"
  "African savanna predator-prey dynamics"
  "5G millimeter wave antenna deployment"
  "Bessemer steel manufacturing processes"
  "container ship port logistics operations"
  "precision GPS-guided agriculture"
  "underground coal mining safety systems"
  "lithographic printing press technology"
  "synthetic nylon fiber production"
  "industrial food freeze-drying methods"
  "GPS satellite orbital mechanics"
  "lithium-ion battery storage chemistry"
  "corporate tax accounting standards"
  "social media marketing attribution"
  "just-in-time supply chain management"
  "commercial real estate cap rate analysis"
  "actuarial life insurance risk modeling"
  "central bank interest rate mechanisms"
  "McKinsey 7S consulting framework"
  "retail point-of-sale inventory tracking"
  "hotel revenue yield management"
  "intermodal freight routing optimization"
  "Roman Republic governance structures"
  "spinning jenny Industrial Revolution impact"
  "World War I Verdun trench warfare"
  "Cuban Missile Crisis Cold War diplomacy"
  "ancient Egyptian pyramid construction"
  "Silk Road caravanserai trade networks"
  "French Revolution Reign of Terror"
  "Gettysburg American Civil War battle"
  "Ming Dynasty porcelain craftsmanship"
  "Viking longship North Atlantic voyages"
  "Himalayan tectonic collision geology"
  "Amazon rainforest canopy biodiversity"
  "Sahara Desert sand dune formation"
  "Pacific Ring of Fire volcanic activity"
  "Great Barrier Reef bleaching events"
  "Antarctic ice core climate records"
  "Nile River seasonal flood irrigation"
  "Mediterranean scrubland fire ecology"
  "Appalachian folded mountain geology"
  "Caribbean volcanic island arc formation"
  "Burgundy wine terroir and viticulture"
  "Parmigiano-Reggiano cheese aging caves"
  "cover crop sustainable farming rotations"
  "Ethiopian coffee bean processing methods"
  "Langstroth hive beekeeping management"
  "Japanese rice paddy water management"
  "regenerative cattle grazing systems"
  "Spanish olive oil cold press extraction"
  "bean-to-bar chocolate tempering process"
  "Korean kimchi fermentation techniques"
  "symphony orchestra seating arrangement"
  "Mississippi Delta blues guitar origins"
  "analog synthesizer sound design"
  "Wagnerian opera vocal projection"
  "Abbey Road rock album recording techniques"
  "Appalachian folk banjo picking styles"
  "counterpoint and fugue music theory"
  "Steinway concert piano action mechanism"
  "West African djembe drumming traditions"
  "Renaissance choral polyphony harmonics"
  "deep sea tuna longline fishing"
  "hot air balloon envelope inflation"
  "diamond faceting and gemstone cutting"
  "Fresnel lens lighthouse optics history"
  "Coptic bookbinding stitch patterns"
  "Grasse perfume essential oil distillation"
  "Swiss mechanical watch escapement design"
  "modular origami polyhedron construction"
  "Arabic naskh calligraphy stroke order"
  "Tiffany stained glass copper foil method"
  "beehive colony collapse disorder research"
  "avalanche prediction snow crystal analysis"
  "coral reef artificial structure restoration"
  "urban rooftop rainwater harvesting systems"
  "heritage grain sourdough fermentation"
  "vintage vinyl record pressing processes"
  "bonsai tree shaping and pruning methods"
  "astronomical telescope mirror grinding"
  "handmade paper mulberry fiber processing"
  "traditional Japanese indigo dyeing"
)

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

embed_text() {
  local text="$1"
  curl -s "$OLLAMA_HOST/api/embed" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$EMBEDDING_MODEL" --arg input "$text" \
      '{model: $model, input: $input}')" \
    | jq -c '.embeddings[0]'
}

# Embed a batch of texts. Input: JSON array of strings. Output: JSON array of embeddings.
embed_batch() {
  local texts_json="$1"
  curl -s "$OLLAMA_HOST/api/embed" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$EMBEDDING_MODEL" --argjson input "$texts_json" \
      '{model: $model, input: $input}')" \
    | jq -c '.embeddings'
}

# Generate diverse entries on a topic. Output: one entry per line.
generate_entries() {
  local topic="$1"
  local count="$2"
  curl -s "$OLLAMA_HOST/api/generate" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$GENERATION_MODEL" \
      --arg prompt "Generate exactly $count short factual notes (1-2 sentences each) about different aspects of $topic. One note per line. No numbering. No blank lines. No introductory text. Start immediately with the first note." \
      '{model: $model, prompt: $prompt, stream: false}')" \
    | jq -r '.response' | grep -v '^$' | head -n "$count"
}

# Create a fresh database with schema
create_db() {
  local db="$1"
  "$SQLITE3" "$db" "
    CREATE TABLE entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content TEXT NOT NULL,
      cluster_id INTEGER NOT NULL
    );
  "
  sql_vec "$db" "
    CREATE VIRTUAL TABLE entries_vec USING vec0(
      embedding float[768] distance_metric=cosine
    );
  "
}

# Batch insert entries + embeddings. Inputs: db, cluster_id, texts (newline-separated), embeddings (JSON array).
# Writes cluster map entries. Prints count of inserted entries.
batch_insert() {
  local db="$1" cluster_id="$2" texts="$3" embeddings_json="$4" cluster_map="$5"
  local sql_file
  sql_file=$(mktemp)

  # Batch insert into entries table via temp file
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

  # Get the IDs that were just inserted (last N rows)
  local ids
  ids=$("$SQLITE3" "$db" "SELECT id FROM entries ORDER BY id DESC LIMIT ${i};" | sort -n)

  # Build vec insert SQL via temp file (too large for command-line arg)
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

# Load base entries from corpus.sh heredoc
load_base_entries() {
  sed -n "/^corpus_entries()/,/^ENTRIES$/p" "$SCRIPT_DIR/corpus.sh" \
    | sed '1,2d;$d'
}

# Load queries from ground truth
load_queries() {
  grep -v '^#' "$GROUND_TRUTH" | grep -v '^$'
}

# ---------------------------------------------------------------------------
# Seed base entries for a given scale (batch embedded)
# ---------------------------------------------------------------------------

seed_base_entries() {
  local db="$1" scale="$2" cluster_map="$3"

  local entries_per_cluster
  if [[ "$scale" -le 10 ]]; then
    entries_per_cluster=1
  else
    entries_per_cluster=999
  fi

  declare -A cluster_count
  declare -A cluster_texts  # cluster_id -> newline-separated texts

  # Collect entries by cluster
  while IFS='|' read -r cluster_id entry_text; do
    [[ -z "$cluster_id" ]] && continue
    if [[ "$scale" -le 100 && "$cluster_id" -eq 0 ]]; then
      continue
    fi
    local count=${cluster_count[$cluster_id]:-0}
    if [[ "$count" -ge "$entries_per_cluster" ]]; then
      continue
    fi
    cluster_count[$cluster_id]=$((count + 1))

    if [[ -n "${cluster_texts[$cluster_id]:-}" ]]; then
      cluster_texts[$cluster_id]+=$'\n'"$entry_text"
    else
      cluster_texts[$cluster_id]="$entry_text"
    fi
  done < <(load_base_entries)

  # Batch embed and insert per cluster
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
    printf "    base: %d entries (cluster %s done)\r" "$total" "$cid" >&2
  done

  printf "    base: %d entries embedded\n" "$total" >&2
  echo "$total"
}

# ---------------------------------------------------------------------------
# Generate and seed background entries (cached to disk for reuse)
# ---------------------------------------------------------------------------

ENTRY_CACHE="$RESULTS/background-entries.txt"

# Ensure the cache has at least N entries. Generate more if needed.
ensure_cached_entries() {
  local needed="$1"
  local have=0
  if [[ -f "$ENTRY_CACHE" ]]; then
    have=$(wc -l < "$ENTRY_CACHE" | tr -d ' ')
  fi

  if [[ "$have" -ge "$needed" ]]; then
    printf "    cache has %d entries (need %d), skipping generation\n" "$have" "$needed" >&2
    return
  fi

  local to_generate=$((needed - have))
  printf "    cache has %d entries, generating %d more...\n" "$have" "$to_generate" >&2

  local entries_per_topic=20
  local total=0
  local topic_idx=$((have / entries_per_topic))  # resume from where we left off
  local num_topics=${#TOPICS[@]}
  local gen_start=$(date +%s)

  while [[ "$total" -lt "$to_generate" ]]; do
    local topic="${TOPICS[$((topic_idx % num_topics))]}"
    topic_idx=$((topic_idx + 1))

    local remaining=$((to_generate - total))
    local batch_size=$entries_per_topic
    if [[ "$remaining" -lt "$batch_size" ]]; then
      batch_size=$remaining
    fi

    local batch_texts
    batch_texts=$(generate_entries "$topic" "$batch_size")
    if [[ -z "$batch_texts" ]]; then
      continue
    fi

    # Filter short lines and append to cache
    echo "$batch_texts" | while IFS= read -r line; do
      [[ ${#line} -ge 10 ]] && echo "$line"
    done >> "$ENTRY_CACHE"

    local added
    added=$(echo "$batch_texts" | awk 'length >= 10' | wc -l | tr -d ' ')
    total=$((total + added))

    local pct=$((total * 100 / to_generate))
    local elapsed=$(($(date +%s) - gen_start))
    local rate=0
    if [[ "$elapsed" -gt 0 ]]; then
      rate=$((total * 10 / elapsed))
    fi
    printf "    generating: %d/%d (%d%%) — %d.%d entries/sec\r" \
      "$total" "$to_generate" "$pct" "$((rate/10))" "$((rate%10))" >&2

    if [[ "$topic_idx" -ge "$num_topics" && "$total" -lt "$to_generate" ]]; then
      entries_per_topic=$((entries_per_topic + 5))
    fi
  done

  printf "    generating: done (%d new entries cached)\n" "$total" >&2
}

seed_background_entries() {
  local db="$1" target_count="$2" cluster_map="$3"

  # Ensure cache has enough entries
  ensure_cached_entries "$target_count"

  # Read entries from cache, embed, and insert in batches
  local total=0
  local batch_size=20
  local batch_texts=""
  local batch_count=0

  printf "    embedding and inserting %d background entries...\n" "$target_count" >&2

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ -n "$batch_texts" ]]; then
      batch_texts+=$'\n'"$line"
    else
      batch_texts="$line"
    fi
    batch_count=$((batch_count + 1))

    if [[ "$batch_count" -ge "$batch_size" ]]; then
      # Batch embed
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
      local elapsed=$(($(date +%s) - scale_gen_start))
      local rate=0
      if [[ "$elapsed" -gt 0 ]]; then
        rate=$((total * 10 / elapsed))
      fi
      printf "    seeding: %d/%d (%d%%) — %d.%d entries/sec\r" \
        "$total" "$target_count" "$pct" "$((rate/10))" "$((rate%10))" >&2
    fi

    if [[ "$total" -ge "$target_count" ]]; then
      break
    fi
  done < <(head -n "$target_count" "$ENTRY_CACHE")

  # Flush remaining batch
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

  printf "    seeding: %d entries embedded and inserted\n" "$total" >&2
  echo "$total"
}

# ---------------------------------------------------------------------------
# Run distance measurement for one scale
# ---------------------------------------------------------------------------

run_scale() {
  local scale="$1"
  local tmpdir
  tmpdir=$(mktemp -d)
  local db="$tmpdir/sensitivity.db"
  local cluster_map="$tmpdir/cluster-map.txt"
  local csv="$RESULTS/distances-${scale}.csv"

  printf "\n\033[1m========================================\033[0m\n"
  printf "\033[1m  Scale %s\033[0m\n" "$scale"
  printf "\033[1m========================================\033[0m\n"

  # Create database
  create_db "$db"
  > "$cluster_map"

  # Seed base entries
  printf "\n  Seeding base entries...\n" >&2
  local base_count
  base_count=$(seed_base_entries "$db" "$scale" "$cluster_map")

  # Generate background entries if needed
  local bg_count=0
  if [[ "$scale" -gt "$base_count" ]]; then
    local needed=$((scale - base_count))
    printf "\n  Generating %d background entries...\n" "$needed" >&2
    scale_gen_start=$(date +%s)
    bg_count=$(seed_background_entries "$db" "$needed" "$cluster_map")
  fi

  local total=$((base_count + bg_count))
  printf "\n  Total entries: %d (base: %d, background: %d)\n" "$total" "$base_count" "$bg_count" >&2

  # Verify
  local db_count
  db_count=$("$SQLITE3" "$db" "SELECT COUNT(*) FROM entries;")
  printf "  Database entry count: %s\n" "$db_count" >&2

  # Write CSV header
  echo "query_id,entry_id,cosine_dist,relevant" > "$csv"

  # Run queries
  printf "\n  Running 20 queries against %s entries...\n" "$db_count" >&2

  local query_num=0
  while IFS=$'\t' read -r qid qtype clusters query_text; do
    query_num=$((query_num + 1))
    printf "    [%2d/20] %s: %s\n" "$query_num" "$qid" "$query_text" >&2

    # Embed query
    local query_vec
    query_vec=$(embed_text "$query_text")
    if [[ -z "$query_vec" || "$query_vec" == "null" ]]; then
      printf "      SKIPPED (embedding failed)\n" >&2
      continue
    fi

    local escaped_vec
    escaped_vec=$(printf '%s' "$query_vec" | sed "s/'/''/g")

    # Compute cosine distance to every entry
    local distance_results
    distance_results=$(sql_vec_json "$db" "
      SELECT
        e.rowid as entry_id,
        vec_distance_cosine(e.embedding, '${escaped_vec}') as cosine_dist
      FROM entries_vec e
      ORDER BY cosine_dist;
    " 2>/dev/null)

    if [[ -z "$distance_results" || "$distance_results" == "[]" ]]; then
      printf "      WARNING: no results\n" >&2
      continue
    fi

    # Write CSV rows
    echo "$distance_results" | jq -r --arg qid "$qid" --arg clusters "$clusters" '
      .[] | [
        $qid,
        .entry_id,
        .cosine_dist,
        0
      ] | @csv
    ' >> "$csv"

    # Mark relevant entries
    if [[ "$clusters" != "none" ]]; then
      IFS=',' read -ra rel_clusters <<< "$clusters"
      for rc in "${rel_clusters[@]}"; do
        # Find entry IDs for this cluster
        local rel_ids
        rel_ids=$(grep "	${rc}$" "$cluster_map" | cut -f1)
        for rid in $rel_ids; do
          # Update the CSV: replace ,0$ with ,1$ for matching entry_id
          sed -i '' "s/^\"*${qid}\"*,\"*${rid}\"*,\(.*\),0$/\"${qid}\",\"${rid}\",\1,1/" "$csv" 2>/dev/null || true
        done
      done
    fi

    printf "      %s distances recorded\n" "$(echo "$distance_results" | jq 'length')" >&2
  done < <(load_queries)

  # Analyze
  printf "\n" >&2
  analyze_scale "$csv" "$scale"

  # Cleanup
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

analyze_scale() {
  local csv="$1" scale="$2"

  local adb
  adb=$(mktemp /tmp/sensitivity-analysis-XXXXXX.db)

  "$SQLITE3" "$adb" <<SQL
CREATE TABLE d (query_id TEXT, entry_id INTEGER, cosine_dist REAL, relevant INTEGER);
.mode csv
.import ${csv} d
DELETE FROM d WHERE query_id = 'query_id';
SQL

  printf "  \033[1mScale %s — Cosine Distance Summary\033[0m\n" "$scale"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT
  CASE WHEN relevant = 1 THEN 'relevant' ELSE 'irrelevant' END as class,
  COUNT(*) as n,
  ROUND(MIN(cosine_dist), 4) as min,
  ROUND(AVG(cosine_dist), 4) as mean,
  ROUND(MAX(cosine_dist), 4) as max
FROM d
GROUP BY relevant
ORDER BY relevant DESC;
SQL

  printf "\n  Separation:\n"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT
  ROUND((SELECT MAX(cosine_dist) FROM d WHERE relevant = 1), 4) as max_relevant,
  ROUND((SELECT MIN(cosine_dist) FROM d WHERE relevant = 0), 4) as min_irrelevant,
  CASE
    WHEN (SELECT MAX(cosine_dist) FROM d WHERE relevant = 1) <
         (SELECT MIN(cosine_dist) FROM d WHERE relevant = 0)
    THEN 'clean'
    ELSE 'overlap'
  END as separation;
SQL

  printf "\n  Nearest irrelevant per negative query:\n"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT query_id, ROUND(MIN(cosine_dist), 4) as nearest_dist
FROM d
WHERE query_id IN ('Q16','Q17','Q18','Q19','Q20')
GROUP BY query_id
ORDER BY query_id;
SQL

  printf "\n  Threshold sweep (cosine):\n"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT * FROM (
  SELECT
    ROUND(threshold, 2) as threshold,
    SUM(CASE WHEN relevant=1 AND cosine_dist <= threshold THEN 1 ELSE 0 END) as true_pos,
    SUM(CASE WHEN relevant=0 AND cosine_dist <= threshold THEN 1 ELSE 0 END) as false_pos,
    SUM(CASE WHEN relevant=1 AND cosine_dist > threshold THEN 1 ELSE 0 END) as false_neg,
    ROUND(
      CAST(SUM(CASE WHEN relevant=1 AND cosine_dist <= threshold THEN 1 ELSE 0 END) AS REAL) /
      NULLIF(SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END), 0), 3
    ) as recall,
    ROUND(
      CAST(SUM(CASE WHEN relevant=1 AND cosine_dist <= threshold THEN 1 ELSE 0 END) AS REAL) /
      NULLIF(SUM(CASE WHEN cosine_dist <= threshold THEN 1 ELSE 0 END), 0), 3
    ) as precision
  FROM d, (SELECT 0.30 as threshold UNION SELECT 0.35 UNION SELECT 0.40 UNION SELECT 0.45
           UNION SELECT 0.50 UNION SELECT 0.55 UNION SELECT 0.60 UNION SELECT 0.65)
  GROUP BY threshold
);
SQL

  rm -f "$adb"
}

cross_scale_analysis() {
  printf "\n\033[1m========================================\033[0m\n"
  printf "\033[1m  Cross-Scale Analysis\033[0m\n"
  printf "\033[1m========================================\033[0m\n"

  local adb
  adb=$(mktemp /tmp/sensitivity-cross-XXXXXX.db)

  # Create a unified table with a scale column
  "$SQLITE3" "$adb" "CREATE TABLE d (scale INTEGER, query_id TEXT, entry_id INTEGER, cosine_dist REAL, relevant INTEGER);"

  for s in "${SCALES[@]}"; do
    local csv="$RESULTS/distances-${s}.csv"
    if [[ ! -f "$csv" ]]; then
      printf "  WARN: missing %s, skipping\n" "$csv" >&2
      continue
    fi
    "$SQLITE3" "$adb" <<SQL
CREATE TABLE IF NOT EXISTS tmp (query_id TEXT, entry_id INTEGER, cosine_dist REAL, relevant INTEGER);
.mode csv
.import ${csv} tmp
DELETE FROM tmp WHERE query_id = 'query_id';
INSERT INTO d SELECT ${s}, query_id, entry_id, cosine_dist, relevant FROM tmp;
DROP TABLE tmp;
SQL
  done

  printf "\n  Mean cosine distance by scale and relevance:\n"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT
  scale,
  CASE WHEN relevant = 1 THEN 'relevant' ELSE 'irrelevant' END as class,
  COUNT(*) as n,
  ROUND(MIN(cosine_dist), 4) as min,
  ROUND(AVG(cosine_dist), 4) as mean,
  ROUND(MAX(cosine_dist), 4) as max
FROM d
GROUP BY scale, relevant
ORDER BY scale, relevant DESC;
SQL

  printf "\n  Minimum irrelevant distance (nearest intruder) by scale:\n"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT
  scale,
  ROUND(MIN(cosine_dist), 4) as min_irrelevant_dist
FROM d
WHERE relevant = 0
GROUP BY scale
ORDER BY scale;
SQL

  printf "\n  Negative query nearest neighbor by scale:\n"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT
  scale,
  query_id,
  ROUND(MIN(cosine_dist), 4) as nearest_dist
FROM d
WHERE query_id IN ('Q16','Q17','Q18','Q19','Q20')
GROUP BY scale, query_id
ORDER BY scale, query_id;
SQL

  printf "\n  Recall at threshold 0.50 (cosine) by scale:\n"
  "$SQLITE3" -header -column "$adb" <<'SQL'
SELECT
  scale,
  SUM(CASE WHEN relevant=1 AND cosine_dist <= 0.50 THEN 1 ELSE 0 END) as true_pos,
  SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END) as total_relevant,
  ROUND(
    CAST(SUM(CASE WHEN relevant=1 AND cosine_dist <= 0.50 THEN 1 ELSE 0 END) AS REAL) /
    NULLIF(SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END), 0), 3
  ) as recall,
  SUM(CASE WHEN relevant=0 AND cosine_dist <= 0.50 THEN 1 ELSE 0 END) as false_pos,
  ROUND(
    CAST(SUM(CASE WHEN relevant=1 AND cosine_dist <= 0.50 THEN 1 ELSE 0 END) AS REAL) /
    NULLIF(SUM(CASE WHEN cosine_dist <= 0.50 THEN 1 ELSE 0 END), 0), 3
  ) as precision
FROM d
GROUP BY scale
ORDER BY scale;
SQL

  rm -f "$adb"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf "\033[1m=== Sensitivity Experiment ===\033[0m\n"
printf "Embedding model: %s\n" "$EMBEDDING_MODEL"
printf "Generation model: %s\n" "$GENERATION_MODEL"
printf "Scales: %s\n" "${SCALES[*]}"
printf "Topics pool: %d\n" "${#TOPICS[@]}"
printf "Results: %s\n\n" "$RESULTS"

STARTED_AT=$(date +%s)

for scale in "${SCALES[@]}"; do
  scale_start=$(date +%s)
  run_scale "$scale"
  scale_end=$(date +%s)
  elapsed=$((scale_end - scale_start))
  printf "\n  Scale %s completed in %dm %ds\n" "$scale" "$((elapsed/60))" "$((elapsed%60))"
done

# Cross-scale analysis
cross_scale_analysis 2>&1 | tee "$RESULTS/analysis.txt"

ENDED_AT=$(date +%s)
ELAPSED=$((ENDED_AT - STARTED_AT))
printf "\n\033[1mExperiment complete (%dm %ds)\033[0m\n" "$((ELAPSED/60))" "$((ELAPSED%60))"
printf "Results in %s/\n" "$RESULTS"
