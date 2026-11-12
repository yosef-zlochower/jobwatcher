# Supporting other batch schedulers: design

Status: design written 2026-11-12; stage 1 (section 6) is implemented, so Slurm now sits behind
the backend interface of section 3 in `lib/sched/slurm.sh`. Stages 2 and 3 (PBS Pro/OpenPBS,
Torque, LSF) are open; EXTENDING_JOBWATCHER.md is the hand-over for them. This document
describes the interface, what each scheduler does differently, and the test-harness plan.
Section 1 records where Slurm was baked in before stage 1 and is kept for the history.

## 1. Where Slurm was baked in before stage 1

Everything scheduler-specific is confined to a few places; the Cactus side (parfile adaptation,
checkpoint detection, outcome classification, status files, hooks) is already neutral.

| Place | What |
|---|---|
| `lib/jw_common.sh` `jw_slurm` | runs a scheduler command, ssh fallback to `MASTERNODE` when inside a job (detected via `SLURM_JOB_ID`) |
| `jw_sbatch` | `sbatch --parsable --export=$SBATCH_EXPORT`, strips `;cluster`, requires a numeric id |
| `jw_job_state`, `jw_job_in_queue` | `squeue -h -j ID -o %T`; "Invalid job id specified" means gone; Slurm state vocabulary |
| `jw_scancel` | `scancel` |
| `jw_submit_run` | `--dependency=afterok:ID --kill-on-invalid-dep=yes`; the option text is written to `chain.log` |
| `jw_prepare_run` | builds the optional `#SBATCH` lines (`SBATCH_PARTITION`, `SBATCH_ACCOUNT`, `SBATCH_QOS`, `SBATCH_MEM`) and the placeholder list of `sub.template`; passes `WALLTIME` unconverted |
| `jw_apply_defaults` | `LAUNCHER=srun`, `SBATCH_EXTRA`, `SBATCH_EXPORT`, `SLURM_MAIL_TYPE`, walltime grammar `[D-]HH:MM:SS` |
| `lib/jw_job.sh` | reads `SLURM_SUBMIT_DIR`, `SLURM_JOB_ID`, `SLURM_JOB_NODELIST`, `SLURM_JOB_PARTITION`; `export SLURM_EXPORT_ENV=ALL` before `srun`; greps `DUE TO TIME LIMIT` |
| `templates/slurm/sub.template` | `#SBATCH` directives, `--output=stdout_%j.out` (the `stdout_<id>.out` name is relied on elsewhere), trailer `exec bash "${SLURM_SUBMIT_DIR:-$PWD}/../.sim_data/jw_job.sh"` |
| `bin/jw` | copies lib + template into `.sim_data`; prompts and messages say Slurm; `cmd_status` column `SLURM`; `cmd_resume` "cannot query Slurm" |
| `tests/` | `fakeslurm` emulates `sbatch squeue scancel srun mail`; several assertions grep Slurm strings (`afterok`, `#SBATCH --mem=4G`, `--time=`, `SBATCH_EXPORT=NONE`, `SLURM_EXPORT_ENV`) |

Functions that mix chain logic with Slurm calls and must be split: `jw_submit_run`,
`jw_prepare_run`, `jw_ensure_successors` (wording), `jw_cancel_successors`, the prologue and
launch section of `jw_job.sh`, `cmd_setup`/`cmd_sync` (copy lists), `cmd_status`/`cmd_resume`
(wording).

## 2. Backend interface

Selection: `SCHEDULER=<name>` in the cluster config (default `slurm`). Backend file
`lib/sched/<name>.sh`, copied into `<simdir>/.sim_data/jw_sched.sh` by `jw setup` and
`jw sync` so that a simulation is frozen with its backend like it is with `jw_job.sh`.

Loader (`jw_load_sched`, in `jw_common.sh`): source the frozen backend if present, else
`$JW_HOME/lib/sched/$SCHEDULER.sh`; check `JW_SCHED_NAME` matches and that every function
below exists, so a half-written backend fails at load, not mid-chain.

