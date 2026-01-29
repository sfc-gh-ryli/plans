# Implementation Plan: Fix Jira Reproducibility for Restarting/Multistage Tests

## Problem Summary

Two issues make correctness failures difficult to reproduce from Jira tickets:

1. **Missing `--restarting` flag**: Only phase 2 tests get `--restarting`, but phases 3+ also need it
2. **Incomplete command generation for 3+ phase tests**: Jira creation only handles 2-phase tests, not 3+ phase multistage tests

## Root Causes

### Location 1: `frostdb/contrib/TestHarness2/test_harness/joshua.py:58-59`

```python
if re.search(r"restarting\/.*-2\.", file_name):
    cmd += ["--restarting"]
```

**Problem**: Regex only matches `-2.` pattern, missing `-3.`, `-4.`, etc.

### Location 2: `fdb_snowflake/joshua/joshua_jira.py:90-117`

```python
if re.search(r"restarting.*-2", data["TEST_FILE"]):
    # Only fetches -1 test data
    restart_testfile_1 = re.sub(re.escape("-2."), "-1.", data["TEST_FILE"])
    ...
```

**Problem**: Only handles 2-phase tests. For a failure in phase 3, we need Commands 1, 2, and 3.

## Implementation Plan

### Step 1: Fix `joshua.py` (frostdb) - Add `--restarting` for all phases > 1

**File**: `frostdb/contrib/TestHarness2/test_harness/joshua.py`

**Current code** (line 58-59):
```python
if re.search(r"restarting\/.*-2\.", file_name):
    cmd += ["--restarting"]
```

**New code**:
```python
# Match any restarting test file that is not phase 1 (i.e., -2, -3, -4, etc.)
if re.search(r"restarting\/.*-[2-9]\d*\.", file_name):
    cmd += ["--restarting"]
```

**Rationale**: The pattern `-[2-9]\d*\.` matches:
- `-2.` (phase 2)
- `-3.` (phase 3)
- `-10.` (phase 10, if ever needed)
- Does NOT match `-1.` (phase 1)

### Step 2: Fix `joshua_jira.py` - Handle multistage tests with 3+ phases

**File**: `fdb_snowflake/joshua/joshua_jira.py`

#### Step 2a: Refactor `get_test_error_details()` to handle N phases

**Current logic** (lines 89-117):
- Only checks for `-2` pattern
- Only fetches `-1` test data
- Creates Command 1 and Command 2

**New logic**:
1. Detect if test is a restarting test and extract phase number
2. For N-phase test (failing at phase N):
   - Generate Command 1 through Command N
   - Fetch TESTHARNESS_RESULTS for phases 1 through N
   - Apply OldBinary from each phase's results
   - Add `--restarting` for phases 2+

**Proposed implementation**:

```python
def get_test_error_details(data: Dict[str, str]) -> Dict[str, str]:
    """Get required details of test failure to be posted in JIRA."""
    command = ["devRetryCorrectnessTest"]
    test_dict: Dict[str, str] = {}
    th_log = json.loads(data["TESTHARNESS_RESULTS"])
    ensemble_id = data["ENSEMBLE_ID"]
    test_file = data["TEST_FILE"]

    test_dict["BuggifyEnabled"] = "on" if th_log["BuggifyEnabled"] == "1" else "off"
    test_dict["RandomSeed"] = data["RANDOM_SEED"]
    test_dict["TestError"] = ""
    test_dict["AssertFailure"] = ""
    test_dict["Reason"] = ""

    # Parse errors (unchanged)
    if "Errors" in th_log and len(th_log["Errors"]) > 0:
        first_error = th_log["Errors"][0]
        test_dict["TestError"] = first_error["Type"]
        if test_dict["TestError"] == "InternalError" and "FailedAssertion" in first_error:
            test_dict["AssertFailure"] = first_error["FailedAssertion"]
        for f in reason_fields:
            if f in first_error:
                test_dict["Reason"] = first_error[f]
                break

    # Build base command (unchanged)
    filter_options = ["--xml", "--xml-file", "-q"]
    testfile = "tests/" + test_file
    for k in th_log["Command"].split(" "):
        if k in filter_options or k.startswith(tuple(filter_options)):
            continue
        command.append(testfile) if testfile in k else command.append(k)
    full_command = " ".join(command)
    test_dict["Command"] = fix_command_paths(full_command)

    # Check if this is a restarting test and get phase number
    phase_match = re.search(r"restarting.*-(\d+)\.(txt|toml)", test_file)
    if phase_match:
        current_phase = int(phase_match.group(1))

        if current_phase > 1:
            # This is a multi-phase test - generate commands for all phases
            commands = {}

            # Fetch data for all phases from 1 to current_phase
            for phase in range(1, current_phase + 1):
                phase_testfile = re.sub(r"-\d+\.(txt|toml)", f"-{phase}.{phase_match.group(2)}", test_file)

                if phase == current_phase:
                    # Use current test's data
                    phase_th_log = th_log
                    phase_data = data
                else:
                    # Fetch data for prior phase
                    phase_data = get_errorlogs_data(ensemble_id, phase_testfile, data.get("TEST_UID"))
                    if phase_data is None:
                        # Fallback: try without TEST_UID
                        phase_data = get_errorlogs_data(ensemble_id, phase_testfile)
                    if phase_data and "TESTHARNESS_RESULTS" in phase_data:
                        phase_th_log = json.loads(phase_data["TESTHARNESS_RESULTS"])
                    else:
                        # Can't fetch data for this phase, construct basic command
                        phase_th_log = {}

                # Build command for this phase
                phase_command = "devRetryCorrectnessTest " + fix_command_paths(
                    phase_th_log.get("Command", f"bin/fdbserver ... tests/{phase_testfile}")
                )

                # Apply OldBinary if present
                if "OldBinary" in phase_th_log:
                    old_binary = "bin/" + phase_th_log["OldBinary"]
                    phase_command = re.sub(
                        r"bin/fdbserver(?:-\d+\.\d+\.\d+(?:-\w+\d*)?)?",
                        old_binary,
                        phase_command,
                    )

                # Add --restarting for phases > 1 if not already present
                if phase > 1 and "--restarting" not in phase_command:
                    # Insert --restarting after the test file argument
                    phase_command = add_restarting_flag(phase_command)

                commands[f"Command {phase}"] = phase_command

            # Replace single Command with numbered commands
            del test_dict["Command"]
            test_dict.update(commands)

    test_dict["JoshuaRun"] = ensemble_id
    test_dict["TestOutput"] = f"aws s3 ls {JOSHUA_TEST_OUTPUT_S3_URL}/{ensemble_id}/"

    return test_dict


def add_restarting_flag(command: str) -> str:
    """Add --restarting flag to command if not present.

    Inserts after the test file path (.txt or .toml) to maintain argument order.
    """
    if "--restarting" in command:
        return command

    # Insert --restarting after the test file argument
    # Pattern matches .txt or .toml followed by space or end
    return re.sub(
        r"(\.(?:txt|toml))(\s|$)",
        r"\1 --restarting\2",
        command,
        count=1
    )
```

