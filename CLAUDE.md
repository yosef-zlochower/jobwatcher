# Working on JobWatcher

Read this before changing anything. It records what is not obvious from the code and the
conventions the maintainer expects. README.md is the user manual, docs/scheduler-backends.md
the design of the scheduler layer, EXTENDING_JOBWATCHER.md the hand-over for adding PBS/LSF.

## What it is

`bin/jw` plus `lib/` run a Cactus simulation as a chain of batch jobs: each job (`lib/jw_job.sh`)
checks its predecessor's termination checkpoint, queues its successor with a dependency, runs
Cactus for `WALLTIME - RUNTIME_MARGIN_MIN`, and classifies the outcome. Everything is bash
(4.x), no other runtime. Current version: `JW_VERSION` in `lib/jw_common.sh`.

## Rules the maintainer has set

- **JobWatcher never deletes, moves or prunes checkpoint files.** No prune step, no cleanup
  option, whatever a driver or site does. Moving a failed Run directory aside is fine.
- **Never run `git push`, `git pull` or `git fetch`.** The maintainer runs every remote git
  command; hand them the command instead. Commit when asked ("commit"), and end commit
  messages with the `Co-Authored-By` line for the model in use.
- **README.md is for new users.** Generic install paths and clone instructions, no site names,
  no personal directories, no references to superseded tools. Cluster facts and comments
  belong in `clusters/<name>.conf`; the code and the README stay cluster-neutral.
- **No cruft, no compatibility shims.** When a key, placeholder or file is renamed, rename it
  everywhere and let `jw sync` refresh existing simulations. Do not keep fallbacks for names
  that were never released.
- `tests/run_tests.sh` must be green before every commit.

## How the pieces fit

- Config precedence: `clusters/<cluster>.conf` < user config (`$JW_CONFIG`, else
  `$XDG_CONFIG_HOME/jobwatcher/config`, else `~/.config/jobwatcher/config`, written by
  `jw configure`) < the partition's line in `PARTITIONS` (tasks, threads, memory only) <
  `jw setup` options < `<simdir>/.sim_data/config` (self-contained once written; successors
  re-read it, so edits between runs take effect).
- `JW_CLUSTER` names a file in `clusters/` or a path; without it the single file in `clusters/`
  is used and several is an error. `tests/cluster.conf` is the neutral example.
- Library defaults for keys a config may omit are in `jw_apply_defaults`; keys only one
  scheduler reads are defaulted by that backend's `jw_sched_defaults`.
- `jw setup` freezes `jw_common.sh`, `jw_job.sh`, the scheduler backend as `jw_sched.sh`, and
  `sub.template` into `<simdir>/.sim_data`; `jw sync` refreshes them (`install_sim_files`,
  temp file plus `mv` so a starting job never sees a half-written file). A change to the
  library therefore reaches existing simulations only after `jw sync`.
- Scheduler calls go only through `jw_sched_*` functions (`lib/sched/<name>.sh`, contract in
  docs/scheduler-backends.md, checked by `jw_load_sched`). `jw_sched_cmd` adds the ssh
  fallback to `MASTERNODE` for compute nodes without working client commands. Templates are
  `templates/<scheduler>/sub.template`, overridable per cluster as
  `clusters/<name>.sub.template`, filled with `@REP{...}` placeholders; the `HEADER_*` ones are
  whole directive lines that are empty when the key is unset.
- The parfile is adapted at setup (`adapt_parfile`): checkpoint directories, `cactus::max_runtime`,
  `terminate`, `cctk_itlast`, TerminationTrigger values become `@REP` placeholders rendered per
  run. Carpet and CarpetX are detected from ActiveThorns; CarpetX prints no done-line after a
  checkpoint, so the job script treats Cactus's own "Done." as the proof of the termination
  checkpoint and checks that the checkpoint files exist.
- Run outcome states: SUCCESS (terminated on time with a checkpoint), COMPLETE (reached the
  end), FAILED, STOPPED (refused to start because `STOP` exists), CANCELLED. Exit status 0 only
  for SUCCESS/COMPLETE/STOPPED, so scheduler dependencies stop a chain after a failure even
  when the job died before reaching the classification code.

## Testing without a cluster

`tests/run_tests.sh [workdir]` runs the scenario suite against `tests/fakeslurm` (symlinked as
`sbatch`, `squeue`, `scancel`, `srun`, `mail`, `runqueue`) and `tests/fakecactus`, with
`JW_CLUSTER=tests/cluster.conf` and a temporary user config. Failing runs keep their work
directory. Known gaps of the fake: it ignores `--export`, accepts unknown options, never parses
the `#SBATCH` header, and cannot run a job in the background, so `jw stop` against a running
job is untested; see EXTENDING_JOBWATCHER.md section 3.4 before relying on it for a new
backend. A quick manual probe of the rendered batch script needs no scheduler:
`jw setup --yes ... --exe /bin/true` in an empty directory, then source `.sim_data/jw_common.sh`
with `JW_HOME` set, `jw_load_sim .` and `jw_prepare_run 1`, and read `Run1/sub`.

`bash -n` on `bin/jw`, `lib/*.sh` and `lib/sched/*.sh` catches syntax slips; the scripts run
under `set -u`, so every new variable needs a default or a `${x:-}`.

## Things easy to get wrong

- `bin/jw` sources the config files inside a function: a cluster config must not use
  `declare` for anything meant to be global (plain assignments only, which is why
  `PARTITIONS` is a multi-line string, not an array).
- `jw_prepare_run` renders `WALLTIME` and `MEM` in the scheduler's spelling and keeps the
  canonical values as `WALLTIME_RAW`/`MEM_RAW`; `jw_walltime_minutes` accepts `[D-]HH:MM:SS`.
- `jw_job_state` returns "" for a finished job and rc 1 only when the query failed;
  `jw_job_in_queue` is 0/1/2 (in queue / gone / cannot tell). `jw resume` relies on that
  distinction to decide whether a dependency can still be expressed.
- Job ids are stored as the scheduler prints them (`JW_JOBID`); file names use
  `JW_JOBID_SHORT`.
- The shipped `clusters/gp.conf` describes the maintainer's cluster and is the only cluster
  file; its comments are deliberately specific. The test suite must keep passing with
  `tests/cluster.conf`, which is what `run_tests.sh` selects.
