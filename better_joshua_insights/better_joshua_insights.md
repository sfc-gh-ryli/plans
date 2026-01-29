# Better Joshua Insights

## Overview

Extend Joshua data ingestion into Snowhouse to capture per-test-run information, enabling detailed analytics on test performance, distribution, and failure patterns.

**What stays the same:**
- `ENSEMBLES` table (aggregate stats, ensemble properties)
- `ERROR_LOGS` table (detailed failure information)
- Existing ingestion flow for these tables

**What's new:**
- `TEST_RUNS` table - individual test run data for ALL tests
- `BUGGIFIED_KNOBS` table - knob values used per test
- `BUGGIFIED_LINES` table - code lines affected by buggify per test

---

## New Tables

### 1. TEST_RUNS

Store individual test run records with key metrics:

```sql
CREATE TABLE TEST_RUNS (
    test_uid VARCHAR(64) NOT NULL,           -- TestUID from XML
    ensemble_id VARCHAR(256) NOT NULL,       -- Parent ensemble
    test_file VARCHAR(512) NOT NULL,         -- TestFile path
    test_group VARCHAR(128),                 -- TestGroup
    test_priority FLOAT,                     -- TestPriority

    -- Timing
    start_time BIGINT,                       -- Time (Unix timestamp)
    real_elapsed_time FLOAT,                 -- RealElapsedTime (wall-clock seconds, internal measurement)
    sim_elapsed_time FLOAT,                  -- SimElapsedTime (simulated seconds, only meaningful for simulation tests)
    runtime FLOAT,                           -- Runtime (wall-clock seconds, external measurement by TestHarness)

    -- Result
    result_code INTEGER NOT NULL,            -- Ok field (0=fail, 1=pass)

    -- Configuration
    buggify_enabled BOOLEAN,                 -- BuggifyEnabled
    negative_test BOOLEAN,                   -- NegativeTest (expected to fail)

    -- Resources
    peak_memory BIGINT,                      -- PeakMemory (bytes)
    cpu_time FLOAT,                          -- CPUTime (user + system CPU seconds)

    -- Debug
    command VARCHAR(4096),                   -- Full command line

    -- Metadata
    ingested_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),

    PRIMARY KEY (test_uid)
);
```

**Field mapping from XML:**
| Table Column | XML Attribute | Example |
|--------------|---------------|---------|
| test_uid | TestUID | `5fb023bb-3ba6-430f-8744-56c960166381` |
| test_file | TestFile | `tests/rare/TomlKnobApplication.toml` |
| test_group | TestGroup | `TomlKnobApplication` |
| test_priority | TestPriority | `1000.0` |
| start_time | Time | `1769489830` |
| real_elapsed_time | RealElapsedTime | `45.272583` |
| sim_elapsed_time | SimElapsedTime | `1500.0` |
| runtime | Runtime | `45.891234` |
| result_code | Ok | `1` |
| buggify_enabled | BuggifyEnabled | `1` |
| negative_test | NegativeTest | `0` |
| peak_memory | PeakMemory | `168692` |
| cpu_time | CPUTime | `12.345` |
| command | Command | `bin/fdbserver -r simulation...` |

### Time Field Deep Dive

Joshua/TestHarness outputs several time-related fields from different sources. Understanding these is crucial for accurate analytics:

| Field | Source | Description | Always Present? |
|-------|--------|-------------|-----------------|
| **Time** | fdbserver `ProgramStart` trace event's `ActualTime` | Unix timestamp (seconds since epoch) when test started | Yes |
| **RealElapsedTime** | fdbserver `ElapsedTime` trace event's `RealTime` | Wall-clock seconds elapsed during test (`timer() - start`) | Only if test completes normally |
| **SimElapsedTime** | fdbserver `ElapsedTime` trace event's `SimTime` | Simulated time elapsed (`now() - simStartTime`); only meaningful for simulation tests | Only if test completes normally |
| **Runtime** | TestHarness `ResourceMonitor.time()` | Wall-clock seconds of subprocess execution (external measurement) | Yes |
| **TotalTestTime** | `TestDescription.total_runtime` | **Cumulative** runtime of ALL runs of this test class in the ensemble (not per-test!) | Yes |
| **CPUTime** | TestHarness `ResourceMonitor` via `resource.getrusage(RUSAGE_CHILDREN)` | CPU time (user + system) consumed by test process | Yes |
| **ElleRuntime** | TestHarness `ResourceMonitor` for Elle checker | Wall-clock time spent running Elle consistency checker | Yes (defaults to 0 if Elle not used) |

