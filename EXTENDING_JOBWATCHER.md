# Extending JobWatcher to another batch scheduler

This is the hand-over for stage 2 (PBS Pro / OpenPBS / Torque) and stage 3 (LSF) of the
scheduler work. It is written for whoever picks the work up later, human or AI, on a machine
where the target scheduler is available. Stage 1 is done: the chain logic calls the scheduler
only through a backend interface, and Slurm is the one backend. Read this file, then
`docs/scheduler-backends.md` (the design, with the full per-scheduler mapping table), then the
code it points at.

## 1. What exists after stage 1

| Path | Role |
|---|---|
| `lib/sched/slurm.sh` | the reference backend; copy it to start a new one |
| `lib/jw_common.sh` | `jw_load_sched` (loads a backend and checks the contract), `jw_sched_cmd` (runs a scheduler command with the ssh fallback), `jw_job_state`/`jw_job_in_queue` (wrappers over `jw_sched_state`), `jw_prepare_run` (renders the batch script), `jw_submit_run`, `jw_ensure_successors`, `jw_cancel_successors` |
| `lib/jw_job.sh` | runs inside the job; uses `jw_sched_job_env`, `jw_sched_launcher_env`, `jw_sched_timelimit_regex` and nothing else scheduler-specific |
| `bin/jw` | `install_sim_files` copies library, backend and template into `.sim_data`; `jw setup`/`jw sync` call it; `cmd_status`, `cmd_stop`, `cmd_resume` use the wrappers |
| `templates/slurm/sub.template` | the Slurm batch-script template |
| `clusters/gp.conf` | the only cluster config; `SCHEDULER=slurm` |
| `tests/fakeslurm`, `tests/run_tests.sh`, `tests/cluster.conf` | the fake scheduler and the scenario suite |
| `docs/scheduler-backends.md` | the design: contract, mapping table, semantic differences, test-harness plan |

A simulation freezes `jw_common.sh`, `jw_job.sh`, `jw_sched.sh` and `sub.template` in
`<simdir>/.sim_data`; `jw sync` refreshes all four. `SCHEDULER=<name>` in the cluster config
selects `lib/sched/<name>.sh` and `templates/<name>/sub.template`; a cluster may ship its own
template as `clusters/<name>.sub.template`.

## 2. The backend contract

A backend is a bash file sourced by `jw_load_sched`. It must set `JW_SCHED_NAME` to its own
name and define all of these functions; the loader refuses a backend that lacks one.

| Function | Contract |
|---|---|
| `jw_sched_defaults` | defaults for keys only this backend reads (`LAUNCHER`, native knobs such as `SBATCH_EXPORT`, `QSUB_OPTS`, `BSUB_OPTS`). Called by `jw_apply_defaults` after the config files. |
| `jw_sched_submit <script> [<dep-jobid>]` | cwd is the run directory. Print the native job id on stdout, rc 0. On failure rc 1, message on stderr, nothing on stdout. The job must get a clean login environment, never the submitter's. With a dependency: start only after that job exited 0, and have the scheduler remove the job when that can never happen, where the scheduler can express it. Go through `jw_sched_cmd`. |
| `jw_sched_cancel <jobid>` | idempotent; rc 0 also when the job is already gone; no output. |
| `jw_sched_state <jobid>` | print `<norm> <raw>`; `norm` is `queued`, `running`, `gone` or `unknown`; `raw` is the scheduler's own state name, `-` when the job is not known any more. rc 1 with a message on stderr only when the query itself failed, so that "gone" and "cannot tell" stay distinct. An empty id prints `gone -`. |
| `jw_sched_job_env` | inside a job: export `JW_IN_JOB=yes`, `JW_JOBID` (native id, used for status files, the log and dependencies), `JW_JOBID_SHORT` (`[0-9]+`, used in file names), `JW_SUBMIT_DIR`, `JW_NODELIST`, `JW_QUEUE`. rc 1 when not inside a job of this scheduler. |
| `jw_sched_launcher_env` | called just before `$LAUNCHER` starts the executable; export whatever makes the launcher pass the environment the job built to the tasks. May be a no-op. |
| `jw_sched_walltime <canonical>` | `[D-]HH:MM:SS` (anything `jw_walltime_minutes` accepts) to the scheduler's spelling. |
| `jw_sched_mem <spec>` | Slurm spelling (`16G`) to the scheduler's spelling. |
| `jw_sched_header <item>` | `partition`, `account`, `qos`, `mem`, `mail`, `exclusive` or `extra`: print the complete directive line(s) for that item, or nothing when the key is unset. Always rc 0. |
| `jw_sched_exec_line` | the last line of the batch script: cd into the run directory (the job may start in `$HOME`) and `exec bash ../.sim_data/jw_job.sh`; redirect its stdout to `stdout_<short id>.out` if the scheduler does not write the job output live. |
| `jw_sched_timelimit_regex` | `grep -E` pattern in the launcher output meaning "killed by the time limit"; may print nothing. |
| `jw_sched_jobid_ok <string>` | rc 0 if the string is a plausible job id of this scheduler. |

