#!/bin/bash
# jw_job.sh - runs inside the Slurm batch job, in a RunN directory.
#
# Sequence:
#   1. record start, refuse to run if STOP is present
#   2. verify the predecessor finished with state SUCCESS and that its termination checkpoint exists
#   3. queue QUEUE_DEPTH successors (afterok on this job, killed by Slurm if this job fails)
#   4. launch Cactus; its output goes to cactus_<jobid>.out
#   5. classify the outcome: SUCCESS / COMPLETE / FAILED, update status files, cancel successors when the chain ends
#   6. run POST_RUN_HOOK (archiving, data merging)
# Exit status 0 only for SUCCESS, COMPLETE or STOPPED; anything else is non-zero so afterok dependents never start.

set -uo pipefail

RUNDIR=$(cd "${SLURM_SUBMIT_DIR:-$PWD}" && pwd -P) || exit 1
cd "$RUNDIR" || exit 1
SIMDIR=$(cd .. && pwd -P)
. "$SIMDIR/.sim_data/jw_common.sh"
jw_load_sim "$SIMDIR" || { echo "jw_job: cannot load $SIMDIR/.sim_data/config" >&2; exit 1; }

RUN=$(jw_run_index "$RUNDIR")
JOBID=${SLURM_JOB_ID:-nojob}
STATUS=$RUNDIR/status
CACTUS_OUT=cactus_${JOBID}.out
T_START=$(date +%s)

echo "$JOBID" > .jobid
jw_status_set "$STATUS" state=RUNNING jobid="$JOBID" start="$T_START" nodes="${SLURM_JOB_NODELIST:-}" jw_version="$JW_VERSION"
jw_log "Run$RUN" "$JOBID" START "nodes=${SLURM_JOB_NODELIST:-?} partition=${SLURM_JOB_PARTITION:-?}"
echo "JobWatcher $JW_VERSION  sim=$SIMNAME run=$RUN job=$JOBID nodes=${SLURM_JOB_NODELIST:-?} $(date)"

mail_body() {               # <headline>
  cat <<EOT
$1

Simulation : $SIMNAME
Run        : Run$RUN   (job $JOBID)
Directory  : $RUNDIR
Nodes      : ${SLURM_JOB_NODELIST:-?}
Iteration  : ${ITER:-?}   (previous ${LAST:-?})
Sim time   : ${STIME:-?}
Elapsed    : $(( $(date +%s) - T_START )) s
Reason     : ${REASON:-}
EOT
}

finish() {                  # <state> <reason> <exit-code>
  local state=$1; REASON=$2; local rc=$3
  jw_status_set "$STATUS" state="$state" reason="$REASON" end="$(date +%s)" iter="${ITER:-}" time="${STIME:-}"
  jw_log "Run$RUN" "$JOBID" "$state" "$REASON"
  case $state in
    SUCCESS) ;;                                          # successors stay queued
    *)       jw_cancel_successors "$RUN" ;;              # COMPLETE, FAILED, STOPPED: chain ends here
  esac
  case $state in
    FAILED)
      { mail_body "JobWatcher: $SIMNAME Run$RUN FAILED: $REASON"
        echo; echo "---- last 60 lines of $CACTUS_OUT ----"; tail -n 60 "$CACTUS_OUT" 2>/dev/null
      } | jw_mail fail "[jw] $SIMNAME Run$RUN FAILED" ;;
    COMPLETE) mail_body "JobWatcher: simulation $SIMNAME is COMPLETE after Run$RUN" | jw_mail complete "[jw] $SIMNAME COMPLETE (Run$RUN)" ;;
    SUCCESS)  mail_body "JobWatcher: $SIMNAME Run$RUN finished; chain continues" | jw_mail success "[jw] $SIMNAME Run$RUN ok (iteration ${ITER:-?})" ;;
    STOPPED)  mail_body "JobWatcher: $SIMNAME Run$RUN did not run: $REASON" | jw_mail stopped "[jw] $SIMNAME Run$RUN stopped" ;;
  esac
  echo "jw_job: Run$RUN $state: $REASON"
  exit "$rc"
}
fail() { finish FAILED "$1" 1; }

# ---------------------------------------------------------------- 1. STOP
[ -e "$SIMDIR/STOP" ] && finish STOPPED "STOP file present in $SIMDIR" 0

