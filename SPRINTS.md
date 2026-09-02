# dehoard completion plan

Baseline: 8158f27, 175 assertions + 12 stress, CI green, v0.2.8 shipped.
Rule for every task: implement, then verify by NEGATIVE CONTROL (break it, watch the test go red).

## Sprint 1 - make the suite trustworthy (blocks everything else)
S1.1  cut the 200 MB `dd` fixture to 5 MB; assert on threshold logic, not real bulk
S1.2  find remaining slow tests; replace real bulk with sparse files (mkfile -n)
S1.3  target: full suite < 3 min, run clean locally end to end
S1.4  re-run all negative controls once suite is fast enough to iterate

## Sprint 2 - correctness debt
S2.1  C4 sizing deadline, re-attempt (its blocker P0.2 proved false)
S2.2  verify maxdepth 3 is enough for nested live databases; test depth 4-5
S2.3  audit every `find` for prune + depth bound (C5 completion)
S2.4  --scan / --pick stress test (only Tier 1 is stress-tested today)

## Sprint 3 - performance
S3.1  C1 bulk `stat -f%z` batching for multi-path _rm calls
S3.2  --report is 2-3 min on a real machine: profile, then bound the du sweep
S3.3  C6 parallel sizing via FIFO semaphore (zsh has no `wait -n`)

## Sprint 4 - coverage
S4.1  Autodesk webdeploy (documented up to 60 GB)
S4.2  nix-collect-garbage
S4.3  bounded artifact hints, sampled + honestly labelled "985.6MB+"
S4.4  stale login items, report-only
S4.5  4 disk-reclaiming optimize actions, NO sudo tier

## Sprint 5 - release
S5.1  full Mole re-comparison, both fresh, same machine
S5.2  docs sync: README, SAFETY, CHANGELOG, --help
S5.3  multi-lens review over the whole diff since v0.2.8
S5.4  tag v0.2.9
