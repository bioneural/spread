#!/usr/bin/env ruby
# frozen_string_literal: true

# sensitivity.rb — test distance threshold stability across corpus scales
#
# Measures cosine distance distributions at corpus sizes of 10, 100, 1000,
# and 10000 entries. Uses cached background entries to avoid regeneration.
#
# Usage:
#   ruby experiment/sensitivity.rb                     # all scales
#   ruby experiment/sensitivity.rb --scales 10,100     # specific scales
#
# Dependencies: sqlite3 gem, ollama (nomic-embed-text, gemma3:1b)

require 'json'
require 'net/http'
require 'uri'
require 'tempfile'
require 'fileutils'
require 'sqlite3'

SCRIPT_DIR = File.expand_path(__dir__)
RESULTS_DIR = File.join(SCRIPT_DIR, 'results', 'sensitivity')
ENTRY_CACHE = File.join(RESULTS_DIR, 'background-entries.txt')
GROUND_TRUTH = File.join(SCRIPT_DIR, 'ground-truth.txt')
CORPUS_SCRIPT = File.join(SCRIPT_DIR, 'corpus.sh')

OLLAMA_HOST = ENV.fetch('OLLAMA_HOST', 'http://localhost:11434')
EMBEDDING_MODEL = ENV.fetch('CRIB_EMBEDDING_MODEL', 'nomic-embed-text')
GENERATION_MODEL = ENV.fetch('CRIB_GENERATION_MODEL', 'gemma3:1b')
VEC_EXTENSION = ENV.fetch('CRIB_VEC_EXTENSION') {
  `python3 -c "import sqlite_vec; print(sqlite_vec.loadable_path())"`.strip
}

SCALES = if ARGV.include?('--scales')
  ARGV[ARGV.index('--scales') + 1].split(',').map(&:to_i)
else
  [10, 100, 1000, 10000]
end

FileUtils.mkdir_p(RESULTS_DIR)

# ---------------------------------------------------------------------------
# Ollama API
# ---------------------------------------------------------------------------

def ollama_post(path, body, retries: 3)
  uri = URI("#{OLLAMA_HOST}#{path}")
  req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
  req.body = JSON.generate(body)
  attempts = 0
  begin
    attempts += 1
    res = Net::HTTP.start(uri.host, uri.port, read_timeout: 300, open_timeout: 30) { |http| http.request(req) }
    JSON.parse(res.body)
  rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET => e
    if attempts < retries
      $stderr.puts "\n    WARN: #{e.class} on attempt #{attempts}, retrying in #{attempts * 5}s..."
      sleep(attempts * 5)
      retry
    else
      $stderr.puts "\n    ERROR: #{e.class} after #{retries} attempts: #{e.message}"
      raise
    end
  end
end

def embed(texts)
  texts = [texts] if texts.is_a?(String)
  result = ollama_post('/api/embed', { model: EMBEDDING_MODEL, input: texts })
  result['embeddings']
end

def generate_entries(topic, count)
  prompt = "Generate exactly #{count} short factual notes (1-2 sentences each) about " \
           "different aspects of #{topic}. One note per line. No numbering. No blank lines. " \
           "No introductory text. Start immediately with the first note."
  result = ollama_post('/api/generate', { model: GENERATION_MODEL, prompt: prompt, stream: false })
  result['response'].lines.map(&:strip).reject { |l| l.empty? || l.length < 10 }
end

# ---------------------------------------------------------------------------
# Base entries (from corpus.sh)
# ---------------------------------------------------------------------------

def load_base_entries
  in_heredoc = false
  entries = []
  File.readlines(CORPUS_SCRIPT).each do |line|
    if line.strip == "cat <<'ENTRIES'"
      in_heredoc = true
      next
    end
    if line.strip == 'ENTRIES'
      in_heredoc = false
      next
    end
    next unless in_heredoc

    if line =~ /^(\d+)\|(.+)$/
      entries << { cluster_id: $1.to_i, content: $2.strip }
    end
  end
  entries
end

# ---------------------------------------------------------------------------
# Queries and ground truth
# ---------------------------------------------------------------------------