#### Step 2b: Update Jira filing logic to handle 3+ phase test filtering

**Current logic** (lines 382-385):
```python
# Only files Jira for -2 tests, skips -1 tests
match = re.search("restarting(.*)-1.toml", test["test_file"])
if match and match.group(1) + "-2" in all_test_names:
    continue
```

**New logic**:
- Skip any intermediate phase if a later phase exists
- Only file Jira for the final/failing phase

```python
# For restarting tests, only file Jira for the highest phase that failed
# Skip phase N if phase N+1 exists in the failure list
match = re.search(r"restarting(.*)-(\d+)\.(txt|toml)", test["test_file"])
if match:
    test_base = match.group(1)
    phase_num = int(match.group(2))
    ext = match.group(3)
    # Check if next phase exists
    next_phase_pattern = f"restarting{test_base}-{phase_num + 1}"
    if any(next_phase_pattern in t for t in all_test_names):
        continue
```

### Step 3: Testing

Since there's no local testing environment, verify by:

1. **Code review**: Ensure regex patterns are correct
2. **Dry run**: Use `--dry-run` flag on `joshua_jira.py` with a known multistage failure ensemble
3. **Manual verification**: After deployment, check a Jira created from a 3-phase test failure

### Files to Modify

| File | Change |
|------|--------|
| `frostdb/contrib/TestHarness2/test_harness/joshua.py` | Fix regex at line 58 |
| `fdb_snowflake/joshua/joshua_jira.py` | Refactor `get_test_error_details()` lines 89-117, update filtering logic lines 382-385 |

### Expected Output Example

For a 3-phase test failing at phase 3:

**Before (broken)**:
```
Command 1: devRetryCorrectnessTest bin/fdbserver ...MetaclusterTest-1.toml...
Command 2: devRetryCorrectnessTest bin/fdbserver ...MetaclusterTest-2.toml... --restarting
```
(Missing Command 3, Command 3 was previously labeled as Command 2)

**After (fixed)**:
```
Command 1: devRetryCorrectnessTest bin/fdbserver-7.1.4 ...MetaclusterTest-1.toml...
Command 2: devRetryCorrectnessTest bin/fdbserver-24.0.3 ...MetaclusterTest-2.toml... --restarting
Command 3: devRetryCorrectnessTest bin/fdbserver ...MetaclusterTest-3.toml... --restarting
```

## Data Availability Analysis

**Key insight from `snowhouse_ingest.py`**: When a test fails at phase N, ALL phases' outputs are processed together with the same failing result_code. This means:

- Phase 1's `<Test>` → added to ERROR_LOGS (even though phase 1 "passed")
- Phase 2's `<Test>` → added to ERROR_LOGS
- Phase N's `<Test>` → added to ERROR_LOGS

Therefore, we CAN fetch prior phases' data using `get_errorlogs_data()` - the same approach used for 2-phase tests will work for 3+ phases.

## Risks and Considerations

1. **Data availability**: ✅ Confirmed - prior phases ARE available in ERROR_LOGS (see analysis above)
2. **Binary name accuracy**: The `OldBinary` field in TESTHARNESS_RESULTS is the source of truth - this should be reliable.
3. **Backward compatibility**: Existing 2-phase tests will continue to work with the new logic.
