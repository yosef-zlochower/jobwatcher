# JobWatcher (Slurm edition) — chained Cactus runs on green-prairies

`jw` runs one Cactus simulation as a chain of Slurm jobs. Each job recovers from the
checkpoint written by its predecessor, verifies that the predecessor really succeeded,
keeps a successor queued behind itself with `--dependency=afterok`, and classifies its
own outcome (SUCCESS, COMPLETE, FAILED) before exiting. The design and limitations of the
PBS-era scripts it replaces are documented in `~/.JobWatcher/README.md`.

```
jw setup  [options]      create a simulation in the current directory
jw start  [-n DEPTH]     create Run1, submit it, keep DEPTH successors queued
jw status                show every run, its Slurm state and progress
jw stop   [--kill]       create STOP, cancel queued successors (--kill: also the running job)
jw resume [-n DEPTH]     remove STOP, move failed runs aside, submit the next run
jw sync                  copy the current library and batch template into .sim_data
jw log / jw config       show chain.log / the effective configuration
```

## Install

```
~/.JobWatcher/Slurm   -> ~/git/yosef/cluster_scripts/JobWatcher/Slurm   (this directory)
~/bin/jw              -> ~/.JobWatcher/Slurm/bin/jw                     (~/bin is on PATH)
~/.JobWatcher/config     user overrides of clusters/gp.conf
```

Configuration precedence: `clusters/gp.conf` < `~/.JobWatcher/config` < `jw setup` options
< edits to `<simdir>/.sim_data/config`.

## Starting a simulation

```
mkdir /lustre/yosef/Runs/q1_new && cd /lustre/yosef/Runs/q1_new
jw setup --name q1 --parfile ~/pars/q1.par --exe /lustre/yosef/NewCluster/Kruskal/Cactus/exe/cactus_lazev_intel21_base \
         --partition gp-long --time 2-00:00:00 --nodes 4
jw start
```

`jw setup` copies the executable and the parfile into `.sim_data/`, and **adapts the parfile
template** so that JobWatcher controls restarts (it prints every change it makes):

| Parameter | Set to | Why |
|---|---|---|
| `IO::checkpoint_dir`, `IO::recover_dir` | `@REP{CHECKPOINT_DIR}` = `<simdir>/CheckPoint` | one shared checkpoint directory for all runs |
| `cactus::max_runtime` | `@REP{MAX_RUNTIME}` = walltime − `RUNTIME_MARGIN_MIN` | Cactus stops itself before Slurm kills the job |
| `cactus::terminate` | `"any"` if the parfile has a positive `cctk_itlast` / `cctk_final_time`, else `"runtime"` | runs stop on runtime; the chain ends when the final condition is reached |
| `IO::recover` | `"autoprobe"` | each run recovers from the newest checkpoint |
| `IO::checkpoint_on_terminate`, `CarpetIOHDF5::checkpoint` | `yes` | the termination checkpoint is how progress is measured |

Placeholders may also be written into the parfile by hand: `@REP{CHECKPOINT_DIR}`,
`@REP{MAX_RUNTIME}`, `@REP{SIMDIR}`, `@REP{SIMNAME}`, `@REP{RUN}`, `@REP{DATADIRNAME}`.

## Layout of a simulation

```
<simdir>/
  .sim_data/config            resolved settings; edit between runs, successors pick the changes up
  .sim_data/parfile.template  adapted parfile with placeholders
  .sim_data/sub.template      batch script template (clusters' sbatch header)
  .sim_data/jw_job.sh, jw_common.sh   frozen copy of the logic; `jw sync` refreshes it
  .sim_data/<exe>             copy of the executable (Run dirs hard-link it)
  .sim_data/last              iteration of the last successful termination checkpoint
  .sim_data/last.history      one line per successful run
  CheckPoint/                 checkpoints of every run (IO::checkpoint_keep applies)
  chain.log                   append-only event log (QUEUED, START, SUCCESS, FAILED, CANCELLED, MOVED ...)
  STOP                        present while the chain is stopped
  RunN/
     sub, <par>.par, <exe>    filled for this run
     status                   key=value: state, jobid, iter, time, reason, start, end, depends
     stdout_<job>.out         JobWatcher trace (what the job did and decided)
     cactus_<job>.out         Cactus output (what the classification parses)
     <DATADIRNAME>/           Cactus IO::out_dir
  RunN.failed.<ts>/           failed runs moved aside by `jw resume`
```

States: `PREPARED → QUEUED → RUNNING → SUCCESS | COMPLETE | FAILED | STOPPED`, plus
`CANCELLED` for queued successors that were cancelled.

## What a job does (`lib/jw_job.sh`)

1. Writes `state=RUNNING`; exits 0 with `STOPPED` if `<simdir>/STOP` exists.
2. For Run N > 1: requires `Run(N-1)/status` to say `SUCCESS` and a checkpoint to exist. If
   the newest checkpoint is not the predecessor's termination checkpoint it warns (or fails with
   `STRICT_CHECKPOINT=yes`).
3. Queues successors so that `QUEUE_DEPTH` runs are waiting, each
   `--dependency=afterok:<previous> --kill-on-invalid-dep=yes`. Successors are prepared from the
   *current* `.sim_data/config`, so walltime, nodes, partition and the executable can change
   between runs. Nothing is queued past `MAX_RUNS` or while `STOP` exists.