def load_queries
  File.readlines(GROUND_TRUTH)
    .reject { |l| l.start_with?('#') || l.strip.empty? }
    .map do |line|
      parts = line.strip.split("\t")
      { id: parts[0], type: parts[1], clusters: parts[2], text: parts[3] }
    end
end

# ---------------------------------------------------------------------------
# Background entry cache
# ---------------------------------------------------------------------------

TOPICS = [
  "quantum mechanics and particle physics",
  "organic chemistry reactions and synthesis",
  "cellular biology and mitosis",
  "stellar evolution and supernovae",
  "plate tectonics and earthquake mechanics",
  "marine ecology and coral reef systems",
  "tropical meteorology and hurricane formation",
  "deep ocean exploration and hydrothermal vents",
  "human genetics and DNA sequencing methods",
  "cognitive neuroscience and brain imaging",
  "materials science and polymer engineering",
  "thermodynamics and heat transfer",
  "microbiology and bacterial resistance",
  "paleontology and dinosaur fossil dating",
  "volcanology and magma chamber dynamics",
  "botany and plant hormone signaling",
  "animal behavior and migration ethology",
  "nuclear physics and radioactive decay",
  "fluid dynamics and turbulence modeling",
  "electromagnetic wave propagation and optics",
  "cardiology and coronary bypass surgery",
  "dermatology and autoimmune skin conditions",
  "oncology and immunotherapy cancer treatment",
  "pediatric developmental milestones",
  "orthopedic joint replacement procedures",
  "pharmacology and drug metabolism pathways",
  "epidemiology and infectious disease modeling",
  "immunology and vaccine development",
  "psychiatric medication management",
  "emergency trauma response protocols",
  "bridge and dam structural engineering",
  "aerospace rocket propulsion design",
  "chemical plant safety operations",
  "biomedical prosthetic device design",
  "environmental soil remediation",
  "nuclear reactor coolant systems",
  "industrial robotic assembly lines",
  "electrical power grid load balancing",
  "internal combustion engine thermodynamics",
  "municipal water treatment processes",
  "ancient Greek philosophical schools",
  "medieval European feudal governance",
  "Victorian novel narrative techniques",
  "Indo-European language family evolution",
  "Pacific Island cultural anthropology",
  "Mesoamerican archaeological excavations",
  "Buddhist and Hindu comparative theology",
  "Italian Renaissance painting techniques",
  "ancient Latin grammatical structures",
  "trolley problem and utilitarian ethics",
  "macroeconomic monetary policy tools",
  "childhood developmental psychology stages",
  "urban gentrification sociology",
  "parliamentary versus presidential systems",
  "glacial landform geomorphology",
  "global population demographic transitions",
  "forensic evidence collection procedures",
  "Montessori educational pedagogy",
  "United Nations peacekeeping operations",
  "behavioral economics and prospect theory",
  "oil painting layering and glazing techniques",
  "marble sculpture carving methodology",
  "jazz improvisation and modal theory",
  "theatrical lighting and stage design",
  "classical ballet positions and movements",
  "long exposure landscape photography",
  "documentary film interview techniques",
  "Gothic cathedral flying buttress design",
  "Navajo textile weaving traditions",
  "Japanese raku ceramic firing",
  "French pastry lamination techniques",
  "raised bed vegetable garden planning",
  "residential plumbing repair methods",
  "motorcycle chain maintenance procedures",
  "powerlifting progressive overload programs",
  "Mediterranean diet meal planning",
  "newborn sleep training approaches",
  "positive reinforcement dog training",
  "traditional hand quilting patterns",
  "mortise and tenon joinery woodworking",
  "baseball curveball pitching physics",
  "4-3-3 soccer tactical formations",
  "tennis topspin serve biomechanics",
  "competitive freestyle swimming technique",
  "artistic gymnastics scoring deductions",
  "ice hockey power play strategies",
  "rugby lineout lifting mechanics",
  "golf driver swing plane analysis",
  "Tour de France peloton drafting tactics",
  "Brazilian jiu-jitsu submission techniques",
  "temperate deciduous forest ecosystems",
  "Arctic sea ice extent monitoring",
  "Sonoran desert plant adaptations",
  "Himalayan mountaineering route planning",
  "Mississippi river delta sedimentation",
  "Arctic tern migration tracking",
  "supercell tornado genesis conditions",
  "thermohaline ocean circulation patterns",
  "autumn leaf color change biochemistry",
  "African savanna predator-prey dynamics",
  "5G millimeter wave antenna deployment",
  "Bessemer steel manufacturing processes",
  "container ship port logistics operations",
  "precision GPS-guided agriculture",
  "underground coal mining safety systems",
  "lithographic printing press technology",
  "synthetic nylon fiber production",
  "industrial food freeze-drying methods",
  "GPS satellite orbital mechanics",
  "lithium-ion battery storage chemistry",
  "corporate tax accounting standards",
  "social media marketing attribution",
  "just-in-time supply chain management",
  "commercial real estate cap rate analysis",
  "actuarial life insurance risk modeling",
  "central bank interest rate mechanisms",
  "McKinsey 7S consulting framework",
  "retail point-of-sale inventory tracking",
  "hotel revenue yield management",
  "intermodal freight routing optimization",
  "Roman Republic governance structures",
  "spinning jenny Industrial Revolution impact",
  "World War I Verdun trench warfare",
  "Cuban Missile Crisis Cold War diplomacy",
  "ancient Egyptian pyramid construction",
  "Silk Road caravanserai trade networks",
  "French Revolution Reign of Terror",
  "Gettysburg American Civil War battle",
  "Ming Dynasty porcelain craftsmanship",
  "Viking longship North Atlantic voyages",
  "Himalayan tectonic collision geology",
  "Amazon rainforest canopy biodiversity",
  "Sahara Desert sand dune formation",
  "Pacific Ring of Fire volcanic activity",
  "Great Barrier Reef bleaching events",
  "Antarctic ice core climate records",
  "Nile River seasonal flood irrigation",
  "Mediterranean scrubland fire ecology",
  "Appalachian folded mountain geology",
  "Caribbean volcanic island arc formation",
  "Burgundy wine terroir and viticulture",
  "Parmigiano-Reggiano cheese aging caves",
  "cover crop sustainable farming rotations",
  "Ethiopian coffee bean processing methods",
  "Langstroth hive beekeeping management",
  "Japanese rice paddy water management",
  "regenerative cattle grazing systems",
  "Spanish olive oil cold press extraction",
  "bean-to-bar chocolate tempering process",
  "Korean kimchi fermentation techniques",
  "symphony orchestra seating arrangement",
  "Mississippi Delta blues guitar origins",
  "analog synthesizer sound design",
  "Wagnerian opera vocal projection",
  "Abbey Road rock album recording techniques",
  "Appalachian folk banjo picking styles",
  "counterpoint and fugue music theory",
  "Steinway concert piano action mechanism",
  "West African djembe drumming traditions",
  "Renaissance choral polyphony harmonics",
  "deep sea tuna longline fishing",
  "hot air balloon envelope inflation",
  "diamond faceting and gemstone cutting",
  "Fresnel lens lighthouse optics history",
  "Coptic bookbinding stitch patterns",
  "Grasse perfume essential oil distillation",
  "Swiss mechanical watch escapement design",
  "modular origami polyhedron construction",
  "Arabic naskh calligraphy stroke order",
  "Tiffany stained glass copper foil method",
  "beehive colony collapse disorder research",
  "avalanche prediction snow crystal analysis",
  "coral reef artificial structure restoration",
  "urban rooftop rainwater harvesting systems",
  "heritage grain sourdough fermentation",
  "vintage vinyl record pressing processes",
  "bonsai tree shaping and pruning methods",
  "astronomical telescope mirror grinding",
  "handmade paper mulberry fiber processing",
  "traditional Japanese indigo dyeing",
].freeze