# ---------------------------------------------------------------- 2. predecessor
LAST=$(cat "$SIMDIR/.sim_data/last" 2>/dev/null); LAST=${LAST:-0}
PREV_DIR="$SIMDIR/Run$(( RUN - 1 ))"
if (( RUN > 1 )); then
  PSTATE=$(jw_status_get "$PREV_DIR/status" state)
  [ "$PSTATE" = SUCCESS ] || fail "predecessor Run$(( RUN - 1 )) has state '${PSTATE:-none}', expected SUCCESS"
  PITER=$(jw_status_get "$PREV_DIR/status" iter)
  CK=$(jw_latest_checkpoint_iter)
  [ -n "$CK" ] || fail "no checkpoint files found in $CHECKPOINT_DIR"
  if [[ $PITER =~ ^[0-9]+$ && $CK =~ ^[0-9]+$ ]] && (( 10#$CK != 10#$PITER )); then
    if [ "$STRICT_CHECKPOINT" = yes ]; then
      fail "newest checkpoint is iteration $CK but predecessor terminated at $PITER (STRICT_CHECKPOINT=yes)"
    else
      jw_warn "newest checkpoint is iteration $CK, predecessor terminated at $PITER; recovering from $CK"
    fi
  fi
else
  CK=$(jw_latest_checkpoint_iter)
  [ -n "$CK" ] && jw_warn "Run1 but $CHECKPOINT_DIR already holds a checkpoint at iteration $CK; Cactus will recover from it"
fi
[ -x "./$EXE" ]   || fail "executable ./$EXE missing or not executable"
[ -r "./$PARFILE" ] || fail "parameter file ./$PARFILE missing"

# ---------------------------------------------------------------- 3. successors
if (( RUN >= MAX_RUNS )); then
  jw_info "Run$RUN reaches MAX_RUNS=$MAX_RUNS; no successor will be queued"
else
  jw_ensure_successors "$RUN" "$JOBID" || jw_warn "could not queue all successors (see above); this run continues"
fi

# ---------------------------------------------------------------- 4. launch
# Jobs are submitted with --export=$SBATCH_EXPORT (NONE by default: Slurm then gives the job a
# fresh login environment instead of a copy of the submitter's, so every run sees the same
# environment whether it was submitted from the login node or from its predecessor's job).
# ENV_INIT (cluster config) runs first, e.g. to define `module`; then SETUP_SCRIPT; then EXTRA_ENV.
[ -n "$ENV_INIT" ] && eval "$ENV_INIT"
if [ -n "$SETUP_SCRIPT" ]; then
  # shellcheck disable=SC1090
  source "$SETUP_SCRIPT" > "env_setup_${JOBID}.log" 2>&1 || jw_warn "sourcing $SETUP_SCRIPT returned non-zero (see env_setup_${JOBID}.log)"
fi
export OMP_NUM_THREADS=$CPUS_PER_TASK OMP_PROC_BIND OMP_PLACES
[ -n "$EXTRA_ENV" ] && eval "$EXTRA_ENV"
# sbatch --export=NONE leaves SLURM_EXPORT_ENV=NONE in the job, and srun would then start the
# Cactus tasks with an empty environment (no HOME, no PATH: MPI startup fails). The tasks must
# get the environment built above, so tell srun to export everything.
export SLURM_EXPORT_ENV=ALL
env | sort > "env_${JOBID}.txt"
echo "environment: $(wc -l < "env_${JOBID}.txt") variables, module=$(type -t module 2>/dev/null || echo undefined), SPACK_ENV=${SPACK_ENV:-unset}, unresolved shared libraries of ./$EXE: $(ldd "./$EXE" 2>/dev/null | grep -c 'not found') (env_${JOBID}.txt, env_setup_${JOBID}.log)"
{ mail_body "JobWatcher: $SIMNAME Run$RUN started" ; } | jw_mail start "[jw] $SIMNAME Run$RUN started"

echo "launch: $LAUNCHER ./$EXE $PARFILE  (OMP_NUM_THREADS=$OMP_NUM_THREADS) at $(date)"
T_LAUNCH=$(date +%s)
$LAUNCHER "./$EXE" "$PARFILE" > "$CACTUS_OUT" 2>&1
RC=$?
echo "launcher exit code $RC after $(( $(date +%s) - T_LAUNCH )) s at $(date)"

# ---------------------------------------------------------------- 5. classify
ITER=""; STIME=""
if TERM_INFO=$(jw_term_checkpoint "$CACTUS_OUT"); then ITER=${TERM_INFO%% *}; STIME=${TERM_INFO#* }; [ "$STIME" = "$TERM_INFO" ] && STIME=""; fi

if [ -z "$ITER" ]; then
  if grep -q 'DUE TO TIME LIMIT' "$CACTUS_OUT" 2>/dev/null; then
    fail "killed by Slurm time limit before writing a termination checkpoint (launcher rc=$RC); lower cactus::max_runtime or raise RUNTIME_MARGIN_MIN"
  fi
  fail "no termination checkpoint announced in $CACTUS_OUT (driver $DRIVER, launcher rc=$RC): crash, kill, or IO::checkpoint_on_terminate is not yes"
fi
[ "$RC" -eq 0 ] || fail "termination checkpoint at iteration $ITER but launcher exited with code $RC"
CKPT_METHOD=$(jw_par_get "$PARFILE" 'CarpetX::checkpoint_method' | tr 'A-Z' 'a-z')
WRITE_PROBLEM=$(jw_term_write_ok "$CACTUS_OUT" "$ITER" "${CKPT_METHOD:-openpmd}") || fail "termination checkpoint at iteration $ITER was announced but $WRITE_PROBLEM"
jw_checkpoint_exists "$ITER" || fail "termination checkpoint at iteration $ITER was announced but no file matching $(jw_checkpoint_pattern) exists for it in $CHECKPOINT_DIR"

# Did the simulation reach its final iteration/time?  (cactus::terminate = iteration | time | any | all | runtime | never)
TERM_MODE=$(jw_par_get "$PARFILE" 'cactus::terminate' | tr 'A-Z' 'a-z')
ITLAST=$(jw_num "$(jw_par_value "$PARFILE" 'cactus::cctk_itlast')")
FTIME=$(jw_num "$(jw_par_value "$PARFILE" 'cactus::cctk_final_time')")
# non-positive limits mean "no such condition"
[ -n "$ITLAST" ] && ! awk "BEGIN{exit !($ITLAST > 0)}" && ITLAST=""
[ -n "$FTIME" ]  && ! awk "BEGIN{exit !($FTIME > 0)}"  && FTIME=""
complete_iter=no; complete_time=no
[ -n "$ITLAST" ] && awk "BEGIN{exit !($ITER >= $ITLAST)}" && complete_iter=yes
[ -n "$FTIME" ] && [ -n "$STIME" ] && awk "BEGIN{exit !($STIME >= $FTIME)}" && complete_time=yes
COMPLETE=no
case $TERM_MODE in
  iteration) COMPLETE=$complete_iter ;;
  time)      COMPLETE=$complete_time ;;
  any)       { [ $complete_iter = yes ] || [ $complete_time = yes ]; } && COMPLETE=yes ;;
  all)       [ $complete_iter = yes ] && [ $complete_time = yes ] && COMPLETE=yes ;;
