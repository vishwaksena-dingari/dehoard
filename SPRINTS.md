# scree completion plan

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
Conclusion: the suite is ~10 min because it runs ~100 real scree invocations. That is inherent to
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
S3.3  DECLINED after measurement. A window-4 PID-array pool over 12 directories measured 0.191s
      against 0.265s sequential - a 28% gain on a synthetic best case, and directory sizing is no
      longer the dominant cost now that plain files are batched through one stat and the whole probe
      is bounded by SCREE_SIZE_TIMEOUT. Concurrency in the code path that DELETES files buys
      background jobs, PID bookkeeping and interrupt handling, and the orphaned-grandchild bug
      already found in _run_timeout is exactly the failure mode it invites. Not worth 28%.

## Sprint 4 - coverage
S4.1  Autodesk webdeploy (documented up to 60 GB)
S4.2  nix-collect-garbage
S4.3  bounded artifact hints, sampled + honestly labelled "985.6MB+"
S4.4  stale login items, report-only
S4.5  DECLINED after measurement. Of the 22 optimize actions surveyed, only four reclaim disk at
      all, and on this machine the largest of them - Saved Application State - is 12 KB. The rest
      are DNS flushes, Spotlight reindexing and permission repairs: maintenance, not reclamation,
      and several need sudo. scree never asking for sudo is a genuine differentiator worth
      keeping, and a "cleaner" that flushes DNS is pretending to work. Not built.

## Sprint 5 - release
S5.1  INCONCLUSIVE this round, and the reason matters more than the number.
      scree v0.2.9 --deep --dry-run: 9.13 GB across 122 items, completed.
      Mole: did not finish. It ran past 20 minutes and stalled in its "App caches" section, versus
      4:54 for a full run earlier the same day. Its own source documents that section's live-cache
      probing (reverse-DNS process matching plus lsof per container) as the expensive one.
      The comparison is NOT valid as a head-to-head regardless, because the machine is not the same
      machine: roughly 20 GB has been reclaimed between the two runs, including the 8 GB Rust target
      tree that dominated the earlier figures. Comparing 20.56 GB found on a full disk against
      9.13 GB found on a cleaned one measures the cleaning, not the tools.
      A valid re-run needs a machine in a known state, ideally a fresh VM. Not something to fake.
S5.2  docs sync: README, SAFETY, CHANGELOG, --help
S5.3  multi-lens review over the whole diff since v0.2.8
S5.4  tag v0.2.9

## Post-v0.2.10: an attempted optimisation that was measured and reverted

--report at ~150s is bounded but still slow, and the cost is `du -h -d 2 ~`. Profiling the home
tree showed `du -sk ~/Library` alone runs past ten minutes, almost entirely
~/Library/Containers and ~/Library/Group Containers - thousands of tiny per-app sandbox files, one
bundle alone holding 2843. Those are also the least useful thing the section can show, since
scree never cleans them: they are app data, not cache.

Skipping them looked like the rare optimisation that costs nothing. It was not.

Rewriting the scan to walk ~'s children individually and skip the container trees measured 437s,
against a 175s baseline. A real bug in the rewrite - it walked ~/Library in the child loop AND
walked Library's children again - accounted for some of it; fixing that brought it to 344s. Still
worse. Two clean runs of the ORIGINAL then measured 158s and 139s, so the gap is not cache warmth:
one `du` traversing the tree once and reporting at every level genuinely beats N invocations each
re-walking a child.

Reverted. The simple bounded version ships. A change that adds a loop, a skip list and a nested
second pass has to earn it with a measurement, and this one measured worse.
