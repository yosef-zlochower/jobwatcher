# JobWatcher — chained Cactus runs under Slurm

`jw` runs one Cactus simulation as a chain of Slurm jobs. Each job recovers from the
checkpoint written by its predecessor, verifies that the predecessor really succeeded,
keeps a successor queued behind itself with `--dependency=afterok`, and classifies its
own outcome (SUCCESS, COMPLETE, FAILED) before exiting.

```
jw configure [options]   write ~/.config/jobwatcher/config: environment setup script and personal defaults
jw setup  [options]      create a simulation in the current directory
jw start  [-n DEPTH]     create Run1, submit it, keep DEPTH successors queued
jw status                show every run, its Slurm state and progress
jw stop   [--kill]       create STOP, cancel queued successors (--kill: also the running job)
jw resume [-n DEPTH]     remove STOP, move failed runs aside, submit the next run
jw sync                  copy the current library and batch template into .sim_data
jw log / jw config       show chain.log / the effective configuration
```

## Install

Choose a directory for JobWatcher (any directory: `jw` finds its library relative to its own
resolved location), clone the repository there and put `jw` on your PATH:

```
export JW_DIR=~/jobwatcher
git clone https://github.com/yosef-zlochower/jobwatcher ${JW_DIR}
ln -s ${JW_DIR}/bin/jw ~/bin/
jw configure                 # once: environment setup script and personal defaults
```

The only fixed path is the user configuration, `~/.config/jobwatcher/config` (honours
`$XDG_CONFIG_HOME`; `$JW_CONFIG` overrides the location).

`jw configure` writes `~/.config/jobwatcher/config`. Its one essential entry is `SETUP_SCRIPT`, the
script every job sources to set up modules/spack before launching Cactus; the cluster config
deliberately leaves it empty because it is personal. Interactive `jw configure` also asks for
the defaults that `jw setup` will offer (partition, walltime, nodes, mail, ...). Non-interactive
forms: `jw configure --setup-script FILE --partition long`, `jw configure KEY=VALUE`,
`--unset KEY`, `--show`. The file is plain bash and can be edited by hand.

A post-run hook (a script of your own that runs at the end of every successful run, see Hooks
below) is configured the same way: `jw configure --hook /path/to/script` makes it the default
for new simulations, `jw setup --hook` sets it for one, and `POST_RUN_HOOK=/path/to/script` in
`<simdir>/.sim_data/config` changes it for the runs that follow. `HOOK_FAILURE_FATAL=yes` makes
a failing hook fail the run.

Cluster-wide defaults (partitions, cores per node, launcher, `ENV_INIT`, ...) live in
`clusters/<cluster>.conf`; `$JW_CLUSTER` selects the file, and the one shipped in `clusters/` is
the model for adding another cluster.

Configuration precedence: `clusters/<cluster>.conf` < `~/.config/jobwatcher/config` (`jw configure`)
< `jw setup` options < edits to `<simdir>/.sim_data/config`. Existing simulations are
self-contained: changing the user config affects only simulations set up afterwards.

## Starting a simulation

```
mkdir /scratch/$USER/q1 && cd /scratch/$USER/q1
jw setup --name q1 --parfile /path/to/q1.par --exe /path/to/Cactus/exe/cactus_sim \
         --partition long --time 2-00:00:00 --nodes 4
jw start
```

`jw setup` copies the executable and the parfile into `.sim_data/`, detects the **driver**
(`carpet` or `carpetx`, from `ActiveThorns`; override with `--driver`), and **adapts the parfile
template** so that JobWatcher controls restarts (it prints every change it makes):

| Parameter | Set to | Why |
|---|---|---|
| `IO::checkpoint_dir`, `IO::recover_dir` | `@REP{CHECKPOINT_DIR}` = `<simdir>/CheckPoint` | one shared checkpoint directory for all runs |
| `cactus::max_runtime` | `@REP{MAX_RUNTIME}` = walltime − `RUNTIME_MARGIN_MIN` | Cactus stops itself before Slurm kills the job |
| `cactus::terminate` | `"any"` if the parfile's mode has a positive `cctk_itlast` / `cctk_final_time`, else `"runtime"`; the condition the original mode did not use gets an unreachable sentinel | runs stop on runtime; the chain ends when the final condition is reached |
| `IO::recover` | `"autoprobe"` | each run recovers from the newest checkpoint |
| `IO::checkpoint_on_terminate` | `yes` | the termination checkpoint is how progress is measured |
| `CarpetIOHDF5::checkpoint` (Carpet) | `"yes"` | enables checkpointing |
| `CarpetX::checkpoint_method`, `recover_method` (CarpetX) | `"openpmd"` when unset or `"error"` (the thorn default, which aborts at the first checkpoint); an explicit `"silo"` is kept | enables checkpointing |
| `TerminationTrigger::max_walltime`, `on_remaining_walltime` (if the thorn is active) | `@REP{WALLTIME_HOURS}`, `@REP{RUNTIME_MARGIN_MIN}` | the trigger follows `WALLTIME` instead of a hard-coded value and fires when `cactus::max_runtime` does |

