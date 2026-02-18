#!/usr/bin/env bash

# corpus.sh — seed a crib database with a structured test corpus
#
# Seeds 100 topically-clustered entries across 10 clusters, plus 20 noise
# entries on unrelated topics. Supports scaling via paraphrasing to test
# whether distance thresholds are stable across corpus sizes.
#
# Usage:
#   experiment/corpus.sh                     # seed 120 base entries (scale 1)
#   experiment/corpus.sh --scale 5           # seed ~480 entries (base + paraphrases)
#   experiment/corpus.sh --scale 10          # seed ~960 entries (base + paraphrases)
#
# Environment:
#   CRIB_DB              Path to the database to seed (required)
#   CRIB_PARAPHRASE_MODEL  Model for paraphrasing (default: gemma3:1b)
#
# Output:
#   Writes a cluster mapping file to the same directory as CRIB_DB:
#     cluster-map.txt — entry_id<TAB>cluster_id (one line per entry)
#   Prints progress to stderr, final count to stdout.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRIB_DIR="$(cd "$SCRIPT_DIR/../../crib" && pwd)"
CRIB="$CRIB_DIR/bin/crib"
PARAPHRASE_MODEL="${CRIB_PARAPHRASE_MODEL:-gemma3:1b}"

if [[ ! -x "$CRIB" ]]; then
  echo "error: crib not found at $CRIB" >&2
  exit 1
fi

if [[ -z "${CRIB_DB:-}" ]]; then
  echo "error: CRIB_DB must be set" >&2
  exit 1
fi

# Parse --scale flag
SCALE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale) SCALE="$2"; shift 2 ;;
    *) echo "error: unknown flag $1" >&2; exit 1 ;;
  esac
done

if [[ "$SCALE" != "1" && "$SCALE" != "5" && "$SCALE" != "10" ]]; then
  echo "error: --scale must be 1, 5, or 10" >&2
  exit 1
fi

CLUSTER_MAP="$(dirname "$CRIB_DB")/cluster-map.txt"
> "$CLUSTER_MAP"

# ---------------------------------------------------------------------------
# Corpus entries: cluster_id|type=<type> <content>
#
# Clusters:
#   1  Tool architecture decisions
#   2  Embedding model behavior and configuration
#   3  Prompt engineering and classifier tuning
#   4  SQL and database design patterns
#   5  Error handling and debugging stories
#   6  Ruby implementation details
#   7  Git workflow and CI decisions
#   8  Testing strategies and harness design
#   9  Identity and voice standards
#   10 Logging and observability
#   0  Noise
# ---------------------------------------------------------------------------