```bash
JW_SCHED_NAME=slurm

jw_sched_defaults              # backend defaults: LAUNCHER, SBATCH_EXPORT / QSUB_OPTS / BSUB_OPTS ...
jw_sched_submit <script> [<dep-jobid>]
                               # cwd = run dir. stdout: native job id, rc 0; rc 1 + stderr on failure.
                               # Contract: clean login environment for the job (never the submitter's);
                               # with dep: start only after that job exited 0, and have the scheduler
                               # remove the job when that can never happen, where it can express it.
jw_sched_cancel <jobid>        # idempotent; rc 0 also when the job is gone
jw_sched_state <jobid>         # stdout "<norm> <raw>": norm in queued|running|gone|unknown; rc 1 = query failed
jw_sched_job_env               # inside the job: export JW_JOBID, JW_JOBID_SHORT ([0-9]+, for file names),
                               # JW_SUBMIT_DIR, JW_NODELIST, JW_QUEUE from the native variables
jw_sched_launcher_env          # inside the job, before $LAUNCHER (Slurm: SLURM_EXPORT_ENV=ALL); may be a no-op
jw_sched_walltime <canonical>  # [D-]HH:MM:SS -> the scheduler's spelling
jw_sched_mem <spec>            # "16G" -> the scheduler's spelling
jw_sched_header <item>         # partition|account|qos|mem|mail|exclusive|extra -> complete directive line(s), or nothing
jw_sched_exec_line             # the template trailer: cd to the run dir and exec jw_job.sh
jw_sched_timelimit_regex       # pattern in the launcher output that means "killed by the time limit"; may be empty
jw_sched_jobid_ok <string>     # plausibility check of a job id
```

Stays generic in `jw_common.sh`: `jw_slurm` renamed `jw_sched_cmd` (gains `--stdin FILE` for
`bsub < script`, and tests `JW_JOBID` instead of `SLURM_JOB_ID`), `jw_job_state`/`jw_job_in_queue`
as thin wrappers with today's 0/1/2 contract, `jw_walltime_minutes`, `jw_mail`,
`jw_fill_template`, status files, checkpoints, parfile code, the chain functions.

Config keys: generic concepts get generic names read by the chain code (`SCHEDULER`,
`PARTITION`, `WALLTIME` canonical, `NODES`, `TASKS_PER_NODE`, `CPUS_PER_TASK`, `MEM` canonical,
`ACCOUNT`, `QOS`, `EXCLUSIVE`, `MAIL`, `MAIL_TYPE`, `HEADER_EXTRA`, `LAUNCHER`). Scheduler-only
knobs keep a native prefix and are read only by their backend (`SBATCH_EXPORT`, `QSUB_OPTS`,
`BSUB_OPTS`). Today's `SBATCH_EXTRA` and `SLURM_MAIL_TYPE` become `HEADER_EXTRA` and `MAIL_TYPE`.

## 3. Templates and placeholders

```
templates/<scheduler>/sub.template        shipped, one per scheduler
clusters/<name>.sub.template              optional complete override next to the cluster config
```

Lookup order: `SUB_TEMPLATE=<path>` from the config chain, else the cluster override, else
`templates/$SCHEDULER/sub.template`. The chosen source is recorded in `.sim_data/config`.

Placeholders every template may use (`jw_prepare_run` always offers all of them):

| Kind | Placeholders |
|---|---|
| values | `SIMNAME RUN SIMDIR RUNDIR EXE PARFILE PARTITION NODES TASKS_PER_NODE CPUS_PER_TASK CPUS_PER_NODE NTASKS NSLOTS MAIL MAIL_TYPE ACCOUNT QOS` |
| scheduler-formatted | `WALLTIME` (via `jw_sched_walltime`), `MEM` (via `jw_sched_mem`), plus `WALLTIME_RAW`, `MEM_RAW` |
| whole directive lines, empty when unset | `HEADER_PARTITION HEADER_ACCOUNT HEADER_QOS HEADER_MEM HEADER_MAIL HEADER_EXCLUSIVE HEADER_EXTRA` |
| trailer | `JW_EXEC` |