4. Sources `SETUP_SCRIPT`, exports `OMP_*`, runs `LAUNCHER ./EXE PARFILE > cactus_<job>.out`.
5. Classifies: no `Dumping termination checkpoint at iteration N` line, a non-zero launcher
   exit, or a missing checkpoint file → `FAILED`. Iteration ≥ `cctk_itlast` or time ≥
   `cctk_final_time` (per `cactus::terminate`) → `COMPLETE`. Fewer than `MIN_PROGRESS` new
   iterations → `FAILED` (this is also what you see if a `terminate = "runtime"` simulation is
   really finished: use `jw stop`). Otherwise `SUCCESS` and `.sim_data/last` is updated.
6. `COMPLETE`, `FAILED` and `STOPPED` cancel every queued successor explicitly; a `FAILED` job
   also exits 1 so Slurm's `afterok` can never fire. Slurm's own `--mail-type=FAIL` mail plus
   JobWatcher's summary mail (events chosen by `MAIL_EVENTS`, with the tail of the Cactus
   output on failure) are sent.
7. Runs `POST_RUN_HOOK <rundir> <state>` if set (see hooks/).

Because the successor is queued at the *start* of a run it accrues queue priority while the
run executes; if the run is killed by the time limit or a node failure, its exit status is
non-zero and the successor is cancelled by Slurm. `jw status` then shows `RUNNING`/`gone`
and `jw resume` restarts from the last successful run.

## Operating

- **Watch:** `jw status`, `jw log`, `squeue --me`, `tail RunN/stdout_*.out`.
- **Pause:** `jw stop` (the running job finishes and queues nothing; its successors are
  cancelled). `jw stop --kill` also cancels the running job.
- **Continue after a failure or a stop:** fix the cause, then `jw resume`. Failed run
  directories become `RunN.failed.<timestamp>`; never-run directories are removed; the next run
  is submitted without a dependency and recovers from the newest checkpoint in `CheckPoint/`.
- **Change resources mid-chain:** edit `.sim_data/config` (e.g. `WALLTIME`, `NODES`,
  `PARTITION`, `EXE` after copying a new executable into `.sim_data/`). The next successor that is
  *prepared* uses them; an already-queued successor does not (cancel it with `jw stop`, then
  `jw resume`).
- **Upgrade the scripts in a running simulation:** `jw sync`.
- **Finish by hand:** `jw stop`, or set a final condition in `.sim_data/parfile.template`.

## Hooks

- `hooks/archive_run.sh` tars `RunN/<DATADIRNAME>` plus the parfile, status and Cactus output
  into `<simdir>/Archive/<DATADIRNAME>_RunN.tar.gz` (set `JW_ARCHIVE_REMOVE=yes` in `EXTRA_ENV` to
  delete the output directory after a verified tar), then calls `lazev_combine.sh` if present.
- `hooks/lazev_combine.sh` rebuilds `<simdir>/combine/` from all successful runs: the LazEv
  diagnostic files, every `*rad_obs_*` file and `pk*` files, concatenated in run order with
  time overlaps trimmed, then `~/Scripts/pitrack.sh`. It is idempotent, so a resumed chain never
  duplicates rows (the old `combo.sh`/`olderdata` dance is gone).

Enable with `POST_RUN_HOOK=$HOME/.JobWatcher/Slurm/hooks/archive_run.sh` in the config. Hooks run
inside the job, on the allocated node, after the termination checkpoint; allow for them in
`RUNTIME_MARGIN_MIN`.

## Cluster assumptions (green-prairies, Slurm 23.11)

- `gp-default` (2 days) and `gp-long` (20 days) are node-exclusive, so `MEM` can stay empty
  there. `debug` (12 h) and `lm-largemem` share the 48-core, 770 GB node `lm-n0001` and default
  to 2 GB per CPU: set `MEM` (`jw setup --mem 16G`, or `MEM=16G` in the config) when using them,
  and keep `TASKS_PER_NODE * CPUS_PER_TASK` within what is free. Use `debug` for short tests.
- Slurm accounting is disabled, so `sacct` cannot tell whether a job succeeded; JobWatcher
  relies on its own status files and on `afterok`.
- Verified on 2026-11-04 with a probe job on `lm-n0001`: `sbatch`, `squeue`, `scontrol` and
  `scancel` work on compute nodes, and a job submitted from inside a job with
  `--dependency=afterok` runs. There is **no `mail` command on compute nodes**, so JobWatcher's
  summary mails go through `ssh $MASTERNODE mail ...` (passwordless ssh from the nodes to
  green-prairies works). Slurm's own `--mail-type` mails are sent by the controller and need
  nothing from the node. Every scheduler call also has the same ssh fallback.
- Finished jobs stay visible to `squeue` for `MinJobAge` (5 min); after that a dependency on
  them cannot be expressed, which is why `jw resume` submits without a dependency when the
  predecessor is gone.

## Tests

`tests/run_tests.sh` runs `jw` against a fake Slurm (`tests/fakeslurm`) and a fake Cactus
(`tests/fakecactus`) that mimics recovery, termination checkpoints and crashes. It covers:
walltime parsing and templating; a chain that completes at `cctk_itlast` and cancels its
queued successor; a crash in Run2 with cancellation of Run3, `jw resume`, and `MAX_RUNS`;
`jw stop`/`jw resume`; a no-progress failure; an announced-but-missing checkpoint file; and
`jw resume` refusing while a job is queued.