def ensure_cached_entries(needed)
  have = File.exist?(ENTRY_CACHE) ? File.readlines(ENTRY_CACHE).count : 0
  return if have >= needed

  to_generate = needed - have
  $stderr.puts "    cache has #{have} entries, generating #{to_generate} more..."

  generated = 0
  topic_idx = have / 20
  entries_per_topic = 20
  start = Time.now

  File.open(ENTRY_CACHE, 'a') do |f|
    while generated < to_generate
      topic = TOPICS[topic_idx % TOPICS.length]
      topic_idx += 1

      batch = generate_entries(topic, [entries_per_topic, to_generate - generated].min)
      batch.each { |line| f.puts(line) }
      generated += batch.length

      elapsed = Time.now - start
      rate = elapsed > 0 ? (generated / elapsed).round(1) : 0
      pct = (generated * 100.0 / to_generate).round(0)
      $stderr.print "\r    generating: #{generated}/#{to_generate} (#{pct}%) — #{rate} entries/sec"

      if topic_idx >= TOPICS.length && generated < to_generate
        entries_per_topic += 5
      end
    end
  end
  $stderr.puts "\n    cache complete: #{have + generated} entries total"
end

# ---------------------------------------------------------------------------
# Run one scale
# ---------------------------------------------------------------------------

