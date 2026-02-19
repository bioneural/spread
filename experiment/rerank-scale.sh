#!/usr/bin/env bash

# rerank-scale.sh — test cross-encoder reranking at multiple corpus sizes
#
# Runs rerank.sh at each specified scale, then produces a cross-scale
# summary comparing RRF-only vs RRF+rerank precision at each corpus size.
#
# Hypothesis: reranking helps more at larger corpus sizes because RRF
# degrades as dual-channel overlap drops to zero, while the cross-encoder
# evaluates content directly and is not affected by channel agreement.
#
# Usage:
#   experiment/rerank-scale.sh                     # run scales 1, 5
#   experiment/rerank-scale.sh --scales 1,5,10     # run specific scales
#
# Output:
#   experiment/results/rerank/summary.md        — scale 1 results
#   experiment/results/rerank-s5/summary.md     — scale 5 results
#   experiment/results/rerank-s10/summary.md    — scale 10 results
#   experiment/results/rerank-scale/summary.md  — cross-scale comparison
#
# Dependencies: rerank.sh, corpus.sh, crib, ollama, sqlite3, jq, ruby

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RERANK_SCRIPT="$SCRIPT_DIR/rerank.sh"
GROUND_TRUTH="$SCRIPT_DIR/ground-truth.txt"
RESULTS="$SCRIPT_DIR/results/rerank-scale"

# Default scales
SCALES=(5)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scales) IFS=',' read -ra SCALES <<< "$2"; shift 2 ;;
    *) echo "error: unknown flag $1" >&2; exit 1 ;;
  esac
done

if [[ ! -x "$RERANK_SCRIPT" ]]; then
  echo "error: rerank.sh not found or not executable at $RERANK_SCRIPT" >&2
  exit 1
fi

mkdir -p "$RESULTS"

printf "\033[1m=== Reranking Scale Experiment ===\033[0m\n"
printf "Scales: %s\n" "${SCALES[*]}"
printf "Results: %s\n\n" "$RESULTS"

STARTED_AT=$(date +%s)

# ---------------------------------------------------------------------------
# Run rerank.sh at each scale
# ---------------------------------------------------------------------------

for scale in "${SCALES[@]}"; do
  scale_start=$(date +%s)
  printf "\n\033[1m========================================\033[0m\n"
  printf "\033[1m  Running rerank.sh --scale %s\033[0m\n" "$scale"
  printf "\033[1m========================================\033[0m\n\n"

  "$RERANK_SCRIPT" --scale "$scale"

  scale_end=$(date +%s)
  elapsed=$((scale_end - scale_start))
  printf "\n  Scale %s completed in %dm %ds\n" "$scale" "$((elapsed/60))" "$((elapsed%60))"
done

# ---------------------------------------------------------------------------
# Cross-scale summary
# ---------------------------------------------------------------------------

printf "\n\033[1m========================================\033[0m\n"
printf "\033[1m  Cross-Scale Summary\033[0m\n"
printf "\033[1m========================================\033[0m\n\n"

