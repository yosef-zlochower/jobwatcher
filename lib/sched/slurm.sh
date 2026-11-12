#!/bin/bash
# slurm.sh - JobWatcher scheduler backend for Slurm.
#
# Sourced by jw_common.sh (jw_load_sched) on the login node and inside the job; copied into
# <simdir>/.sim_data/jw_sched.sh by `jw setup` and `jw sync`. Every backend defines the same
# set of jw_sched_* functions; the contract is described in docs/scheduler-backends.md.
# Scheduler commands go through jw_sched_cmd (jw_common.sh), which adds the ssh fallback.

JW_SCHED_NAME=slurm

# Defaults for keys only this backend reads, applied after the config files.
jw_sched_defaults() {
  : "${LAUNCHER:=srun}"
  : "${SBATCH_EXPORT:=NONE}"      # --export for sbatch: NONE gives every job a fresh login environment
}

# jw_sched_submit <script> [<dep-jobid>]: submit <script> from the current directory (the run
# directory); with <dep-jobid> the job starts only after that job exited 0 and Slurm kills it
# when that can never happen. Prints the job id; rc 1 and a message on stderr on failure.
jw_sched_submit() {
  local script=$1 dep=${2:-} out opts=()
  [ -n "$dep" ] && opts=(--dependency=afterok:"$dep" --kill-on-invalid-dep=yes)
  out=$(jw_sched_cmd sbatch --parsable --export="$SBATCH_EXPORT" "${opts[@]}" "$script") || return 1
  out=${out%%;*}                                   # --parsable may append ;<cluster>
  jw_sched_jobid_ok "$out" || { jw_warn "sbatch returned unexpected output: $out"; return 1; }
  echo "$out"
}

# jw_sched_cancel <jobid>: idempotent; succeeds also when the job is already gone.
jw_sched_cancel() { [ -n "$1" ] && jw_sched_cmd scancel "$1" >/dev/null 2>&1; return 0; }

# jw_sched_state <jobid>: prints "<norm> <raw>" with norm in queued|running|gone|unknown, raw the
# scheduler's own state ("-" when the job is not known any more). rc 1 when the query itself
# failed, so that "gone" and "cannot tell" stay distinct.
jw_sched_state() {
  local out raw
  [ -n "$1" ] || { echo "gone -"; return 0; }
  if out=$(jw_sched_cmd squeue -h -j "$1" -o %T 2>&1); then
    raw=${out%%$'\n'*}
    case $raw in
      PENDING|CONFIGURING|REQUEUED|SUSPENDED)                  echo "queued $raw" ;;
      RUNNING|COMPLETING|RESIZING|SIGNALING|STAGE_OUT|REVOKED) echo "running $raw" ;;
      COMPLETED|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|PREEMPTED|BOOT_FAIL|DEADLINE|OUT_OF_MEMORY|SPECIAL_EXIT) echo "gone $raw" ;;
      "")                                                      echo "gone -" ;;
      *)                                                       echo "unknown $raw" ;;
    esac
    return 0
  fi
  # After MinJobAge the controller forgets a finished job and squeue -j fails with this message.
  [[ $out == *"Invalid job id specified"* ]] && { echo "gone -"; return 0; }
  printf '%s\n' "$out" >&2
  return 1
}

# jw_sched_job_env: inside a job, export the job's identity in scheduler-neutral variables.
# rc 1 when not inside a Slurm job.
jw_sched_job_env() {
  [ -n "${SLURM_JOB_ID:-}" ] || return 1
  export JW_IN_JOB=yes JW_JOBID=$SLURM_JOB_ID JW_JOBID_SHORT=$SLURM_JOB_ID \
         JW_SUBMIT_DIR=${SLURM_SUBMIT_DIR:-$PWD} JW_NODELIST=${SLURM_JOB_NODELIST:-} JW_QUEUE=${SLURM_JOB_PARTITION:-}
}

# jw_sched_launcher_env: called just before $LAUNCHER starts the executable. sbatch --export=NONE
# leaves SLURM_EXPORT_ENV=NONE in the job, and srun would then start the tasks with an empty
# environment (no HOME, no PATH: MPI startup fails); tell srun to pass on the environment the
# job built (ENV_INIT, SETUP_SCRIPT, OMP_*, EXTRA_ENV).
jw_sched_launcher_env() { export SLURM_EXPORT_ENV=ALL; }

# Value formatting: Slurm's own spellings are JobWatcher's canonical ones.
jw_sched_walltime() { echo "$1"; }                # [D-]HH:MM:SS
jw_sched_mem()      { echo "$1"; }                # e.g. 16G

# jw_sched_header <item>: the complete directive line(s) for one optional item, or nothing when
# the corresponding key is unset. Items: partition account qos mem mail exclusive extra.
jw_sched_header() {
  case $1 in
    partition) [ -n "$PARTITION" ] && echo "#SBATCH --partition=$PARTITION" ;;
    account)   [ -n "$ACCOUNT" ]   && echo "#SBATCH --account=$ACCOUNT" ;;
    qos)       [ -n "$QOS" ]       && echo "#SBATCH --qos=$QOS" ;;
    mem)       [ -n "$MEM" ]       && echo "#SBATCH --mem=$MEM" ;;
    mail)      [ -n "$MAIL" ]      && { echo "#SBATCH --mail-user=$MAIL"; echo "#SBATCH --mail-type=$MAIL_TYPE"; } ;;
    exclusive) [ "$EXCLUSIVE" = yes ] && echo "#SBATCH --exclusive" ;;
    extra)     [ -n "$HEADER_EXTRA" ] && printf '%s\n' "$HEADER_EXTRA" ;;
  esac
  return 0
}

# jw_sched_exec_line: the last line of the batch script: go to the run directory and hand over
# to the frozen job logic. Slurm starts the script in the submit directory already.
jw_sched_exec_line() { echo 'cd "${SLURM_SUBMIT_DIR:?}" && exec bash ../.sim_data/jw_job.sh'; }

# jw_sched_timelimit_regex: text in the launcher output meaning "killed by the time limit".
jw_sched_timelimit_regex() { echo 'DUE TO TIME LIMIT'; }

jw_sched_jobid_ok() { [[ $1 =~ ^[0-9]+$ ]]; }