esac
PROGRESS=$(( ITER - LAST ))

if [ "$COMPLETE" = yes ]; then
  finish_state=COMPLETE; finish_reason="final condition reached (terminate=$TERM_MODE, iteration $ITER, time $STIME)"
elif (( PROGRESS < MIN_PROGRESS )); then
  fail "only $PROGRESS iterations of progress (from $LAST to $ITER), MIN_PROGRESS=$MIN_PROGRESS; if the simulation is finished set cactus::terminate/cctk_final_time or run 'jw stop'"
else
  finish_state=SUCCESS; finish_reason="iteration $LAST -> $ITER (+$PROGRESS), time $STIME"
fi
echo "$ITER" > "$SIMDIR/.sim_data/last"
echo "$ITER $STIME Run$RUN $JOBID $(date +%s)" >> "$SIMDIR/.sim_data/last.history"

# ---------------------------------------------------------------- 6. hook
if [ -n "$POST_RUN_HOOK" ]; then
  if [ -x "$POST_RUN_HOOK" ]; then
    echo "hook: $POST_RUN_HOOK $RUNDIR $finish_state"
    if ! "$POST_RUN_HOOK" "$RUNDIR" "$finish_state" > "hook_${JOBID}.out" 2>&1; then
      jw_log "Run$RUN" "$JOBID" HOOK-FAIL "$POST_RUN_HOOK (see hook_${JOBID}.out)"
      [ "$HOOK_FAILURE_FATAL" = yes ] && fail "POST_RUN_HOOK failed (run itself was $finish_state at iteration $ITER)"
      jw_warn "POST_RUN_HOOK failed; see $RUNDIR/hook_${JOBID}.out"
    fi
  else
    jw_warn "POST_RUN_HOOK=$POST_RUN_HOOK is not executable; skipped"
  fi
fi

finish "$finish_state" "$finish_reason" 0