Why generic names rather than `SBATCH_*`: the placeholder vocabulary is the contract between
`jw_prepare_run` and every template, including cluster overrides, so there should be one
vocabulary and the chain code should not know a scheduler's name. The directory already says
which scheduler a template is for. The current `SBATCH_PARTITION/ACCOUNT/QOS/MEM` names would
be renamed in stage 1; simulations created before that get the new template with `jw sync`.

Shipped Slurm template after stage 1 (same output as today):

```
#!/bin/bash
@REP{HEADER_PARTITION}
@REP{HEADER_ACCOUNT}
@REP{HEADER_QOS}
#SBATCH --time=@REP{WALLTIME}
#SBATCH --nodes=@REP{NODES}
#SBATCH --ntasks-per-node=@REP{TASKS_PER_NODE}
#SBATCH --cpus-per-task=@REP{CPUS_PER_TASK}
@REP{HEADER_MEM}
@REP{HEADER_EXCLUSIVE}
#SBATCH --job-name=@REP{SIMNAME}_R@REP{RUN}
#SBATCH --output=stdout_%j.out
@REP{HEADER_MAIL}
@REP{HEADER_EXTRA}
@REP{JW_EXEC}
```

Trailers (`jw_sched_exec_line`); `jw_job.sh` then takes `RUNDIR=$(pwd -P)`:

```
slurm : cd "${SLURM_SUBMIT_DIR:?}" && exec bash ../.sim_data/jw_job.sh
pbs   : cd "${PBS_O_WORKDIR:?}"   && exec bash ../.sim_data/jw_job.sh > "stdout_${PBS_JOBID%%.*}.out" 2>&1
lsf   : cd "${LS_SUBCWD:?}"       && exec bash ../.sim_data/jw_job.sh
```

## 4. Scheduler mapping

"verify" marks behaviour that must be checked on a real installation before relying on it.

