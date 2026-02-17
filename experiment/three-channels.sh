#!/usr/bin/env bash

# three-channels.sh — experiment proving crib's three retrieval channels
# are each necessary, not redundant.
#
# Seeds 10 memory entries into a fresh crib database, then runs 13 queries
# through each channel in isolation (CRIB_CHANNEL=triples|fts|vector) and
# through the union (unset). Prints a summary table.
#
# Usage:
#   experiment/three-channels.sh
#
# Dependencies: crib (with CRIB_CHANNEL support), ollama, sqlite3, sqlite-vec
#
# Output:
#   results/    — per-query output files
#   results/triples.json — actual extracted triples
#   summary table on stdout

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRIB_DIR="$(cd "$SCRIPT_DIR/../../crib" && pwd)"
CRIB="$CRIB_DIR/bin/crib"

if [[ ! -x "$CRIB" ]]; then
  echo "error: crib not found at $CRIB" >&2
  exit 1
fi

# Temporary database
TMPDIR_BASE=$(mktemp -d)
export CRIB_DB="$TMPDIR_BASE/experiment.db"

# Results directory
RESULTS="$SCRIPT_DIR/results"
rm -rf "$RESULTS"
mkdir -p "$RESULTS"

cleanup() {
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

printf "\033[1m=== Three channels, one query — experiment ===\033[0m\n\n"

# ---------------------------------------------------------------------------
# Phase 1: Seed 10 memory entries
# ---------------------------------------------------------------------------

printf "\033[1mSeeding entries...\033[0m\n"

entries=(
  'type=decision Switched spill from per-tool log files to a single SQLite database. Centralized logging means one place to query when debugging cross-tool failures at 3 AM.'
  'type=note hooker evaluates policies in priority order: gates first, then transforms, then injects. A gate halt stops the chain. Transforms and injects both fire on the same event.'
  "type=error book dispatcher crashed when a task payload contained a single quote. The SQL interpolation in store_result did not escape it. Fixed by running gsub(\"'\", \"''\") on all user-supplied strings before interpolation."
  'type=correction Previously believed screen needed separate prompt templates per classifier. Wrong. One shared template with condition and input XML tags handles all three classifiers. The tuning target is the condition wording, not the template structure.'
  'type=decision prophet does not vendor its dependencies. Each tool — hooker, crib, screen, trick, spill, book — lives in its own repo as a sibling directory. prophet discovers them at runtime via relative paths.'
  'type=note nomic-embed-text produces 768-dimensional float vectors. At the default ollama settings, embedding a single sentence takes 50-80ms on M-series Apple Silicon. Batch embedding via the /api/embed endpoint accepts an array and is 3x faster than individual calls.'
  'type=error trick extracted 14 memories from a single transcript but 9 were trivial operational details like "edited file X" and "ran test suite." The extraction prompt needed stronger filtering language. Changed to: "Do not extract trivial operational details (file edits, command outputs, routine code changes)."'
  'type=decision crib uses consolidation-on-write rather than periodic garbage collection. When a new triple contradicts an existing one, the old relation gets valid_until set to now. No background jobs. No scheduled cleanup. The write path keeps the archive clean.'
  'type=note The gemma3:1b model says yes to anything technology-adjacent when given vague conditions. A meeting agenda mentioning "vendor API" classified as source code. Specificity in the condition wording is the only fix — the model cannot self-calibrate.'
  'type=decision core holds identity and voice standards in IDENTITY.md. Every repo references core as the canonical source. When the persona evolves, it evolves in one place. No copies. No drift.'
)

for i in "${!entries[@]}"; do
  n=$((i + 1))
  printf "  [%2d/10] " "$n"
  output=$(echo "${entries[$i]}" | "$CRIB" write 2>&1)
  if echo "$output" | grep -q "stored entry"; then
    triples=$(echo "$output" | sed -n 's/.*\([0-9][0-9]*\) triples.*/\1/p')
    printf "ok (%s triples)\n" "${triples:-0}"
  else
    printf "FAILED: %s\n" "$output"
  fi
done

# ---------------------------------------------------------------------------
# Phase 2: Inspect extracted triples
# ---------------------------------------------------------------------------

printf "\n\033[1mInspecting extracted triples...\033[0m\n"

SQLITE3="${CRIB_SQLITE3:-/opt/homebrew/opt/sqlite/bin/sqlite3}"
triples_json=$("$SQLITE3" -json "$CRIB_DB" "
  SELECT s.name AS subject, r.predicate, o.name AS object
  FROM relations r
  JOIN entities s ON r.subject_id = s.id
  JOIN entities o ON r.object_id = o.id
  WHERE r.valid_until IS NULL;
" 2>/dev/null)

echo "$triples_json" > "$RESULTS/triples.json"

entity_count=$("$SQLITE3" "$CRIB_DB" "SELECT COUNT(*) FROM entities;" 2>/dev/null)
relation_count=$("$SQLITE3" "$CRIB_DB" "SELECT COUNT(*) FROM relations WHERE valid_until IS NULL;" 2>/dev/null)
entry_count=$("$SQLITE3" "$CRIB_DB" "SELECT COUNT(*) FROM entries;" 2>/dev/null)

printf "  %s entries, %s entities, %s active relations\n" "$entry_count" "$entity_count" "$relation_count"
printf "  Triples saved to results/triples.json\n"

# ---------------------------------------------------------------------------
# Phase 3: Run queries
# ---------------------------------------------------------------------------

queries=(
  "A1|what logging backend does spill use?"
  "A2|what does prophet discover at runtime?"
  "A3|what architecture does prophet use for dependencies?"
  "B1|gsub escaping single quote"
  "B2|valid_until consolidation-on-write"
  "B3|porter stemming unicode61 tokenize"
  "B4|768 dimensional float vectors nomic"
  "C1|how do the tools find each other at startup?"
  "C2|what went wrong with the task queue crashing?"
  "C3|preventing the agent from remembering useless things"
  "C4|making sure the persona does not diverge across projects"
  "D1|how does the small model fail on classification?"
  "D2|every architectural decision we made about persistence"
)

channels=(triples fts vector union)

printf "\n\033[1mRunning %d queries × 4 channels...\033[0m\n" "${#queries[@]}"

for entry in "${queries[@]}"; do
  IFS='|' read -r qid query <<< "$entry"
  printf "  %s: %s\n" "$qid" "$query"

  for ch in "${channels[@]}"; do
    if [[ "$ch" == "union" ]]; then
      output=$(echo "$query" | "$CRIB" retrieve 2>/dev/null)
    else
      output=$(echo "$query" | CRIB_CHANNEL="$ch" "$CRIB" retrieve 2>/dev/null)
    fi
    echo "$output" > "$RESULTS/${qid}-${ch}.txt"
  done
done

# ---------------------------------------------------------------------------
# Phase 4: Summary table
# ---------------------------------------------------------------------------

printf "\n\033[1m=== Summary ===\033[0m\n\n"

# Determine if a result file has content (non-empty <memory> output)
has_result() {
  local file="$1"
  [[ -s "$file" ]] && grep -q '<memory' "$file"
}

# Print header
printf "%-4s  %-55s  %-8s  %-8s  %-8s  %-8s\n" "ID" "Query" "Triples" "FTS" "Vector" "Union"
printf "%-4s  %-55s  %-8s  %-8s  %-8s  %-8s\n" "----" "-------------------------------------------------------" "--------" "--------" "--------" "--------"

for entry in "${queries[@]}"; do
  IFS='|' read -r qid query <<< "$entry"

  # Truncate query for display
  display_q="${query:0:55}"

  t_result="—"
  f_result="—"
  v_result="—"
  u_result="—"

  has_result "$RESULTS/${qid}-triples.txt" && t_result="HIT"
  has_result "$RESULTS/${qid}-fts.txt" && f_result="HIT"
  has_result "$RESULTS/${qid}-vector.txt" && v_result="HIT"
  has_result "$RESULTS/${qid}-union.txt" && u_result="HIT"

  printf "%-4s  %-55s  %-8s  %-8s  %-8s  %-8s\n" "$qid" "$display_q" "$t_result" "$f_result" "$v_result" "$u_result"
done

printf "\n"

# Count channel-exclusive hits
triple_only=0
fts_only=0
vector_only=0

for entry in "${queries[@]}"; do
  IFS='|' read -r qid query <<< "$entry"
  t=0; f=0; v=0
  has_result "$RESULTS/${qid}-triples.txt" && t=1
  has_result "$RESULTS/${qid}-fts.txt" && f=1
  has_result "$RESULTS/${qid}-vector.txt" && v=1

  [[ $t -eq 1 && $f -eq 0 && $v -eq 0 ]] && ((triple_only++))
  [[ $t -eq 0 && $f -eq 1 && $v -eq 0 ]] && ((fts_only++))
  [[ $t -eq 0 && $f -eq 0 && $v -eq 1 ]] && ((vector_only++))
done

printf "Channel-exclusive hits: triples=%d  fts=%d  vector=%d\n" "$triple_only" "$fts_only" "$vector_only"
printf "Results saved to %s/\n" "$RESULTS"