Parfile variables (`$itlast = 64 * 16`) are resolved when the final condition is inspected.
Placeholders may also be written into the parfile by hand: `@REP{CHECKPOINT_DIR}`,
`@REP{MAX_RUNTIME}`, `@REP{WALLTIME_HOURS}`, `@REP{RUNTIME_MARGIN_MIN}`, `@REP{SIMDIR}`,
`@REP{SIMNAME}`, `@REP{RUN}`, `@REP{DATADIRNAME}`.

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
     env_<job>.txt, env_setup_<job>.log   environment the job launched with; SETUP_SCRIPT output
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
4. Builds the environment: evaluates `ENV_INIT`, sources `SETUP_SCRIPT` (output in
   `env_setup_<job>.log`), exports `OMP_*`, evaluates `EXTRA_ENV`, records the result in
   `env_<job>.txt`, then runs `LAUNCHER ./EXE PARFILE > cactus_<job>.out`.
5. Classifies: no termination-checkpoint announcement, a non-zero launcher exit, an announced but
   unconfirmed write (CarpetX only, see below), or a missing checkpoint → `FAILED`. Iteration ≥
   `cctk_itlast` or time ≥ `cctk_final_time` (per `cactus::terminate`) → `COMPLETE`. Fewer than
   `MIN_PROGRESS` new iterations → `FAILED` (this is also what you see if a
   `terminate = "runtime"` simulation is really finished: use `jw stop`). Otherwise `SUCCESS` and
   `.sim_data/last` is updated.
6. `COMPLETE`, `FAILED` and `STOPPED` cancel every queued successor explicitly; a `FAILED` job
   also exits 1 so Slurm's `afterok` can never fire. Slurm's own `--mail-type=FAIL` mail plus
   JobWatcher's summary mail (events chosen by `MAIL_EVENTS`, with the tail of the Cactus
   output on failure) are sent.
7. Runs `POST_RUN_HOOK <rundir> <state>` if set (see Hooks below).

Because the successor is queued at the *start* of a run it accrues queue priority while the
run executes; if the run is killed by the time limit or a node failure, its exit status is
non-zero and the successor is cancelled by Slurm. `jw status` then shows `RUNNING`/`gone`
and `jw resume` restarts from the last successful run.

### Drivers: Carpet and CarpetX

`DRIVER` in `.sim_data/config` selects how the termination checkpoint is recognised:

| | Carpet (`CarpetIOHDF5`) | CarpetX |
|---|---|---|
| announcement in the Cactus output | `Dumping termination checkpoint at iteration N, simulation time T` (printed after the write) | `Checkpointing before terminating at iteration N, time T, run time H h` (printed *before* the write) |
| write confirmed by | the announcement itself | CarpetX prints nothing when the checkpoint is finished, so the proof is Cactus's clean shutdown line `Done.` after the announcement (a job killed inside the write never gets there); also accepted: `Already wrote checkpoint at iteration N; skipping checkpointing` (a periodic checkpoint coincided), `Recovered from checkpoint at iteration N; skipping checkpointing` (no progress: `MIN_PROGRESS` then fails the run), and `OutputOpenPMD done.` from older CarpetX versions |
| checkpoint on disk | `<file>.chkpt.it_N[.file_P].h5` | `<file>.chkpt.itNNNNNNNN.{bp5,bp4,bp,h5,silo}` (zero padded; BP5 is a directory). The `<file>.openpmd.visit` index and anything with another suffix (e.g. a directory renamed to `.bp5_bad`) is ignored |