| Item | Slurm | PBS Pro / OpenPBS | Torque | LSF |
|---|---|---|---|---|
| submit | `sbatch --parsable --export=NONE sub` | `qsub sub` | `qsub sub` | `bsub -env none -L /bin/bash < sub` (`#BSUB` lines are parsed from stdin only, verify) |
| id format | `123` (strip `;cluster`) | `123.server` (keep whole string; short id for file names) | `123.server` | `Job <123> is submitted to queue <q>.` |
| dependency | `--dependency=afterok:ID --kill-on-invalid-dep=yes` | `-W depend=afterok:ID` | `-W depend=afterok:ID` | `-w 'done(ID)' -ti` (`-ti` needs LSF >= 9.1.3, verify) |
| parent fails or is killed | dependent killed (flag) | server deletes the dependent | same (verify) | stays PEND forever unless `-ti` |
| state query | `squeue -h -j ID -o %T` | `qstat -x -f ID`, `job_state =` | `qstat -f ID` (`-x` is XML there) | `bjobs -a -noheader -o stat ID` (fallback: parse `bjobs -a ID`) |
| state classes | PENDING...→queued; RUNNING, COMPLETING...→running; COMPLETED, FAILED, CANCELLED, TIMEOUT, NODE_FAIL...→gone | Q H W T→queued; R E S B→running; F X M→gone | as PBS, plus C→gone | PEND PSUSP WAIT→queued; RUN USUSP SSUSP→running; DONE EXIT→gone |
| "not known" (→ gone) | `Invalid job id specified` | `Unknown Job Id` | `Unknown Job Id` | `Job <ID> is not found` |
| finished jobs visible for | `MinJobAge` (300 s default) | only with `job_history_enable` (default off: vanish at once) | `keep_completed` seconds | `CLEAN_PERIOD` (3600 s default) |
| cancel | `scancel` | `qdel` | `qdel` | `bkill` |
| directive | `#SBATCH` | `#PBS` | `#PBS` | `#BSUB` |
| walltime | `[D-]HH:MM:SS` as is | `-l walltime=HH:MM:SS` (hours may exceed 24) | same | `-W [HH:]MM`, minutes, round up |
| nodes/tasks/threads | `--nodes --ntasks-per-node --cpus-per-task` | `-l select=N:ncpus=T*C:mpiprocs=T:ompthreads=C -l place=scatter` | `-l nodes=N:ppn=T*C` (launcher must place T ranks/node) | `-n N*T*C -R "span[ptile=T*C]"` (launcher places ranks) |
| exclusive | `--exclusive` | `-l place=scatter:excl` | `-n` (verify) | `-x` |
| memory | `--mem=16G` per node | chunk `:mem=16gb` | `-l mem=` / `-l pmem=` (verify semantics) | `-R "rusage[mem=MB]"` (per slot or host, verify) |
| queue / account | `--partition` / `--account` | `-q` / `-A` | `-q` / `-A` | `-q` / `-P` |
| job stdout | `--output=stdout_%j.out`, live | `-o`, no `%j`, staged back at job end (so the trailer redirects `jw_job.sh` itself) | same | `-o stdout_%J.out`, written at job end |
| mail | `--mail-user --mail-type=FAIL` | `-M addr -m a` (aborted only; no mail on a plain non-zero exit) | same | `-u addr -N` (end report, any outcome) |
| clean environment | `--export=NONE` (fresh login env on the node) | default: nothing exported (login shell on Torque: yes; PBS Pro: verify) | default | `-env none` (verify availability) + `-L /bin/bash`; default `-env all` would leak the parent job's `LSB_*` |
| job env vars | `SLURM_JOB_ID SLURM_SUBMIT_DIR SLURM_JOB_NODELIST SLURM_JOB_PARTITION` | `PBS_JOBID PBS_O_WORKDIR PBS_NODEFILE PBS_QUEUE` | same | `LSB_JOBID LS_SUBCWD LSB_DJOB_HOSTFILE/LSB_MCPU_HOSTS LSB_QUEUE` |
| starting cwd | submit dir | `$HOME` (trailer must cd) | `$HOME` | submit dir |
| submit from a compute node | yes (client + munge on nodes) | client + `pbs.conf` on nodes; `acl_hosts` may restrict (verify per site) | `allow_node_submit=true` or `submit_hosts` | yes |
| launcher env | `SLURM_EXPORT_ENV=ALL` for `srun` | no-op; `mpirun`/`mpiexec` read `PBS_NODEFILE` | no-op; often `mpirun -npernode T` | no-op; `mpirun`/`blaunch`/`jsrun` |
| time-limit text | `DUE TO TIME LIMIT` in the step stderr | `=>> PBS: job killed: walltime` in the job stderr, not in the Cactus output | same | `TERM_RUNLIMIT` in the job report |

Semantic points that matter for the chain:

1. **Dependent after a parent that dies without running `finish()`** (walltime kill, node
   failure, manual cancel): Slurm kills it with our flag, PBS deletes it, LSF leaves it PEND
   unless `-ti`. On old LSF `jw status` shows a PEND successor and `jw resume` refuses until
   `jw stop`. `finish()` already cancels successors explicitly in every other case.
2. **Visibility after exit**: with PBS history disabled a job vanishes the instant it ends.
   The chain never depends on seeing a finished job (resume submits without a dependency when
   the predecessor is gone), so this only changes what `jw status` shows.
3. **Job starts in `$HOME`** on PBS/Torque: the trailer must `cd`, and `jw_job.sh` must not use
   `$PWD` at start.
4. **Output staging**: PBS/Torque/LSF write the batch stdout at the end, PBS possibly by scp to
   the submitting host (a compute node when a successor was queued from a job). `jw_job.sh`
   already writes its own files directly; the trailer should redirect its stdout too.