# Helpers
load_queries() {
  grep -v '^#' "$GROUND_TRUTH" | grep -v '^$'
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

results_dir_for_scale() {
  local s="$1"
  if [[ "$s" -eq 1 ]]; then
    echo "$SCRIPT_DIR/results/rerank"
  else
    echo "$SCRIPT_DIR/results/rerank-s${s}"
  fi
}

# Collect precision data for each scale
{
  printf "# Cross-Encoder Reranking — Scale Experiment Results\n\n"
  printf "Date: %s\n\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Include scale 1 baseline if it exists
  all_scales=()
  if [[ -d "$SCRIPT_DIR/results/rerank" && -f "$SCRIPT_DIR/results/rerank/summary.md" ]]; then
    # Only include scale 1 if it wasn't in the SCALES list
    has_scale_1=false
    for s in "${SCALES[@]}"; do
      [[ "$s" -eq 1 ]] && has_scale_1=true
    done
    if ! $has_scale_1; then
      all_scales+=(1)
    fi
  fi
  all_scales+=("${SCALES[@]}")

  # Sort scales
  IFS=$'\n' all_scales=($(sort -n <<< "${all_scales[*]}")); unset IFS

  printf "Scales tested: %s\n\n" "${all_scales[*]}"

  # --- Per-scale detail tables ---
  for scale in "${all_scales[@]}"; do
    rdir=$(results_dir_for_scale "$scale")
    if [[ ! -d "$rdir" ]]; then
      printf "## Scale %s: MISSING\n\n" "$scale"
      continue
    fi

    # Read corpus size from summary.md
    corpus_size=$(grep '^Corpus:' "$rdir/summary.md" | sed 's/Corpus: //' | sed 's/ entries//')

    printf "## Scale %s (%s entries)\n\n" "$scale" "$corpus_size"
    printf "| Query | Type | RRF P@10 | Reranked P@10 | Delta |\n"
    printf "|-------|------|----------|---------------|-------|\n"

    while IFS=$'\t' read -r qid qtype clusters query_text; do
      [[ "$qtype" == "negative" ]] && continue

      # RRF precision@10
      rrf_relevant=0
      if [[ -f "$rdir/${qid}-rrf.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rrf_relevant=$((rrf_relevant + rel))
        done < "$rdir/${qid}-rrf.tsv"
      fi

      # Reranked precision@10
      rerank_relevant=0
      if [[ -f "$rdir/${qid}-rerank.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rscore rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rerank_relevant=$((rerank_relevant + rel))
        done < "$rdir/${qid}-rerank.tsv"
      fi

      delta=$((rerank_relevant - rrf_relevant))
      delta_str="0"
      [[ $delta -gt 0 ]] && delta_str="+${delta}"
      [[ $delta -lt 0 ]] && delta_str="$delta"

      printf "| %s | %s | %s/10 | %s/10 | %s |\n" \
        "$qid" "$qtype" "$rrf_relevant" "$rerank_relevant" "$delta_str"
    done < <(load_queries)
    printf "\n"
  done

  # --- Aggregate cross-scale table ---
  printf "## Aggregate: Cross-Scale Comparison\n\n"
  printf "| Scale | Entries | Query Type | N | Mean RRF P@10 | Mean Reranked P@10 | Mean Delta |\n"
  printf "|-------|---------|------------|---|---------------|--------------------|-----------|\n"

  for scale in "${all_scales[@]}"; do
    rdir=$(results_dir_for_scale "$scale")
    [[ ! -d "$rdir" ]] && continue

    corpus_size=$(grep '^Corpus:' "$rdir/summary.md" | sed 's/Corpus: //' | sed 's/ entries//')

    # Direct queries
    direct_rrf=0 direct_rerank=0 direct_count=0
    while IFS=$'\t' read -r qid qtype clusters query_text; do
      [[ "$qtype" != "single" ]] && continue
      direct_count=$((direct_count + 1))

      rrf_rel=0
      if [[ -f "$rdir/${qid}-rrf.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rrf_rel=$((rrf_rel + rel))
        done < "$rdir/${qid}-rrf.tsv"
      fi

      rerank_rel=0
      if [[ -f "$rdir/${qid}-rerank.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rscore rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rerank_rel=$((rerank_rel + rel))
        done < "$rdir/${qid}-rerank.tsv"
      fi

      direct_rrf=$((direct_rrf + rrf_rel))
      direct_rerank=$((direct_rerank + rerank_rel))
    done < <(load_queries)

    if [[ $direct_count -gt 0 ]]; then
      mean_rrf=$(ruby -e "printf '%.2f', ${direct_rrf}.to_f / ${direct_count}")
      mean_rerank=$(ruby -e "printf '%.2f', ${direct_rerank}.to_f / ${direct_count}")
      mean_delta=$(ruby -e "printf '%+.2f', (${direct_rerank}.to_f - ${direct_rrf}.to_f) / ${direct_count}")
      printf "| %s | %s | Direct | %d | %s/10 | %s/10 | %s |\n" \
        "$scale" "$corpus_size" "$direct_count" "$mean_rrf" "$mean_rerank" "$mean_delta"
    fi

    # Paraphrase queries
    para_rrf=0 para_rerank=0 para_count=0
    while IFS=$'\t' read -r qid qtype clusters query_text; do
      [[ "$qtype" != "paraphrase" ]] && continue
      para_count=$((para_count + 1))

      rrf_rel=0
      if [[ -f "$rdir/${qid}-rrf.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rrf_rel=$((rrf_rel + rel))
        done < "$rdir/${qid}-rrf.tsv"
      fi

      rerank_rel=0
      if [[ -f "$rdir/${qid}-rerank.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rscore rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rerank_rel=$((rerank_rel + rel))
        done < "$rdir/${qid}-rerank.tsv"
      fi

      para_rrf=$((para_rrf + rrf_rel))
      para_rerank=$((para_rerank + rerank_rel))
    done < <(load_queries)

    if [[ $para_count -gt 0 ]]; then
      mean_rrf=$(ruby -e "printf '%.2f', ${para_rrf}.to_f / ${para_count}")
      mean_rerank=$(ruby -e "printf '%.2f', ${para_rerank}.to_f / ${para_count}")
      mean_delta=$(ruby -e "printf '%+.2f', (${para_rerank}.to_f - ${para_rrf}.to_f) / ${para_count}")
      printf "| %s | %s | Paraphrase | %d | %s/10 | %s/10 | %s |\n" \
        "$scale" "$corpus_size" "$para_count" "$mean_rrf" "$mean_rerank" "$mean_delta"
    fi

    # All non-negative combined
    all_rrf=$((direct_rrf + para_rrf))
    all_rerank=$((direct_rerank + para_rerank))
    all_count=$((direct_count + para_count))
    if [[ $all_count -gt 0 ]]; then
      mean_rrf=$(ruby -e "printf '%.2f', ${all_rrf}.to_f / ${all_count}")
      mean_rerank=$(ruby -e "printf '%.2f', ${all_rerank}.to_f / ${all_count}")
      mean_delta=$(ruby -e "printf '%+.2f', (${all_rerank}.to_f - ${all_rrf}.to_f) / ${all_count}")
      printf "| **%s** | **%s** | **All** | **%d** | **%s/10** | **%s/10** | **%s** |\n" \
        "$scale" "$corpus_size" "$all_count" "$mean_rrf" "$mean_rerank" "$mean_delta"
    fi
  done

  # --- Negative query score analysis across scales ---
  printf "\n## Negative Queries: Rerank Score Distribution by Scale\n\n"
  printf "| Scale | Entries | Query | Candidates | Mean Score | Max Score | Scores > 0.5 |\n"
  printf "|-------|---------|-------|------------|------------|-----------|-------------|\n"

  for scale in "${all_scales[@]}"; do
    rdir=$(results_dir_for_scale "$scale")
    [[ ! -d "$rdir" ]] && continue

    corpus_size=$(grep '^Corpus:' "$rdir/summary.md" | sed 's/Corpus: //' | sed 's/ entries//')

    while IFS=$'\t' read -r qid qtype clusters query_text; do
      [[ "$qtype" != "negative" ]] && continue

      if [[ -f "$rdir/${qid}-scores.tsv" ]]; then
        stats=$(tail -n +2 "$rdir/${qid}-scores.tsv" | ruby -e '
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
        printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
          "$scale" "$corpus_size" "$qid" "$n_cand" "$mean_score" "$max_score" "$above_half"
      fi
    done < <(load_queries)
  done

  # --- Hypothesis assessment ---
  printf "\n## Hypothesis: Does reranking help more at larger corpus sizes?\n\n"
  printf "The hypothesis is that RRF degrades at scale (dual-channel overlap drops to zero)\n"
  printf "while cross-encoder reranking evaluates content directly and is unaffected by\n"
  printf "channel agreement. If true, the reranking delta should increase at larger scales.\n\n"

  printf "| Scale | Mean RRF P@10 (all) | Mean Reranked P@10 (all) | Delta |\n"
  printf "|-------|---------------------|--------------------------|-------|\n"

  for scale in "${all_scales[@]}"; do
    rdir=$(results_dir_for_scale "$scale")
    [[ ! -d "$rdir" ]] && continue

    corpus_size=$(grep '^Corpus:' "$rdir/summary.md" | sed 's/Corpus: //' | sed 's/ entries//')

    total_rrf=0 total_rerank=0 total_count=0
    while IFS=$'\t' read -r qid qtype clusters query_text; do
      [[ "$qtype" == "negative" ]] && continue
      total_count=$((total_count + 1))

      rrf_rel=0
      if [[ -f "$rdir/${qid}-rrf.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rrf_rel=$((rrf_rel + rel))
        done < "$rdir/${qid}-rrf.tsv"
      fi

      rerank_rel=0
      if [[ -f "$rdir/${qid}-rerank.tsv" ]]; then
        while IFS=$'\t' read -r rank eid cluster rscore rrf_s ch content; do
          [[ "$rank" == "rank" ]] && continue
          rel=$(is_relevant "$cluster" "$clusters")
          rerank_rel=$((rerank_rel + rel))
        done < "$rdir/${qid}-rerank.tsv"
      fi

      total_rrf=$((total_rrf + rrf_rel))
      total_rerank=$((total_rerank + rerank_rel))
    done < <(load_queries)

    if [[ $total_count -gt 0 ]]; then
      mean_rrf=$(ruby -e "printf '%.2f', ${total_rrf}.to_f / ${total_count}")
      mean_rerank=$(ruby -e "printf '%.2f', ${total_rerank}.to_f / ${total_count}")
      mean_delta=$(ruby -e "printf '%+.2f', (${total_rerank}.to_f - ${total_rrf}.to_f) / ${total_count}")
      printf "| %s (%s entries) | %s/10 | %s/10 | %s |\n" \
        "$scale" "$corpus_size" "$mean_rrf" "$mean_rerank" "$mean_delta"
    fi
  done

} > "$RESULTS/summary.md"

cat "$RESULTS/summary.md"

ENDED_AT=$(date +%s)
ELAPSED=$((ENDED_AT - STARTED_AT))

printf "\n\033[1m========================================\033[0m\n"
printf "\033[1m  Scale experiment complete (%dm %ds)\033[0m\n" "$((ELAPSED/60))" "$((ELAPSED%60))"
printf "\033[1m========================================\033[0m\n"
printf "\nResults: %s/summary.md\n" "$RESULTS"