def run_scale(scale)
  all_base = load_base_entries
  queries = load_queries

  $stderr.puts "\n#{'=' * 40}"
  $stderr.puts "  Scale #{scale}"
  $stderr.puts '=' * 40

  # Select base entries for this scale
  if scale <= 10
    # 1 per cluster, no noise
    seen = Hash.new(0)
    base = all_base.select { |e| e[:cluster_id] != 0 && (seen[e[:cluster_id]] += 1) <= 1 }
  elsif scale <= 100
    # all cluster entries, no noise
    base = all_base.select { |e| e[:cluster_id] != 0 }
  else
    base = all_base
  end

  # Create temp database
  dir = Dir.mktmpdir('sensitivity')
  db_path = File.join(dir, 'sensitivity.db')
  db = SQLite3::Database.new(db_path)
  db.enable_load_extension(true)
  db.load_extension(VEC_EXTENSION)
  db.execute('CREATE TABLE entries (id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, cluster_id INTEGER)')
  db.execute('CREATE VIRTUAL TABLE entries_vec USING vec0(embedding float[768] distance_metric=cosine)')

  # Seed base entries (batch embed)
  $stderr.puts "\n  Seeding #{base.length} base entries..."
  base.each_slice(20) do |batch|
    texts = batch.map { |e| e[:content] }
    embeddings = embed(texts)
    next unless embeddings

    db.transaction do
      batch.each_with_index do |entry, i|
        db.execute('INSERT INTO entries (content, cluster_id) VALUES (?, ?)', [entry[:content], entry[:cluster_id]])
        id = db.last_insert_row_id
        db.execute('INSERT INTO entries_vec (rowid, embedding) VALUES (?, ?)', [id, JSON.generate(embeddings[i])])
      end
    end
  end
  base_count = db.get_first_value('SELECT COUNT(*) FROM entries')
  $stderr.puts "    #{base_count} base entries seeded"

  # Seed background entries if needed
  bg_needed = scale - base_count
  if bg_needed > 0
    ensure_cached_entries(bg_needed)
    $stderr.puts "  Seeding #{bg_needed} background entries..."

    lines = File.readlines(ENTRY_CACHE, chomp: true).first(bg_needed)
    seeded = 0
    start = Time.now

    lines.each_slice(20) do |batch|
      embeddings = embed(batch)
      unless embeddings
        $stderr.puts "    WARN: embed failed for batch"
        next
      end

      db.transaction do
        batch.each_with_index do |text, i|
          db.execute('INSERT INTO entries (content, cluster_id) VALUES (?, ?)', [text, -1])
          id = db.last_insert_row_id
          db.execute('INSERT INTO entries_vec (rowid, embedding) VALUES (?, ?)', [id, JSON.generate(embeddings[i])])
        end
      end
      seeded += batch.length

      elapsed = Time.now - start
      rate = elapsed > 0 ? (seeded / elapsed).round(1) : 0
      pct = (seeded * 100.0 / bg_needed).round(0)
      $stderr.print "\r    seeding: #{seeded}/#{bg_needed} (#{pct}%) — #{rate} entries/sec"
    end
    $stderr.puts "\n    #{seeded} background entries seeded"
  end

  total = db.get_first_value('SELECT COUNT(*) FROM entries')
  $stderr.puts "  Total: #{total} entries"

  # Build cluster map: entry_id -> cluster_id
  cluster_map = {}
  db.execute('SELECT id, cluster_id FROM entries').each { |row| cluster_map[row[0]] = row[1] }

  # Run queries
  csv_path = File.join(RESULTS_DIR, "distances-#{scale}.csv")
  $stderr.puts "\n  Running #{queries.length} queries..."

  File.open(csv_path, 'w') do |csv|
    csv.puts 'query_id,entry_id,cosine_dist,relevant'

    queries.each_with_index do |q, qi|
      $stderr.puts "    [#{qi + 1}/#{queries.length}] #{q[:id]}: #{q[:text]}"

      qvec = embed(q[:text])&.first
      unless qvec
        $stderr.puts "      SKIP (embed failed)"
        next
      end

      qvec_json = JSON.generate(qvec)

      # Compute cosine distance to every entry
      rows = db.execute(
        "SELECT rowid, vec_distance_cosine(embedding, ?) as dist FROM entries_vec ORDER BY dist",
        [qvec_json]
      )

      # Determine relevant clusters for this query
      rel_clusters = q[:clusters] == 'none' ? [] : q[:clusters].split(',').map(&:to_i)

      rows.each do |row|
        eid, dist = row
        relevant = rel_clusters.include?(cluster_map[eid]) ? 1 : 0
        csv.puts "#{q[:id]},#{eid},#{dist},#{relevant}"
      end

      $stderr.puts "      #{rows.length} distances"
    end
  end

  # Analyze
  analyze_scale(db, csv_path, scale, queries)

  # Cleanup
  db.close
  FileUtils.rm_rf(dir)