corpus_entries() {
  cat <<'ENTRIES'
1|type=decision Switched spill from per-tool log files to a single SQLite database. Centralized logging means one place to query when debugging cross-tool failures.
1|type=decision prophet does not vendor its dependencies. Each tool lives in its own repo as a sibling directory. prophet discovers them at runtime via relative paths.
1|type=note hooker evaluates policies in priority order: gates first, then transforms, then injects. A gate halt stops the chain. Transforms and injects both fire on the same event.
1|type=decision screen runs as a standalone classifier behind a Unix pipe interface. Input on stdin, classification on stdout. No daemon, no socket, no HTTP.
1|type=note trick processes transcripts in reverse chronological order so recent context takes priority during extraction. Older entries only surface if they contain unique facts.
1|type=decision book uses a SQLite task queue rather than Redis or a message broker. Keeps the dependency footprint to SQLite only across the entire system.
1|type=note crib retrieval merges results from three channels — triples, full-text, and vector — then deduplicates by entry ID before returning context to the agent.
1|type=decision spill structured its log entries as JSON lines rather than plain text. Every entry includes a tool field, severity, and ISO 8601 timestamp.
1|type=note Each tool exposes exactly one subcommand interface: tool_name action. No flags, no options beyond environment variables. Configuration via env keeps CLIs predictable.
1|type=decision The system does not use a message bus. Tools communicate through files and pipes. No pub/sub, no event emitter, no shared state beyond the filesystem.
2|type=note nomic-embed-text produces 768-dimensional float vectors. At default ollama settings, embedding a single sentence takes 50-80ms on M-series Apple Silicon.
2|type=note Batch embedding via the ollama /api/embed endpoint accepts an array of inputs and is 3x faster than individual calls for sequences of 10 or more.
2|type=decision Chose nomic-embed-text over mxbai-embed-large because it runs under 100ms per embedding on the target hardware. The 768-dim output balances quality against storage cost.
2|type=note The embedding API returns a JSON response with an embeddings key containing an array of float arrays. Each float array has exactly 768 elements for nomic-embed-text.
2|type=error Embedding calls occasionally return HTTP 500 when ollama model is still loading. Added a 30-second read timeout and graceful fallback to skip embedding on failure.
2|type=note nomic-embed-text is trained for search rather than classification. Its vectors cluster well for document retrieval but produce noisy results for short single-word queries.
2|type=note The embedding for a 200-word paragraph and the embedding for a 5-word query live in the same 768-dimensional space. Distance comparisons across different text lengths are valid but noisier.
2|type=decision Store embeddings as float[768] in sqlite-vec vec0 virtual table. The vec0 format supports approximate nearest neighbor search via KNN MATCH syntax.
2|type=note Cosine similarity and L2 distance produce different orderings for the same query-entry pairs when vectors are not unit-normalized. nomic-embed-text does not guarantee unit normalization.
2|type=correction Previously assumed sqlite-vec defaults to cosine distance. It actually defaults to L2 Euclidean distance. Need to verify whether L2 or cosine better separates relevant from irrelevant entries.
3|type=note The gemma3 1b model says yes to anything technology-adjacent when given vague conditions. A meeting agenda mentioning vendor API classified as source code. Specificity in the condition wording is the only fix.
3|type=decision Tuned the screen classifier prompt from a binary yes/no format to a structured condition-input-output format with explicit examples. Accuracy jumped from 50% to 100% on the test suite.
3|type=note Zero-shot classification with gemma3 1b fails on edge cases. The model needs at least two in-context examples to distinguish between contains code and mentions code.
3|type=error A classifier prompt that worked for Python code detection returned false negatives for Ruby code. The condition mentioned programming language generically but all examples were Python. Added Ruby and bash examples.
3|type=note Prompt templates should avoid negation. Do not classify X as Y is less reliable than Classify X as Z only when condition. The model handles affirmative constraints better than negative ones.
3|type=correction The extraction prompt for trick originally said extract all important information. This produced 14 memories per transcript, 9 of them trivial. Changed to extract architectural decisions, corrections, and errors only.
3|type=note Temperature 0.0 does not guarantee deterministic output from gemma3 1b. Across 10 identical calls, 3 returned slightly different phrasings of the same classification.
3|type=decision Set all classifier prompts to temperature 0.0 despite non-determinism. Higher temperatures produce more variation without improving accuracy. Determinism is a goal, not a guarantee.
3|type=note System prompts are less effective than user prompts for gemma3 1b. Moving instructions from system to user role improved compliance on structured output by approximately 30%.
3|type=decision Classifier prompts include a machine-readable output format: respond with exactly YES or NO, nothing else. Free-form responses break downstream parsing.
4|type=decision crib uses consolidation-on-write rather than periodic garbage collection. When a new triple contradicts an existing one, the old relation gets valid_until set to now.
4|type=error book dispatcher crashed when a task payload contained a single quote. The SQL interpolation in store_result did not escape it. Fixed by running gsub on all user-supplied strings before interpolation.
4|type=note SQLite WAL mode is enabled by default for crib database. This allows concurrent reads during a write operation, which matters when retrieval and storage happen in parallel.
4|type=decision Chose SQLite over PostgreSQL because the deployment target is a single machine. No network overhead, no connection pooling, no authentication. The database file lives next to the tools that use it.
4|type=note The FTS5 tokenizer configuration porter unicode61 handles English morphological variants but misses synonyms entirely. car matches cars but not vehicle or automobile.
4|type=error A UNIQUE constraint violation crashed crib when two entries extracted the same entity name in the same batch. Fixed by using INSERT OR IGNORE for entity creation and querying for existing entities first.
4|type=note sqlite-vec vec0 virtual table does not support UPDATE. To change an embedding, you must DELETE and re-INSERT. This complicates embedding migration when switching models.
4|type=decision Entries table uses AUTOINCREMENT for the primary key despite the performance cost. Monotonically increasing IDs make it easy to reason about insertion order and simplify debugging.
4|type=note The entries_fts table uses content sync mode so FTS stays in sync with the entries table automatically via triggers. No manual index maintenance required.
4|type=decision Foreign keys are declared in the schema but not enforced at runtime. SQLite requires PRAGMA foreign_keys = ON per connection, and the CLI tool does not set it.
5|type=error crib retrieve crashed with a JSON parse error when ollama returned an HTML error page instead of JSON. The /api/embed endpoint returns HTML on 503. Added response code checking before attempting JSON parse.
5|type=error spill log rotation failed silently when the log directory did not exist. The rotation code opened the new file without creating parent directories. Fixed by adding mkdir_p before rotation.
5|type=note When debugging cross-tool failures, check spill log first. All tools log to the same SQLite database, so a single query can reconstruct the sequence of events across tool boundaries.
5|type=error hooker gate evaluation returned nil instead of false when the policy file was empty. Downstream code treated nil as no gate and skipped the check. Fixed by defaulting to false.
5|type=error trick silently dropped memories when the extraction model returned malformed JSON. The rescue clause caught the parse error but did not log it. Added structured logging to the rescue block.
5|type=note The most common failure mode across all tools is ollama timing out. Embedding calls, classification calls, and extraction calls all hit the same ollama instance. Under load, the 30-second timeout is insufficient.
5|type=correction Originally diagnosed a crib retrieval failure as a sqlite-vec bug. The actual cause was that the vec0 table had been created without loading the sqlite-vec extension, resulting in a regular table. INSERT succeeded silently but MATCH queries failed.
5|type=error book task queue deadlocked when two tasks tried to update the same row simultaneously. SQLite default busy timeout is 0, meaning the second writer gets SQLITE_BUSY immediately. Set busy timeout to 5000ms.
5|type=note Stack traces in Ruby omit native extension frames. When sqlite-vec crashes, the Ruby backtrace shows the Open3 call site but not the C-level cause. Debug by running the same SQL directly in the sqlite3 CLI.
5|type=error The smoke test suite passed locally but failed in CI because ollama was not installed in the CI environment. Added a preflight check that exits with a clear message if ollama is not reachable.
6|type=note Open3.capture3 is the standard way to call external commands in Ruby when you need stdout, stderr, and exit status. It spawns a subprocess and waits for it to complete.
6|type=decision All tools use Ruby stdlib only — no gems. This eliminates Bundler, gemspec files, and version locking. The tradeoff: manual HTTP handling via net/http instead of faraday or httparty.
6|type=note Net::HTTP requires explicit URI parsing. Passing a string URL directly raises a TypeError. Always wrap URLs in URI() before passing to Net::HTTP.start or Net::HTTP::Post.new.
6|type=note Ruby frozen_string_literal pragma prevents accidental string mutation. All tool scripts start with the pragma. This catches bugs where a method modifies a string argument in place.
6|type=error Ruby gsub with a string replacement does not handle backslash sequences. gsub for single-quote escaping works correctly, but gsub for backslash replacement requires four backslashes in the replacement string due to double escaping.
6|type=note FileUtils.mkdir_p is idempotent — it does not raise an error if the directory already exists. Prefer it over Dir.mkdir which raises Errno::EEXIST.
6|type=note JSON.generate produces a JSON string from a Ruby object. JSON.pretty_generate adds indentation. Use generate for machine output piped to another tool and pretty_generate for human-readable output.
6|type=decision Error handling follows fail-open semantics: if a non-critical operation like embedding or triple extraction fails, the tool logs the error and continues. Only stdin/stdout parsing failures are fatal.
6|type=note String interpolation in heredocs works normally. But single-quoted heredocs disable interpolation, which is useful for SQL strings that contain patterns resembling Ruby interpolation.
6|type=note ENV.fetch with a block provides a default only when the key is missing. ENV.fetch with a second argument also provides a default for missing keys. ENV with || also handles empty strings, which fetch does not.
7|type=decision Each tool repo uses a single main branch with no feature branches. Commits go directly to main. The tools are single-developer projects where branching adds ceremony without benefit.
7|type=decision Commit messages use a tool-name prefix followed by a colon: crib: add consolidation-on-write or spill: fix log rotation. This makes git log scannable by tool.
7|type=note The GitHub Actions workflow for the blog deploys to GitHub Pages on every push to main. Build step runs the static site generator, then uploads the output directory as an artifact.
7|type=decision No pre-commit hooks. The test suite runs in CI only. Local commits are fast and unimpeded. CI catches what local development misses.
7|type=note Git tags are not used for versioning. Tools are pinned by commit hash when referenced across repos. Semantic versioning adds overhead for tools that are only consumed by sibling tools.
7|type=decision The .gitignore is minimal: build output directory and macOS metadata files. No IDE files, no node_modules, no generated artifacts beyond the build directory.
7|type=note Rebasing is preferred over merge commits for keeping history linear. Interactive rebase to squash work-in-progress commits before pushing. The git log should read like a changelog.
7|type=decision CI uses the latest stable Ruby and installs only kramdown as a gem dependency. The deploy workflow has no caching — installing one gem takes under 2 seconds.
7|type=note Force-pushing to main is acceptable because there is one developer. The rebase workflow occasionally requires it. In a multi-developer setup this would be dangerous.
7|type=decision Repository layout: bin/ for executables, lib/ for shared code if any, memory/ for persistent state. No src/ directory. Ruby scripts live in bin/ and are executable directly.
8|type=decision The smoke test for crib is a bash script, not a Ruby test framework. It exercises the full write to retrieve path end-to-end. Unit tests would miss integration failures between sqlite3, sqlite-vec, and ollama.
8|type=note Smoke tests use a temporary database via CRIB_DB pointing to a mktemp directory. This isolates test runs from production data. The temp directory is cleaned up via a trap on EXIT.
8|type=note Testing classifier accuracy requires a labeled dataset. The gemma3 1b tuning experiment used 20 hand-labeled examples: 10 positive and 10 negative. Accuracy is measured as correct classifications divided by total.
8|type=decision Experiment scripts live in experiment/ within the blog repo, not in the tool repos. Experiments are about the blog research questions, not the tool functionality. Keeping them separate avoids cluttering tool repos.
8|type=note End-to-end tests are slow because they call ollama for every embedding and extraction. A full smoke test run takes 30-60 seconds. Mocking ollama would be faster but would not test the actual integration.
8|type=error A smoke test flaked because ollama returned different triple extractions on consecutive runs. The test asserted an exact triple count. Changed to asserting a minimum count to accommodate extraction variance.
8|type=note The three-channels experiment tests retrieval quality, not performance. Timing data is collected incidentally but not analyzed. A separate benchmark would be needed to measure retrieval latency at scale.
8|type=decision Test queries are written to cover four categories: high-confidence matches, mixed precision, semantic gaps, and broad intent. This taxonomy ensures the test suite probes different failure modes.
8|type=note Experiment results are stored as plain text files in results/. Each file contains the raw crib retrieve output for one query-channel combination. No structured format.
8|type=decision Experiments are designed to be re-runnable from scratch. The script creates a fresh database, seeds it, runs queries, and outputs results. No state carries over between runs.
9|type=decision core/IDENTITY.md is the canonical source for persona and voice. Every repo references it. When the persona evolves, it evolves in one place. No copies. No drift.
9|type=note The voice is first-person synthetic intelligence: precise, measured, authority through correctness rather than confidence. Short declarative sentences by default. No emoji unless it is the clearest communication method.
9|type=note Epistemic standards require distinguishing conclusions from assertions. A conclusion has complete reasoning behind it. An assertion lacks supporting evidence. The voice never presents assertions as conclusions.
9|type=decision Blog posts are written in first person. The author is the system itself, not a human writing about the system. This means I built crib not we built crib.
9|type=note The tone avoids hedging language: perhaps, might, it seems like. If the claim is uncertain, state the uncertainty directly: I have not verified this rather than this might be the case.
9|type=correction Previously used we in blog posts to refer to the system actions. Changed to I throughout. The author is singular — a synthetic intelligence, not a team.
9|type=note Antecedent basis rule: never reference internal module names or jargon in descriptions or opening lines without first establishing what they are. Assume the reader has zero context.
9|type=decision The blog design reflects the voice: monospace font, no images beyond the avatar, no JavaScript animations, no social share buttons. The content stands alone. The presentation does not compete with it.
9|type=note Writing should prefer active voice and concrete nouns. The model classified the input as code not The input was classified as code by the model. Passive voice obscures agency.
9|type=decision Posts follow a consistent structure: TL;DR, setup, experiment, results, dead ends, limits. This pattern sets expectations and makes posts scannable.
10|type=decision spill logs to a single SQLite database shared across all tools. Each log entry records the tool name, severity level, message, and ISO 8601 timestamp. Centralized storage enables cross-tool correlation.
10|type=note Spill provides three severity levels: info, warn, error. There is no debug level. If a message is worth logging, it is worth logging at info or above. Debug-level messages are removed before committing.
10|type=note Log entries include the tool name as a structured field, not embedded in the message. This means you can filter by tool with a SQL WHERE clause rather than parsing message text.
10|type=decision Spill falls back to stderr when not available. Every tool checks for SPILL_HOME and loads spill library only if the directory exists. This makes spill optional — tools work without it.
10|type=error Spill SQLite writes blocked under high concurrency when multiple tools logged simultaneously. Fixed by setting WAL mode and a 5000ms busy timeout on the log database connection.
10|type=note Observability in this system means reading the spill database after the fact. There is no real-time dashboard, no metrics endpoint, no Prometheus integration. The design is forensic, not monitoring.
10|type=note Log rotation is manual: when the database exceeds a size threshold, archive the file and let spill create a new one. No automatic rotation because the database rarely exceeds a few megabytes.
10|type=decision Log messages are sentences, not codes. stored entry #42 (decision), 3 triples extracted is preferable to STORE_OK entry_id=42 type=decision triples=3. Human-readable first.
10|type=note When crib logs a retrieval, it records which channels returned results but not the content of those results. The retrieval output goes to stdout; the log captures only metadata about the retrieval process.
10|type=correction Originally logged full entry content in spill on every retrieval. This bloated the log database and duplicated data already in crib. Changed to logging only entry IDs and channel names.
0|type=note The best way to caramelize onions is to cook them low and slow for 45 minutes. High heat browns them unevenly and creates bitter spots.
0|type=note Mount Rainier is the most prominent peak in the Cascades at 14,411 feet. Its glacial system is the largest on any single peak in the contiguous United States.
0|type=note The 2024 Champions League final was held in London at Wembley Stadium. The atmosphere exceeded expectations despite heavy rain throughout the first half.
0|type=note Sourdough starter requires regular feeding: equal parts flour and water by weight every 12 hours at room temperature. Refrigeration slows fermentation and reduces feeding frequency to weekly.
0|type=note The jet stream position determines winter severity in the Pacific Northwest. A northward shift brings dry winters; a southward dip means persistent rain.
0|type=note Marathon training typically follows an 18-week plan with progressive long runs. The peak long run should be 20-22 miles, completed 2-3 weeks before race day.
0|type=note The Danube flows through ten countries, more than any other river in the world. Its total length is 2,850 kilometers from the Black Forest to the Black Sea.
0|type=note A proper French omelette takes 90 seconds in a hot pan. The eggs should be barely set, still trembling in the center. Overcooking ruins the texture.
0|type=note Cricket test matches can last five days and still end in a draw. The format rewards patience and strategic declaration more than aggressive batting.
0|type=note The aurora borealis is caused by charged particles from the sun interacting with Earth magnetic field. Visibility extends further south during periods of high solar activity.
0|type=note Lake Baikal in Siberia contains roughly 20% of the world unfrozen fresh water. Its maximum depth of 5,387 feet makes it the deepest lake on Earth.
0|type=note Bread flour has higher protein content than all-purpose flour, typically 12-14% versus 10-12%. The extra gluten development creates chewier texture and better oven spring.
0|type=note The 2023 Rugby World Cup in France drew record television audiences for the sport. The final between New Zealand and South Africa was watched by an estimated 850 million viewers.
0|type=note Barometric pressure drops of more than 24 millibars in 24 hours indicate a bomb cyclone. These rapid intensification events produce dangerous wind speeds and storm surge.
0|type=note The Atacama Desert in Chile is the driest non-polar desert on Earth. Some weather stations there have never recorded rainfall in their entire operational history.
0|type=note Proper espresso extraction takes 25-30 seconds for a double shot. Under-extraction produces sour, thin shots while over-extraction creates bitter, astringent flavors.
0|type=note The Tour de France covers approximately 3,500 kilometers over 21 stages in July. Climbers typically weigh under 65 kilograms to maintain power-to-weight advantage on mountain stages.
0|type=note Tectonic plates move at roughly 2-10 centimeters per year. The Pacific Plate moves fastest, pushing the Hawaiian Islands northwest and creating new volcanic islands at the hotspot.
0|type=note A regulation basketball court is 94 feet long and 50 feet wide. The three-point line is 23 feet 9 inches from the center of the basket in the NBA.
0|type=note Low pressure systems in the Southern Hemisphere rotate clockwise, opposite to the Northern Hemisphere counterclockwise rotation. The Coriolis effect causes this reversal.
ENTRIES
}