Placeholders `jw_prepare_run` offers to every template: `SIMNAME RUN SIMDIR RUNDIR EXE PARFILE
PARTITION NODES TASKS_PER_NODE CPUS_PER_TASK CPUS_PER_NODE NTASKS NSLOTS MAIL MAIL_TYPE ACCOUNT
QOS WALLTIME WALLTIME_RAW MEM MEM_RAW HEADER_PARTITION HEADER_ACCOUNT HEADER_QOS HEADER_MEM
HEADER_MAIL HEADER_EXCLUSIVE HEADER_EXTRA JW_EXEC`. `WALLTIME` and `MEM` are already in the
scheduler's spelling; `*_RAW` are the canonical values. `jw_fill_template` warns about
placeholders a template uses that were not offered.

Generic config keys the chain code reads: `SCHEDULER PARTITION WALLTIME NODES TASKS_PER_NODE
CPUS_PER_TASK CORES_PER_NODE MEM ACCOUNT QOS EXCLUSIVE MAIL MAIL_TYPE (Slurm vocabulary:
NONE BEGIN END FAIL ALL) MAIL_EVENTS HEADER_EXTRA LAUNCHER SETUP_SCRIPT ENV_INIT EXTRA_ENV
MASTERNODE`. `bin/jw` writes `SBATCH_EXPORT` into every simulation config today; a new backend
ignores it, and `write_config` can grow the new backend's knobs the same way.

Chain semantics every backend must preserve (see `docs/scheduler-backends.md` section 4):

1. A successor is submitted at the start of its predecessor's run, depending on it. If the
   predecessor finishes with a non-zero exit (any state but SUCCESS, COMPLETE or STOPPED) the
   successor must never start. `jw_job.sh` also cancels successors explicitly in those cases;
   the scheduler mechanism matters when the predecessor dies without reaching that code
   (time-limit kill, node failure, manual cancel).
2. `gone` must cover every finished state, not only "unknown to the scheduler", otherwise
   `jw resume` tries to depend on a finished job. `jw resume` submits without a dependency
   when the predecessor is `gone`.
3. `jw_job.sh` takes the run directory from `pwd`, so the trailer must cd there.
4. Job ids are stored as the scheduler prints them and passed back unchanged.

## 3. Stage 2: PBS Pro / OpenPBS, then Torque

Do it on a machine with the scheduler installed, with a short Cactus-like test job available
(even `sleep` plus a fake checkpoint file is enough to exercise the chain; `tests/fakecactus`
shows what `jw_job.sh` expects to see in the Cactus output).

### 3.1 Backend `lib/sched/pbs.sh`

Start from `lib/sched/slurm.sh`. Expected spellings (verify each on the installation; the
items marked "verify" in the design doc are the ones with known variation between sites and
versions):