end

# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def analyze_scale(db_unused, csv_path, scale, queries)
  adb = SQLite3::Database.new(':memory:')
  adb.execute('CREATE TABLE d (query_id TEXT, entry_id INTEGER, cosine_dist REAL, relevant INTEGER)')

  File.readlines(csv_path).drop(1).each do |line|
    parts = line.strip.split(',')
    adb.execute('INSERT INTO d VALUES (?,?,?,?)', [parts[0], parts[1].to_i, parts[2].to_f, parts[3].to_i])
  end

  $stderr.puts "\n  Scale #{scale} — Cosine Distance Summary"
  adb.execute(<<~SQL).each { |r| $stderr.puts "    #{r.join('  ')}" }
    SELECT CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END,
           COUNT(*), ROUND(MIN(cosine_dist),4), ROUND(AVG(cosine_dist),4), ROUND(MAX(cosine_dist),4)
    FROM d GROUP BY relevant ORDER BY relevant DESC
  SQL

  $stderr.puts "\n  Negative query nearest neighbor:"
  adb.execute(<<~SQL).each { |r| $stderr.puts "    #{r.join('  ')}" }
    SELECT query_id, ROUND(MIN(cosine_dist),4) FROM d
    WHERE query_id IN ('Q16','Q17','Q18','Q19','Q20')
    GROUP BY query_id ORDER BY query_id
  SQL

  $stderr.puts "\n  Threshold sweep:"
  $stderr.puts "    threshold  recall  precision  true_pos  false_pos"
  [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65].each do |t|
    row = adb.get_first_row(<<~SQL, [t, t, t, t, t])
      SELECT
        ROUND(CAST(SUM(CASE WHEN relevant=1 AND cosine_dist<=? THEN 1 ELSE 0 END) AS REAL) /
              NULLIF(SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END),0), 3),
        ROUND(CAST(SUM(CASE WHEN relevant=1 AND cosine_dist<=? THEN 1 ELSE 0 END) AS REAL) /
              NULLIF(SUM(CASE WHEN cosine_dist<=? THEN 1 ELSE 0 END),0), 3),
        SUM(CASE WHEN relevant=1 AND cosine_dist<=? THEN 1 ELSE 0 END),
        SUM(CASE WHEN relevant=0 AND cosine_dist<=? THEN 1 ELSE 0 END)
      FROM d
    SQL
    $stderr.puts "    #{t}      #{row.join('     ')}"
  end

  adb.close
