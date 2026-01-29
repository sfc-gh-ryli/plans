# Improve reproducibility of correctness failures via restarting and multistage test Jiras

## Context 

For context, I will be speaking about tests in the context of simulation correctness tests, colloquially known as Joshua tests. Essentially, Joshua is a system with the capability to run ensembles of correctness tests. For correctness tests, Joshua runs the test_harness found in frostdb/, though the majority of the actual Joshua system code is written in fdb_snowflake/joshua and it does not have awareness of what it is even running.

Ensembles are processed by an always-on Jenkins job called the FDB_joshua_monitor. This Jenkins job essentially runs a script slack_update.py on a regular cycle. This script checks for completed ensembles and "processes" them, looking for test failures, ingesting ensemble information to Snowhouse, and creating Jiras for failures if needed. The Jiras contain many pieces of information that should help the developer reading the Jira debug.

## The task

There are some problems with specific types of tests (multistage and restarting) which make them difficult to reproduce. For this task, you will have to look deeper into code to understand what multistage and restarting tests do, or at least how they're treated by Joshua post-processing jobs like the monitor. 

From what we know, there are two main problems:

1. Restarting tests should have the --restarting argument in the repro command. If I were to start somewhere to look into this, I would check frostdb/contrib/TestHarness2/test_harness/joshua.py at line 58 and learn how the pieces all interact. 
2. Sometimes, tests have the wrong fdbserver binary name. When there are multiple commands, the commands can't all run with the same fdbserver binary. The last command runs with the current fdbserver, and the older commands each run with different older fdbserver binaries with suffixes. More details in examples. This already usually happens, but may fail for some reason (perhaps in 3+ phase tests).


### Misc advice from team members

In response to two threads where people reported issues reproducing failures from a Jira:

- So, all stages that are not the first one need to have a --restarting flag, which basically tells fdbserver to not clear files at startup, allowing it to pick up the data from the prior runs and keep using it.
  - The multistage one in Brian's final message was missing a --restarting.
  - The logic used in testharness2 is just count != 0.
- and then there was also the issue of the binary extracted being wrong
  - in Thomas's thread, the second command was supposed to have something other than bin/fdbserver
  - it looks like in Brian's thread it also got the binary wrong for phase 1

### Examples
For a multistage failure Jira, the description says this:

BuggifyEnabled: on
RandomSeed: 2099992186
TestError: UnhandledErrorInRunWorkload
AssertFailure: 
Reason: The cluster is being removed from the metacluster
Command 1: devGit checkout 238710a502c2a86c7e94becc436f314f91e3a021 && devProfile cloudWSArm prerelease && devRetryCorrectnessTest bin/fdbserver-25.3.1 -r simulation -f tests/restarting/multistage/from_25.3.0_until_25.4.0/MetaclusterManagementConcurrencyRestart-1.toml -s 2099992185 --trace_format json -fi on --crash
Command 2: devGit checkout 238710a502c2a86c7e94becc436f314f91e3a021 && devProfile cloudWSArm prerelease && devRetryCorrectnessTest bin/fdbserver -r simulation -f tests/restarting/multistage/from_25.3.0_until_25.4.0/MetaclusterManagementConcurrencyRestart-2.toml -s 2099992186 --trace_format json -fi on --restarting -b on --crash
JoshuaRun: 20260106-044636-nightly_correctness_main_aarch64-1febeaf37f522914
TestOutput: aws s3 ls s3://sfc-eng-jenkins/foundationdb/test-outputs/20260106-044636-nightly_correctness_main_aarch64-1febeaf37f522914/
TestType: correctness
Profile: prerelease
Count: 1
Commit: 238710a502c2a86c7e94becc436f314f91e3a021
Branch: main

See that command 1 has bin/fdbserver-25.3.1. This is important. Only the last command should have the current bin/fdbserver (without suffix). Occasionally that fails (maybe for failures with 3+ stages?).

Command 1: devRetryCorrectnessTest bin/fdbserver-7.1.4 -r simulation -f tests/restarting/multistage/from_6.3.13_until_71.2.0/ClientTransactionProfilingCorrectness-1.txt -s 766102510 -b on --crash --trace_format json
Command 2: devRetryCorrectnessTest bin/fdbserver-24.0.3 -r simulation -f tests/restarting/multistage/from_6.3.13_until_71.2.0/ClientTransactionProfilingCorrectness-2.txt --restarting -s 766102511 -b off --crash --trace_format json
Command 3: devRetryCorrectnessTest bin/fdbserver -r simulation -f tests/restarting/multistage/from_6.3.13_until_71.2.0/ClientTransactionProfilingCorrectness-3.txt -s 766102512 -b off --crash --trace_format json

Command 3 is missing --restarting