An announcement without a confirmation means Cactus died inside the checkpoint write: the run is
`FAILED` and the incomplete directory stays on disk (JobWatcher never deletes checkpoints; note
that CarpetX ignores `IO::checkpoint_keep`, so prune `CheckPoint/` by hand). Because `IO::recover
= "autoprobe"` picks the newest checkpoint, check `CheckPoint/` before `jw resume` after such a
failure.

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
- **Upgrade the scripts in a running simulation:** `jw sync`. Every job that starts afterwards,
  including successors that are already queued, executes the new `jw_job.sh` (the batch script
  `exec`s it from `.sim_data` at run time).
- **Finish by hand:** `jw stop`, or set a final condition in `.sim_data/parfile.template`.

## Hooks

`POST_RUN_HOOK` names a script of your own (archiving, merging diagnostics, ...) that every
successful run executes at its end. Set it with `jw configure --hook SCRIPT`, `jw setup --hook`,
or `POST_RUN_HOOK=/path/to/script` in a config. The interface:

- Called as `SCRIPT <rundir> <state>` with `state` `SUCCESS` or `COMPLETE`, inside the job on the
  allocated node, after the termination checkpoint, with the job's environment. Allow for its
  running time in `RUNTIME_MARGIN_MIN`.
- Must be executable; otherwise it is skipped with a warning.
- Its output goes to `RunN/hook_<jobid>.out`.
- A non-zero exit is logged as `HOOK-FAIL` in `chain.log`; the run itself stays `SUCCESS` unless
  `HOOK_FAILURE_FATAL=yes`.
- To get at the simulation's settings (`DATADIRNAME`, `PARFILE`, `CHECKPOINT_DIR`, ...) source
  `<simdir>/.sim_data/jw_common.sh` and call `jw_load_sim <simdir>`, where `<simdir>` is the
  parent of `<rundir>`; `jw_run_dirs` then lists the run directories in order and
  `jw_status_get <dir>/status state` tells which of them succeeded.

## What JobWatcher assumes about Slurm

- `sbatch`, `squeue`, `scontrol` and `scancel` must work on compute nodes, and a job must be
  allowed to submit another job with `--dependency=afterok`: successors are queued from inside
  the running job. If a compute node cannot run them, or has no `mail` command for the summary
  mails, every such call falls back to `ssh $MASTERNODE ...` (set `MASTERNODE` in the cluster
  config; passwordless ssh from the nodes is then required). Slurm's own `--mail-type` mails are
  sent by the controller and need nothing from the node.
- Slurm accounting is not needed: JobWatcher never consults `sacct`, only its own status files
  and `afterok`.
- Finished jobs stay visible to `squeue` only for `MinJobAge` (typically a few minutes); after
  that a dependency on them cannot be expressed, which is why `jw resume` submits without a
  dependency when the predecessor is gone.
- On node-exclusive partitions `MEM` can stay empty. On shared partitions set it
  (`jw setup --mem 16G`, or `MEM=16G` in the config) and keep `TASKS_PER_NODE * CPUS_PER_TASK`
  within what is free.
- Jobs are submitted with `--export=NONE` (`SBATCH_EXPORT`), so Slurm gives every job a fresh
  login environment instead of a copy of the submitter's; a successor submitted from inside a
  running job therefore sees exactly what a job submitted from the login node sees, nothing is
  inherited from the parent job. The job then evaluates `ENV_INIT` from the cluster config (for
  example to define `module` where `/etc/profile.d/lmod.sh` is skipped under Slurm), sources
  `SETUP_SCRIPT` and sets `SLURM_EXPORT_ENV=ALL` so that `srun` passes that environment to the
  Cactus tasks (with `NONE` still in force the tasks would start without `HOME`/`PATH` and
  OpenMPI's `MPI_Init` fails with "Unable to get the user home directory").

## Tests

`tests/run_tests.sh` runs `jw` against a fake Slurm (`tests/fakeslurm`) and a fake Cactus
(`tests/fakecactus`) that mimics recovery, termination checkpoints and crashes. It covers:
walltime parsing, templating and parfile-variable resolution; a chain that completes at
`cctk_itlast` and cancels its queued successor; a crash in Run2 with cancellation of Run3,
`jw resume`, and `MAX_RUNS`; `jw stop`/`jw resume`; a no-progress failure; an
announced-but-missing checkpoint file; `jw resume` refusing while a job is queued; jobs forgotten
by the controller after `MinJobAge`; and a CarpetX chain (`FAKE_DRIVER=carpetx`: padded `.bp5`
directories, completion by `cctk_final_time` given as a parfile variable, a write killed before
the clean shutdown, the "Already wrote"/"Recovered from" skip lines); and `jw configure`.