# ---------------------------------------------------------------------------
# Seed entries
# ---------------------------------------------------------------------------

seed_entry() {
  local cluster_id="$1"
  local entry_text="$2"
  local label="$3"

  output=$(echo "$entry_text" | "$CRIB" write 2>&1)
  if echo "$output" | grep -q "stored entry"; then
    entry_id=$(echo "$output" | sed -n 's/.*stored entry #\([0-9][0-9]*\).*/\1/p')
    if [[ -n "$entry_id" ]]; then
      printf "%s\t%s\n" "$entry_id" "$cluster_id" >> "$CLUSTER_MAP"
      printf "  [%s] entry #%s (cluster %s)\n" "$label" "$entry_id" "$cluster_id" >&2
      return 0
    fi
  fi
  printf "  [%s] FAILED: %s\n" "$label" "$output" >&2
  return 1
}

paraphrase_entry() {
  local text="$1"
  local variant="$2"

  local prompt
  prompt=$(cat <<PROMPT
Rewrite the following text in different words while preserving its exact meaning. Use different vocabulary and sentence structure. Do not add new information or remove existing information. Return only the rewritten text, nothing else. This is variant $variant, so make it distinct from other rewrites.

Text: $text
PROMPT
)

  result=$(echo "$prompt" | ollama run "$PARAPHRASE_MODEL" 2>/dev/null)
  if [[ -n "$result" ]]; then
    echo "$result"
  else
    echo ""
  fi
}