**Key distinctions:**
1. **RealElapsedTime** vs **Runtime**: Both measure wall-clock time, but from different perspectives:
   - `RealElapsedTime` is measured *inside* fdbserver and written to traces before exit
   - `Runtime` is measured *outside* by TestHarness (process start to process exit)
   - If a test crashes before writing `ElapsedTime`, only `Runtime` will be available

2. **SimElapsedTime**: Only meaningful for simulation tests (`-r simulation`). For real cluster tests (`-r test`), this value is meaningless.

3. **TotalTestTime**: This is an **aggregate field** tracking ensemble-wide statistics, NOT the duration of this specific test run. It's useful for understanding test scheduling but NOT for per-test duration analysis.

4. **CPUTime**: Useful for identifying CPU-bound tests. A test with high `Runtime` but low `CPUTime` is likely I/O bound or waiting.

**Recommendation for TEST_RUNS table:**
- Use `Time` as `start_time` (Unix timestamp)
- Store all three time measurements: `RealElapsedTime`, `SimElapsedTime`, `Runtime`
- For duration analysis, prefer `real_elapsed_time` (more accurate), fall back to `runtime` if NULL
- Compute `finish_time` in queries as `start_time + COALESCE(real_elapsed_time, runtime)`
- Store `CPUTime` for resource analysis (CPU-bound vs I/O-bound tests)
- Do NOT use `TotalTestTime` for per-test duration (it's an ensemble aggregate)

### 2. BUGGIFIED_KNOBS

Store the knob values set by buggify for each test:

```sql
CREATE TABLE BUGGIFIED_KNOBS (
    test_uid VARCHAR(64) NOT NULL,           -- Foreign key to TEST_RUNS
    knob VARCHAR(256) NOT NULL,              -- Knob name
    value VARCHAR(256),                      -- Knob value

    PRIMARY KEY (test_uid, knob),
    FOREIGN KEY (test_uid) REFERENCES TEST_RUNS(test_uid)
);
```

**Parsed from XML:**
```xml
<BuggifiedKnob Name="byte_sample_start_delay" Value="0"/>
<BuggifiedKnob Name="spring_cleaning_vacuums_per_lazy_delete_page" Value="0.019196"/>
```

### 3. BUGGIFIED_LINES

Store the code lines affected by buggify for each test:

```sql
CREATE TABLE BUGGIFIED_LINES (
    test_uid VARCHAR(64) NOT NULL,           -- Foreign key to TEST_RUNS
    file VARCHAR(512) NOT NULL,              -- Source file path
    line INTEGER NOT NULL,                   -- Line number

    PRIMARY KEY (test_uid, file, line),
    FOREIGN KEY (test_uid) REFERENCES TEST_RUNS(test_uid)
);
```

**Parsed from XML:**
```xml
<BuggifiedSection File="fdbrpc/FlowTransport.actor.cpp" Line="1234"/>
```

---

## ENSEMBLES Table Extensions

The existing `ENSEMBLES` table captures basic ensemble metadata, but several useful fields are **not persisted** (lost after run completes):

| Field | Source | How to Capture |
|-------|--------|----------------|
| `sanitizer` | Inferred from username or binary path | Requires `joshua start` flag or env var |
| `valgrind` | TestHarness `--use-valgrind` | Requires `joshua start` flag or env var |
| `include_test_files` | TestHarness `--include-test-files` | Requires `joshua start` flag or env var |
| `exclude_test_files` | TestHarness `--exclude-test-files` | Requires `joshua start` flag or env var |
| `kill_seconds` | TestHarness `--kill-seconds` | Requires `joshua start` flag or env var |
| `buggify_on_ratio` | TestHarness buggify config | Requires `joshua start` flag or env var |

**Note:** `binary_version` is available per-test via `SourceVersion` in the test output XML if needed in the future.

### Proposed Schema Extension

```sql
ALTER TABLE ENSEMBLES ADD COLUMN sanitizer VARCHAR(16);           -- 'asan', 'ubsan', 'tsan', 'none'
ALTER TABLE ENSEMBLES ADD COLUMN valgrind BOOLEAN;
ALTER TABLE ENSEMBLES ADD COLUMN include_test_files VARCHAR(2048);
ALTER TABLE ENSEMBLES ADD COLUMN exclude_test_files VARCHAR(2048);
ALTER TABLE ENSEMBLES ADD COLUMN kill_seconds INTEGER;
ALTER TABLE ENSEMBLES ADD COLUMN buggify_on_ratio FLOAT;
```

### Implementation (DONE)

**The persistence mechanism already exists!** Joshua's `--property` flag stores key-value pairs in the FDB cluster.

**Changes made:**

1. **`fdbdev/fdbdev.rc`** - `devRunCorrectness` now passes:
   ```bash
   --property sanitizer="$sanitizer"      # Detected from bazel config (asan/tsan/ubsan/none)
   --property valgrind="$isValgrind"      # Detected from FDBDEV_CORRECTNESS_PREFIX
   --property include_test_files="..."    # From @+ argument
   --property exclude_test_files="..."    # From @- argument
   ```

2. **`jenkins_utils/.../fdb_joshua_proxy.groovy`** - Jenkins pipeline now passes:
   ```groovy
   --property sanitizer=${sanitizer}      // Inferred from PACKAGE_TYPE
   --property valgrind=${isValgrind}      // True if PACKAGE_TYPE == 'valgrind'
   --property kill_seconds=${params.KILL_SECONDS}
   --property package_type=${params.PACKAGE_TYPE}
   ```

3. **`snowhouse_ingest.py`** - Reads properties and INSERTs into new ENSEMBLES columns.

4. **`migrations/add_ensembles_testharness_config.sql`** - DDL to add columns.

**How it works:**
1. `joshua start --property key=value` stores in FDB via `joshua_model.create_ensemble()`
2. Properties retrieved later via `joshua_model.get_ensemble_properties(ensemble_id)`
3. `snowhouse_ingest.py` reads properties and populates ENSEMBLES table

**No changes needed to:** `joshua_agent.py`, `joshua_model.py`, or the FDB schema.

---

## Data Volume

- Ensembles range from **10K to 7M test runs**
- Each test can have **50-100 buggified knobs**
- Each test can have **10-50 buggified lines**

For a 100K test ensemble:
- TEST_RUNS: ~100K rows
- BUGGIFIED_KNOBS: ~5-10M rows
- BUGGIFIED_LINES: ~1-5M rows

---

## Implementation Approach

### Bulk Loading with `write_pandas`

Use Snowflake's `write_pandas()` function:
- Converts DataFrame to Parquet format
- Stages data efficiently
- Executes `COPY INTO` for bulk insertion
- Recommended for 5K-3M row batches

### Chunked Pipeline Architecture

Process and write in chunks to bound memory:

```
┌─────────────┐     ┌─────────────────┐     ┌──────────────┐
│ FDB Read    │────▶│ ProcessPool     │────▶│ Chunk Buffer │
│ (streaming) │     │ XML Parsing     │     │ (50K rows)   │
└─────────────┘     └─────────────────┘     └──────┬───────┘
                                                   │
                                                   ▼ (when full)
                                            ┌──────────────┐
                                            │ write_pandas │
                                            │ to Snowflake │
                                            └──────────────┘
```

### Keep Multiprocessing for XML Parsing

Benchmark results confirm **5.14x speedup** with `ProcessPoolExecutor`:

| Approach | 112K Records | Rate |
|----------|--------------|------|
| Sequential | 121.6s | 924 rec/s |
| **Multiprocessing** | **23.6s** | **4756 rec/s** |
| Threading | 129.1s | 870 rec/s |

---

## Implementation Steps

### Step 1: Add Dependencies

Update `joshua_slack_report_requirements.txt`:

```
pyarrow>=12.0.0        # NEW - required for write_pandas
```

### Step 2: Create Tables in Snowhouse

Execute DDL in Snowflake (database: `eng_fdb`, schema: `joshua`).

### Step 3: Modify XML Parser

Update `process_output()` to return structured data for all three tables:

```python
def process_test_run(output, ensemble_id):
    """
    Parse XML and return data for TEST_RUNS, BUGGIFIED_KNOBS, BUGGIFIED_LINES.
    Returns (test_run_row, knob_rows, line_rows) or (None, [], []) on failure.
    """
    log_json = parse_xml_to_json(output)
    if not log_json or "Test" not in log_json:
        return None, [], []

    test = log_json["Test"]
    test_uid = test.get("TestUID")
    if not test_uid:
        return None, [], []

    # TEST_RUNS row
    test_run = {
        'test_uid': test_uid,
        'ensemble_id': ensemble_id,
        'test_file': test.get("TestFile"),
        'test_group': test.get("TestGroup"),
        'test_priority': float(test.get("TestPriority", 0)) or None,
        'start_time': int(test.get("Time", 0)) or None,
        'real_elapsed_time': float(test.get("RealElapsedTime", 0)) or None,
        'sim_elapsed_time': float(test.get("SimElapsedTime", 0)) or None,
        'runtime': float(test.get("Runtime", 0)) or None,
        'result_code': int(test.get("Ok", 0)),
        'buggify_enabled': test.get("BuggifyEnabled") == "1",
        'negative_test': test.get("NegativeTest") == "1",
        'peak_memory': int(test.get("PeakMemory", 0)) or None,
        'cpu_time': float(test.get("CPUTime", 0)) or None,
        'command': test.get("Command"),
    }

    # BUGGIFIED_KNOBS rows
    knob_rows = []
    for knob in test.get("BuggifiedKnob", []):
        knob_rows.append({
            'test_uid': test_uid,
            'knob': knob.get("Name"),
            'value': knob.get("Value"),
        })

    # BUGGIFIED_LINES rows
    line_rows = []
    for section in test.get("BuggifiedSection", []):
        line_rows.append({
            'test_uid': test_uid,
            'file': section.get("File"),
            'line': int(section.get("Line", 0)),
        })

    return test_run, knob_rows, line_rows
```

### Step 4: Implement Chunked Ingestion

```python
CHUNK_SIZE = 50_000

def ingest_test_runs(ensemble_id, conn):
    """
    Ingest TEST_RUNS, BUGGIFIED_KNOBS, BUGGIFIED_LINES using chunked write_pandas.
    """
    test_runs = []
    knobs = []
    lines = []

    with ProcessPoolExecutor() as executor:
        futures = {}

        for rec in joshua_model.tail_results(ensemble_id, errors_only=False):
            # Extract output from record
            output = extract_output(rec)
            if output and "<Test" in output:
                future = executor.submit(process_test_run, output, ensemble_id)
                futures[future] = True

        for future in as_completed(futures):
            test_run, knob_rows, line_rows = future.result()
            if test_run:
                test_runs.append(test_run)
                knobs.extend(knob_rows)
                lines.extend(line_rows)

            # Flush TEST_RUNS when chunk full
            if len(test_runs) >= CHUNK_SIZE:
                write_pandas(conn, pd.DataFrame(test_runs), 'TEST_RUNS')
                test_runs = []

            # Flush BUGGIFIED_KNOBS when chunk full
            if len(knobs) >= CHUNK_SIZE:
                write_pandas(conn, pd.DataFrame(knobs), 'BUGGIFIED_KNOBS')
                knobs = []

            # Flush BUGGIFIED_LINES when chunk full
            if len(lines) >= CHUNK_SIZE:
                write_pandas(conn, pd.DataFrame(lines), 'BUGGIFIED_LINES')
                lines = []

        # Flush remaining
        if test_runs:
            write_pandas(conn, pd.DataFrame(test_runs), 'TEST_RUNS')
        if knobs:
            write_pandas(conn, pd.DataFrame(knobs), 'BUGGIFIED_KNOBS')
        if lines:
            write_pandas(conn, pd.DataFrame(lines), 'BUGGIFIED_LINES')
```

### Step 5: Integrate with Existing Flow

Modify `ingest_to_snowhouse()` to call the new ingestion **after** existing ENSEMBLES and ERROR_LOGS ingestion:

```python
def ingest_to_snowhouse(ensemble_id, conn):
    # EXISTING: Ingest ensemble summary → ENSEMBLES table
    # EXISTING: Ingest error logs → ERROR_LOGS table
    # ... existing code unchanged ...

    # NEW: Ingest individual test runs
    ingest_test_runs(ensemble_id, conn)
```

---

## Design Decisions

1. **Retention policy**: Keep data indefinitely. No retention limit.
2. **Partitioning**: Standard tables without date partitioning.
3. **Error handling**: Fail loudly (log errors) but continue processing remaining chunks.
4. **Existing tables**: ERROR_LOGS and ENSEMBLES ingestion remains unchanged.

---

## Example Queries

### Test Duration by Group
```sql
SELECT
    test_group,
    COUNT(*) as runs,
    AVG(COALESCE(real_elapsed_time, runtime)) as avg_duration,
    MAX(COALESCE(real_elapsed_time, runtime)) as max_duration
FROM TEST_RUNS
WHERE ensemble_id = 'xxx'
GROUP BY test_group
ORDER BY avg_duration DESC;
```

### Most Commonly Buggified Knobs in Failures
```sql
SELECT
    k.knob,
    COUNT(*) as failure_count
FROM BUGGIFIED_KNOBS k
JOIN TEST_RUNS t ON k.test_uid = t.test_uid
WHERE t.result_code = 0
GROUP BY k.knob
ORDER BY failure_count DESC
LIMIT 20;
```

### Buggified Lines Correlated with Failures
```sql
SELECT
    l.file,
    l.line,
    COUNT(*) as failure_count
FROM BUGGIFIED_LINES l
JOIN TEST_RUNS t ON l.test_uid = t.test_uid
WHERE t.result_code = 0
GROUP BY l.file, l.line
ORDER BY failure_count DESC
LIMIT 20;
```

### Memory Usage Trends
```sql
SELECT
    DATE_TRUNC('day', ingested_at) as day,
    test_group,
    AVG(peak_memory) / 1e6 as avg_memory_mb
FROM TEST_RUNS
GROUP BY day, test_group
ORDER BY day;
```

### Failure Rate by Sanitizer
```sql
SELECT
    sanitizer,
    COUNT(*) as ensembles,
    AVG(num_fail / NULLIF(num_pass + num_fail, 0)) as failure_rate
FROM ENSEMBLES
WHERE sanitizer IS NOT NULL
GROUP BY sanitizer;
```

### Slowest Tests by Configuration
```sql
SELECT
    e.sanitizer,
    e.valgrind,
    t.test_group,
    AVG(COALESCE(t.real_elapsed_time, t.runtime)) as avg_duration
FROM TEST_RUNS t
JOIN ENSEMBLES e ON t.ensemble_id = e.ensemble_id
GROUP BY e.sanitizer, e.valgrind, t.test_group
ORDER BY avg_duration DESC;
```

---

## Files to Modify

### ENSEMBLES Extensions (DONE)

| File | Changes | Status |
|------|---------|--------|
| `migrations/add_ensembles_testharness_config.sql` | DDL for new columns | **Done** |
| `snowhouse_ingest.py` | Read properties, extend ENSEMBLES INSERT | **Done** |
| `fdbdev/fdbdev.rc` | Pass sanitizer, valgrind, include/exclude_test_files as properties in `devRunCorrectness` | **Done** |
| `jenkins_utils/.../fdb_joshua_proxy.groovy` | Pass sanitizer, valgrind, kill_seconds, package_type as properties | **Done** |

### TEST_RUNS / BUGGIFIED_* Tables (TODO)

| File | Changes | Status |
|------|---------|--------|
| `joshua_slack_report_requirements.txt` | Add `pyarrow>=12.0.0` | Pending |
| `snowhouse_ingest.py` | Add `process_test_run()`, `ingest_test_runs()` | Pending |
| DDL script | Create TEST_RUNS, BUGGIFIED_KNOBS, BUGGIFIED_LINES tables | Pending |

---

## Testing

1. **Unit tests**: Parse sample XML, verify all three table outputs
2. **Integration**: Ingest small ensemble, verify data in Snowflake
3. **Performance**: Benchmark with 87K and 650K record ensembles

### ENSEMBLES Extension Testing

To test the new ENSEMBLES columns:

```bash
# 1. Run the migration in Snowflake
snowsql -f migrations/add_ensembles_testharness_config.sql

# 2. Start an ensemble with properties
joshua start my_tarball.tar.gz \
    --property sanitizer=asan \
    --property valgrind=false \
    --property kill_seconds=900

# 3. After ensemble completes, ingest to Snowhouse
python snowhouse_ingest.py ingest --id <ensemble_id>

# 4. Verify in Snowflake
SELECT ensemble_id, sanitizer, valgrind, kill_seconds
FROM JOSHUA.ENSEMBLES
WHERE ensemble_id = '<ensemble_id>';
```