end

# ---------------------------------------------------------------------------
# Cross-scale analysis
# ---------------------------------------------------------------------------

def cross_scale_analysis(scales)
  $stderr.puts "\n#{'=' * 40}"
  $stderr.puts "  Cross-Scale Analysis"
  $stderr.puts '=' * 40

  adb = SQLite3::Database.new(':memory:')
  adb.execute('CREATE TABLE d (scale INTEGER, query_id TEXT, entry_id INTEGER, cosine_dist REAL, relevant INTEGER)')

  scales.each do |s|
    csv = File.join(RESULTS_DIR, "distances-#{s}.csv")
    next unless File.exist?(csv)
    File.readlines(csv).drop(1).each do |line|
      parts = line.strip.split(',')
      adb.execute('INSERT INTO d VALUES (?,?,?,?,?)', [s, parts[0], parts[1].to_i, parts[2].to_f, parts[3].to_i])
    end
  end

  $stderr.puts "\n  Mean cosine by scale:"
  $stderr.puts "  scale  class        n       min     mean    max"
  adb.execute(<<~SQL).each { |r| $stderr.puts "  #{r.join('  ')}" }
    SELECT scale, CASE WHEN relevant=1 THEN 'relevant' ELSE 'irrelevant' END,
           COUNT(*), ROUND(MIN(cosine_dist),4), ROUND(AVG(cosine_dist),4), ROUND(MAX(cosine_dist),4)
    FROM d GROUP BY scale, relevant ORDER BY scale, relevant DESC
  SQL

  $stderr.puts "\n  Negative query nearest neighbor by scale:"
  adb.execute(<<~SQL).each { |r| $stderr.puts "  #{r.join('  ')}" }
    SELECT scale, query_id, ROUND(MIN(cosine_dist),4) FROM d
    WHERE query_id IN ('Q16','Q17','Q18','Q19','Q20')
    GROUP BY scale, query_id ORDER BY scale, query_id
  SQL

  $stderr.puts "\n  Recall at 0.50 cosine threshold by scale:"
  adb.execute(<<~SQL).each { |r| $stderr.puts "  #{r.join('  ')}" }
    SELECT scale,
           SUM(CASE WHEN relevant=1 AND cosine_dist<=0.50 THEN 1 ELSE 0 END) as tp,
           SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END) as total_rel,
           ROUND(CAST(SUM(CASE WHEN relevant=1 AND cosine_dist<=0.50 THEN 1 ELSE 0 END) AS REAL) /
                 NULLIF(SUM(CASE WHEN relevant=1 THEN 1 ELSE 0 END),0), 3) as recall,
           SUM(CASE WHEN relevant=0 AND cosine_dist<=0.50 THEN 1 ELSE 0 END) as fp
    FROM d GROUP BY scale ORDER BY scale
  SQL

  # Save to file
  analysis_path = File.join(RESULTS_DIR, 'analysis.txt')
  File.write(analysis_path, "Cross-scale analysis saved at #{Time.now.utc}\nSee CSV files for raw data.\n")

  adb.close
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$stderr.puts "=== Sensitivity Experiment ==="
$stderr.puts "Scales: #{SCALES.join(', ')}"
$stderr.puts "Embedding: #{EMBEDDING_MODEL}"
$stderr.puts "Generation: #{GENERATION_MODEL}"

start = Time.now

SCALES.each do |scale|
  t = Time.now
  run_scale(scale)
  $stderr.puts "\n  Scale #{scale} completed in #{(Time.now - t).round(0)}s"
end

cross_scale_analysis(SCALES)

$stderr.puts "\n=== Done (#{(Time.now - start).round(0)}s) ==="
$stderr.puts "Results in #{RESULTS_DIR}/"
