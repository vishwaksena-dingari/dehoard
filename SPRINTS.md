# dehoard completion plan

Baseline: 8158f27, 175 assertions + 12 stress, CI green, v0.2.8 shipped.
Rule for every task: implement, then verify by NEGATIVE CONTROL (break it, watch the test go red).

## Sprint 1 - suite runtime: REOPENED AND FIXED (the close below was wrong)
Root cause: SAFE_PATH claimed to exclude package managers, and did exclude brew/npm/go/uv/cargo -
but pip3 and gem ship inside /usr/bin. Every --apply in the suite ran a REAL `pip3 cache purge`
(4.89s) and `gem cleanup` (2.53s) against the developer's actual Python and Ruby installs. About
100 invocations x 7.4s is ~12 minutes, spent mutating real state no test asserts on.
Fix: a stub directory prepended to SAFE_PATH. Empty-fixture --apply: 7.7-14.6s -> 4.1-4.3s.

The lesson is in the discarded reasoning below. I measured wildly inconsistent timings for the same
command, called the variance "noise exceeding signal", and closed the question. The variance WAS the
signal: a cold `pip3 cache purge` against a populated wheel cache is slow and variable, and that is
precisely what it looked like.

### superseded reasoning, kept deliberately
Measured rather than assumed, and the assumptions were wrong:
- 563 MB of `dd` fixtures cost 5.5s total, and `du` over them is 0.02s. Not the cause.
- `_pm_run` already guards on `command -v`, so absent package managers cost nothing.
- Startup is 0.09s (--version); dry-run 1.37s. Only --apply is slow.
- The same --apply command measured 7.8s, 14.3s, 16.0s and 20.6s on an empty fixture within a few
  minutes. The variance EXCEEDS the signal, so nothing here can be optimised with confidence on
  this machine.
Conclusion: the suite is ~10 min because it runs ~100 real dehoard invocations. That is inherent to
integration tests that spawn the real binary, not a defect. CI runs it reliably; local iteration
uses test/stress-apply.zsh (~20s) plus targeted isolation harnesses.

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