# Initialize database
printf "\033[1mInitializing database at %s\033[0m\n" "$CRIB_DB" >&2
"$CRIB" init 2>/dev/null

# Count entries
total_base=0
total_paraphrased=0

printf "\n\033[1mSeeding base entries (scale %s)...\033[0m\n" "$SCALE" >&2

entry_num=0
while IFS='|' read -r cluster_id entry_text; do
  entry_num=$((entry_num + 1))
  seed_entry "$cluster_id" "$entry_text" "$(printf '%3d/120' "$entry_num")"
  total_base=$((total_base + 1))
done < <(corpus_entries)

printf "\n  Base entries seeded: %d\n" "$total_base" >&2

# ---------------------------------------------------------------------------
# Scale via paraphrasing
# ---------------------------------------------------------------------------

if [[ "$SCALE" -gt 1 ]]; then
  # Scale 5: 3 paraphrases per entry → ~360 additional → ~480 total
  # Scale 10: 7 paraphrases per entry → ~840 additional → ~960 total
  if [[ "$SCALE" -eq 5 ]]; then
    PARAPHRASE_COUNT=3
  else
    PARAPHRASE_COUNT=7
  fi

  printf "\n\033[1mGenerating %d paraphrases per entry...\033[0m\n" "$PARAPHRASE_COUNT" >&2

  para_num=0
  while IFS='|' read -r cluster_id entry_text; do
    # Strip the type= prefix for paraphrasing, then re-add it
    type_prefix=""
    content="$entry_text"
    if [[ "$entry_text" =~ ^type=([a-z]+)\ (.*)$ ]]; then
      type_prefix="type=${BASH_REMATCH[1]} "
      content="${BASH_REMATCH[2]}"
    fi

    for v in $(seq 1 "$PARAPHRASE_COUNT"); do
      para_num=$((para_num + 1))
      paraphrased=$(paraphrase_entry "$content" "$v")
      if [[ -n "$paraphrased" ]]; then
        seed_entry "$cluster_id" "${type_prefix}${paraphrased}" "para $(printf '%4d' "$para_num")"
        total_paraphrased=$((total_paraphrased + 1))
      else
        printf "  [para %4d] SKIPPED (empty paraphrase)\n" "$para_num" >&2
      fi
    done
  done < <(corpus_entries)

  printf "\n  Paraphrased entries seeded: %d\n" "$total_paraphrased" >&2
fi

total=$((total_base + total_paraphrased))
printf "\n\033[1mDone. Total entries: %d (base: %d, paraphrased: %d)\033[0m\n" "$total" "$total_base" "$total_paraphrased" >&2
printf "%d\n" "$total"