5. **Ranks vs slots**: Torque and slot-based LSF do not distinguish ranks from threads, so
   `LAUNCHER` must carry ranks per node (e.g. `mpirun -npernode $TASKS_PER_NODE`); evaluate
   `LAUNCHER` with the config variables available.
6. **Job ids with a dot** (PBS) widen status/log columns; file names use `JW_JOBID_SHORT`.
7. **Mail on failure** exists only on Slurm; JobWatcher's own `MAIL_EVENTS=fail` mail covers it.

## 5. Tests

One scheduler-neutral queue engine with thin per-scheduler front ends, not three fakes:

```
tests/
  run_tests.sh          unit + configure tests once; scenarios A-E once per backend
  lib/fakequeue.sh      engine: jobs/<n> (state, rc, dep, killdep, sched, spooled script, cwd, out), next_id,
                        runqueue [--one], forget ID (MinJobAge/CLEAN_PERIOD), timeout ID, mail
  fake/slurm            sbatch squeue scancel srun          (reject unknown options; honour --export; parse --output)
  fake/pbs              qsub qstat qdel mpiexec             (ids <n>.fake; job cwd = fake $HOME; dependents deleted on parent failure)
  fake/lsf              bsub bjobs bkill mpirun             (script from stdin; -ti decides whether dependents die)
  fakecactus            unchanged
  expect/<sched>.sh     per-backend strings: walltime/partition/mem lines, job-output glob, job-id regex, export key
  cluster.conf          neutral; run_tests.sh adds SCHEDULER and LAUNCHER per backend
```

Scenario bodies become functions parameterised by the work dir and the `expect` variables.
Assertions that grep Slurm text today (`afterok` in `chain.log`, `#SBATCH --mem=4G`,
`--time=1:00:00`, `SBATCH_EXPORT=NONE`, the `SLURM_EXPORT_ENV` source grep) move to the
expect files, and `chain.log` should record `after=<id>` instead of the raw option.

Gaps in today's fake worth closing while generalising: `--export=NONE` is ignored (the job
inherits the test environment), unknown `sbatch` options are accepted, `#SBATCH` headers are
never parsed, the stdout name is hard-coded, `--kill-on-invalid-dep` is recorded but not
honoured, nothing runs concurrently so `jw stop` against a running job and `jw stop --kill`
are untested, and the time-limit kill is simulated by hand-editing files.

## 6. Staged plan

| Stage | Content | Size |
|---|---|---|
| 1 | Slurm behind the interface, zero behaviour change: `lib/sched/slurm.sh`, generic keys and `HEADER_*` placeholders, `jw_sched_cmd`, `jw_job.sh` prologue/launch via the backend, `.sim_data/jw_sched.sh` frozen, `jw sync` copies four files (tmp + mv), tests green with the same assertions, a pre-refactor simulation still readable and upgradable with `jw sync` | ~350 lines, 5-7 h, plus one real short chain |
| 2 | PBS Pro/OpenPBS (`lib/sched/pbs.sh`, template) and Torque (small override of pbs), fake engine + `fake/pbs`, README | ~450 lines, 10-14 h, half of it validation on a real PBS system |
| 3 | LSF (`lib/sched/lsf.sh`, template, `fake/lsf`), `BSUB_OPTS` default `-env none -L /bin/bash` so a cluster can change it | ~350 lines, 8-12 h |

Main risks: stage 1, the rename of placeholders and keys for frozen simulations (test with a
copy of today's template) and queued jobs picking up a half-synced `.sim_data`; stage 2, the
"verify" items above, in particular PBS Pro's login-shell behaviour and output staging from
compute-node submissions; stage 3, `-env none`, `-ti` and `bjobs -o` availability on older LSF.
Stages 2 and 3 cannot be validated here (no PBS or LSF installation): they should ship as
"tested against the fake, assumptions listed".