| Item | PBS Pro / OpenPBS |
|---|---|
| submit | `qsub [-W depend=afterok:ID] sub`; default export (no `-V`) gives a clean environment; output `123.server` (last line) |
| id check | `^[0-9]+(\[\])?\.[^ ]+$`; `JW_JOBID_SHORT=${PBS_JOBID%%.*}` |
| state | `qstat -x -f ID`, parse `job_state =`: `Q H W T` queued, `R E S B` running, `F X M` gone. "Unknown Job Id" on stderr means gone. Without job history (`job_history_enable` off, the default) a finished job is unknown at once: that is fine, map it to gone. |
| cancel | `qdel ID`; ignore "Unknown Job Id" and "Job has finished" |
| job env | `PBS_JOBID`, `PBS_O_WORKDIR`, `PBS_NODEFILE` (one line per rank; `sort -u \| paste -sd,` for `JW_NODELIST`), `PBS_QUEUE` |
| launcher env | no-op (`mpirun`/`mpiexec` read `PBS_NODEFILE`); `LAUNCHER` comes from the cluster config |
| walltime | `HH:MM:SS` with hours = days*24+HH (PBS rejects `2-00:00:00`) |
| memory | per chunk, `:mem=16gb` inside the `select` line; `jw_sched_header mem` prints nothing and the template embeds `@REP{MEM}` |
| headers | `#PBS -q`, `#PBS -A`, `#PBS -l place=scatter:excl` (exclusive) vs `#PBS -l place=scatter` (always one of them), `#PBS -M addr` + `#PBS -m a` (PBS has no mail-on-nonzero-exit; JobWatcher's own fail mail covers it), extra verbatim |
| trailer | `cd "${PBS_O_WORKDIR:?}" && exec bash ../.sim_data/jw_job.sh > "stdout_${PBS_JOBID%%.*}.out" 2>&1` (the job starts in `$HOME`; the PBS stdout file is staged back only at the end) |
| time-limit text | `=>> PBS: job killed: walltime` appears in the job stderr, not in the Cactus output, so the regex may print nothing; the run is then classified by the missing termination checkpoint |

Template `templates/pbs/sub.template`:

```
#!/bin/bash
@REP{HEADER_PARTITION}
@REP{HEADER_ACCOUNT}
#PBS -l walltime=@REP{WALLTIME}
#PBS -l select=@REP{NODES}:ncpus=@REP{CPUS_PER_NODE}:mpiprocs=@REP{TASKS_PER_NODE}:ompthreads=@REP{CPUS_PER_TASK}@REP{MEM}
@REP{HEADER_EXCLUSIVE}
#PBS -N @REP{SIMNAME}_R@REP{RUN}
#PBS -j oe
#PBS -o pbs.out
@REP{HEADER_MAIL}
@REP{HEADER_EXTRA}
@REP{JW_EXEC}
```

Things to establish on the real system before trusting the backend:

- Does a job start as a login shell (so `~/.bash_profile` runs)? If not, `ENV_INIT` and
  `SETUP_SCRIPT` in the cluster config must do all environment work; they already can.
- May a job submit another job from a compute node (`qsub` on the node, `pbs.conf` present,
  server `acl_hosts`)? If not, set `MASTERNODE` so that `jw_sched_cmd` falls back to ssh.
- What happens to a dependent job when its parent is killed by the walltime, is `qdel`ed while
  queued, or exits non-zero: the server should delete it (PBS semantics). Confirm.
- Is job history enabled, and what does `qstat` print for a finished job with and without `-x`.
- Where does the `-o` file land when the job was submitted from a compute node (`PBS_O_HOST`
  is the node): with the trailer redirecting `jw_job.sh` itself, nothing important depends on
  it, but check it does not fail the job.
- The exact spelling of memory (`mem=16gb`), and whether `place=scatter` is needed to get one
  chunk per node.

### 3.2 Torque `lib/sched/torque.sh`

Source `pbs.sh` and override: `JW_SCHED_NAME=torque`; `jw_sched_state` uses `qstat -f` (Torque's
`-x` means XML) and maps `C` to gone (jobs stay `C` for `keep_completed` seconds); `jw_sched_header
mem` prints `#PBS -l mem=` (verify whether per job or per node on that site) and `exclusive`
prints `#PBS -n`; template uses `#PBS -l nodes=@REP{NODES}:ppn=@REP{CPUS_PER_NODE}`. Torque
has no ranks-versus-threads notion, so the cluster config must carry ranks per node in the
launcher, e.g. `LAUNCHER='mpirun -npernode 8'`. (A later improvement: let `LAUNCHER` reference
config variables and `eval` it in `jw_job.sh`.)

### 3.3 Cluster config and user-facing pieces

- `clusters/<name>.conf` for the PBS cluster with `SCHEDULER=pbs`, queue names, cores per
  node, launcher, `ENV_INIT`, `MASTERNODE`; keep the cluster-specific comments there, not in
  the code or README.
- `bin/jw`: `write_config` writes `SBATCH_EXPORT`; add the PBS knob (e.g. `QSUB_OPTS`) the same
  way if the backend has one, or make `write_config` emit backend knobs through a backend
  function.
- README: the "What JobWatcher assumes about Slurm" section gets a sibling for PBS, or is
  rewritten as a per-scheduler table. Keep it for new users: no site names, no personal paths.

### 3.4 Tests

`tests/fakeslurm` is Slurm-only. The design's section 5 describes the intended shape: one
neutral queue engine (`tests/lib/fakequeue.sh`: job files with state, rc, dependency,
kill-on-invalid flag, spooled script, cwd, output path; `runqueue`, `forget`, `timeout`, `mail`)
with thin front ends `tests/fake/slurm`, `tests/fake/pbs` (later `lsf`), and `run_tests.sh`
running the scenario suite once per backend with per-backend expectation strings in
`tests/expect/<sched>.sh`. Minimum the PBS front end must emulate for scenarios A to E:

- `qsub` parses `-W depend=afterok:ID`, prints `<n>.fake`, rejects unknown options and
  unknown dependency ids, spools the script, records that the job inherits nothing unless
  `-V`; dependents of a failed or cancelled parent are deleted (PBS semantics).
- `qstat -x -f ID` prints `job_state = Q|H|R|F` (dependents of a running parent show `H`);
  unknown id gives `qstat: Unknown Job Id` with rc 153; a switch (`FAKE_PBS_HISTORY=no`) makes
  finished jobs unknown at once.
- `qdel`; a passthrough `mpiexec`.
- `runqueue` starts the job with `PBS_JOBID=<n>.fake PBS_O_WORKDIR PBS_NODEFILE PBS_QUEUE` and
  **cwd set to a fake `$HOME`**, which catches a trailer that forgets to cd.
- Assertions in `run_tests.sh` that grep Slurm strings (`#SBATCH --mem=4G`, `--time=1:00:00`,
  `--partition`, `--account`, `SBATCH_EXPORT=NONE`, the `SLURM_EXPORT_ENV` grep, `stdout_*.out`)
  become per-backend expectations.

While generalising, close the gaps in the current fake: it ignores `--export=NONE`, accepts
unknown options, never parses the `#SBATCH` header, hard-codes the stdout file name, records
but never honours `--kill-on-invalid-dep`, and cannot run a job in the background, so
`jw stop` against a running job and `jw stop --kill` are untested.

### 3.5 Acceptance

- `tests/run_tests.sh` green for slurm and pbs (and torque if done).
- On the real PBS system: `jw setup`, `jw start` with `QUEUE_DEPTH=1`, a run that terminates
  by walltime margin and hands over to its successor, `jw stop` cancelling the queued
  successor, `jw resume` after a deliberate failure, and `jw status` showing sensible states
  throughout. Record what was verified and what was not in the README's scheduler section.
- The Slurm suite and a rendered Slurm batch script are unchanged.

## 4. Stage 3: LSF

Same procedure. The points that differ from PBS, from the design's mapping table:

- `bsub` reads the script from **stdin** (`bsub < sub`; `#BSUB` lines in a script given as an
  argument are ignored). `jw_sched_cmd` therefore needs a `--stdin FILE` option that also works
  through the ssh fallback (`cd dir && bsub ... < FILE` on the remote side).
- Submit with `-env none -L /bin/bash` so the successor does not inherit the parent job's
  `LSB_*` and module environment (the problem `--export=NONE` solved on Slurm); expose these
  as a `BSUB_OPTS` default so a cluster can change them.
- Dependency `-w 'done(ID)' -ti`: without `-ti` (LSF before 9.1.3) a successor whose
  predecessor died without running the finish code stays PEND forever; `jw resume` then
  refuses until `jw stop`. Document this.
- State: `bjobs -a -noheader -o stat ID` (fallback: parse `bjobs -a ID`); `PEND PSUSP WAIT`
  queued, `RUN USUSP SSUSP` running, `DONE EXIT` gone; "Job <ID> is not found" means gone
  (after `CLEAN_PERIOD`).
- Job env: `LSB_JOBID`, `LS_SUBCWD`, hosts from `LSB_DJOB_HOSTFILE` or `LSB_MCPU_HOSTS`,
  `LSB_QUEUE`; the job starts in the submit directory.
- Walltime `-W` in minutes (round up); slots not ranks: `-n N*T*C -R "span[ptile=T*C]"` and a
  launcher that places ranks per node; memory via `-R "rusage[mem=MB]"` whose unit and
  per-slot/per-host meaning depend on site settings; account is `-P`; mail `-u addr -N`
  (end report, any outcome); output `-o stdout_%J.out` written at job end.
- Time-limit text `TERM_RUNLIMIT` is in the job report, not the Cactus output.

## 5. Working conventions in this repository

- Run `tests/run_tests.sh` before every commit; it must stay green.
- Never run `git push`, `git pull` or `git fetch`; the owner runs them. Commit when asked.
- The README is for new users of JobWatcher: generic paths and clone instructions, no site
  names, personal directories or references to superseded tools. Cluster-specific facts and
  comments belong in `clusters/<name>.conf`.
- No compatibility shims for things that were never released: when a key or placeholder is
  renamed, rename it everywhere and let `jw sync` refresh existing simulations.
- JobWatcher never deletes, moves or prunes checkpoint files.
