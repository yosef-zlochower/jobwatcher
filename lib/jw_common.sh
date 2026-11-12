#!/bin/bash
# jw_common.sh - shared functions for JobWatcher.
# Sourced by bin/jw (on the login node) and by jw_job.sh (inside the batch job).
# Requires bash >= 4.  Every function is prefixed jw_.

JW_VERSION=2.0

jw_die()  { echo "jw: ERROR: $*" >&2; exit 1; }
jw_warn() { echo "jw: WARNING: $*" >&2; }
jw_info() { echo "jw: $*" >&2; }

# ---------------------------------------------------------------- defaults
# Applied after the config files so that an old config missing a key still works.
jw_apply_defaults() {
  : "${MASTERNODE:=}"
  : "${PARTITION:=}" "${WALLTIME:=24:00:00}" "${NODES:=1}"
  : "${TASKS_PER_NODE:=1}" "${CPUS_PER_TASK:=1}" "${MEM:=}" "${ACCOUNT:=}" "${QOS:=}"
  : "${SCHEDULER:=slurm}"
  : "${CORES_PER_NODE:=$(( TASKS_PER_NODE * CPUS_PER_TASK ))}"
  : "${SETUP_SCRIPT:=}" "${LAUNCHER:=srun}"
  : "${OMP_PROC_BIND:=close}" "${OMP_PLACES:=cores}" "${EXTRA_ENV:=}" "${SBATCH_EXTRA:=}"
  : "${MAIL:=$USER}" "${SLURM_MAIL_TYPE:=FAIL}" "${MAIL_EVENTS:=fail,complete}"
  : "${MAX_RUNS:=100}" "${QUEUE_DEPTH:=1}" "${MIN_PROGRESS:=100}"
  : "${RUNTIME_MARGIN_MIN:=20}" "${STRICT_CHECKPOINT:=no}"
  : "${POST_RUN_HOOK:=}" "${HOOK_FAILURE_FATAL:=no}"
  : "${DRIVER:=carpet}" "${SBATCH_EXPORT:=NONE}" "${ENV_INIT:=}"
}

# ---------------------------------------------------------------- simulation
# jw_load_sim <simdir>: sources .sim_data/config and sets SIMDIR, CHECKPOINT_DIR.
jw_load_sim() {
  local d=$1
  [ -r "$d/.sim_data/config" ] || return 1
  SIMDIR=$(cd "$d" && pwd -P)
  . "$SIMDIR/.sim_data/config"
  jw_apply_defaults
  : "${CHECKPOINT_DIR:=$SIMDIR/CheckPoint}"
  return 0
}

# jw_find_simdir [dir]: walk up from dir until a .sim_data/config is found.
jw_find_simdir() {
  local d; d=$(cd "${1:-.}" && pwd -P)
  while [ "$d" != / ]; do
    [ -r "$d/.sim_data/config" ] && { echo "$d"; return 0; }
    d=$(dirname "$d")
  done
  return 1
}

jw_run_index()  { local b; b=$(basename "$1"); echo "${b#Run}"; }
# Run directories in numeric order (Run1 Run2 ... Run10), ignoring RunN.failed.* etc.
jw_run_dirs()   { ls -d "$SIMDIR"/Run[0-9]* 2>/dev/null | grep -E '/Run[0-9]+$' | sed 's/.*Run//' | sort -n | sed "s|^|$SIMDIR/Run|"; }
jw_last_run_index() { jw_run_dirs | sed 's/.*Run//' | tail -n1; }

# ---------------------------------------------------------------- status files
# A status file is a set of key=value lines; the last occurrence of a key wins.
jw_status_set() {           # <file> key=value ...
  local f=$1 kv k pat="" tmp; shift
  [ $# -gt 0 ] || return 0
  for kv in "$@"; do k=${kv%%=*}; pat+="${pat:+|}$k"; done
  tmp="$f.tmp.$$"           # unique per writer: the login node and the job may update the same file
  { [ -f "$f" ] && grep -Ev "^($pat)=" "$f"; printf '%s\n' "$@"; } > "$tmp" && mv -f "$tmp" "$f"
}
jw_status_get() {           # <file> <key>
  [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n1
}

jw_log() {                  # <run-label> <jobid> <event> [details...]
  local r=$1 j=$2 e=$3; shift 3
  printf '%s %-8s %-8s %-9s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$r" "${j:--}" "$e" "$*" >> "$SIMDIR/chain.log"
}

# ---------------------------------------------------------------- templating
# jw_fill_template <src> <dst> VAR...: replaces @REP{VAR} with the value of $VAR.
# Pure bash, so values may contain / & and other sed-hostile characters.
jw_fill_template() {
  local src=$1 dst=$2 key content; shift 2
  content=$(<"$src") || return 1
  for key in "$@"; do
    content=${content//"@REP{$key}"/${!key:-}}
  done
  if [[ $content == *@REP\{* ]]; then
    jw_warn "$dst: unreplaced placeholders: $(grep -o '@REP{[A-Za-z_0-9]*}' <<<"$content" | sort -u | tr '\n' ' ')"
  fi
  printf '%s\n' "$content" > "$dst"
}

# ---------------------------------------------------------------- walltime
# jw_walltime_minutes "[D-]HH:MM:SS" | "MM" | "MM:SS" | "D-HH" | "D-HH:MM"
jw_walltime_minutes() {
  local w=$1 d=0 h=0 m=0 s=0 n
  if [[ $w == *-* ]]; then
    d=${w%%-*}; w=${w#*-}
    IFS=: read -r h m s <<<"$w"
  else
    n=$(awk -F: '{print NF}' <<<"$w")
    case $n in
      1) m=$w ;;
      2) m=${w%%:*}; s=${w#*:} ;;
      3) IFS=: read -r h m s <<<"$w" ;;
    esac
  fi
  [[ "${d:-0}${h:-0}${m:-0}${s:-0}" =~ ^[0-9]+$ ]] || { jw_warn "invalid walltime '$1' (expected [D-]HH:MM:SS)"; return 1; }
  echo $(( 10#${d:-0}*1440 + 10#${h:-0}*60 + 10#${m:-0} ))
}

# ---------------------------------------------------------------- parfile
# jw_par_get <parfile> <param>: value of the last assignment (comments and quotes stripped).
jw_par_get() {
  local v
  v=$(grep -iE "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | tail -n1)
  [ -n "$v" ] || return 0
  v=${v#*=}; v=${v#"${v%%[![:space:]]*}"}            # drop 'name =' and leading blanks
  if [[ $v == \"* ]]; then
    v=${v#\"}; v=${v%%\"*}                           # quoted: everything up to the closing quote ('#' allowed)
  else
    v=${v%%#*}; v=${v%"${v##*[![:space:]]}"}         # unquoted: strip comment and trailing blanks
  fi
  printf '%s\n' "$v"
}
# jw_par_value <parfile> <param>: like jw_par_get, with parfile variables ($name = ...) substituted,
# each definition wrapped in parentheses so that jw_num can evaluate e.g. "$itlast" = "(64 * 16)".
jw_par_value() {
  local v d i
  v=$(jw_par_get "$1" "$2")
  for i in 1 2 3 4 5; do
    [[ $v =~ \$\{?([A-Za-z_][A-Za-z_0-9]*)\}? ]] || break
    d=$(jw_par_get "$1" "\\\$${BASH_REMATCH[1]}")
    [ -n "$d" ] || break
    v=${v//"${BASH_REMATCH[0]}"/($d)}
  done
  printf '%s\n' "$v"
}
# jw_num <expr>: evaluate a simple numeric expression (digits . e + - * / parentheses); fails if not numeric.
jw_num() {
  local v=$1
  [[ -n $v && $v =~ ^[0-9.eE+*/()[:space:]-]+$ ]] || return 1
  awk "BEGIN{printf \"%.17g\", $v}" 2>/dev/null
}

# ---------------------------------------------------------------- drivers / checkpoints
# Everything that depends on the driver (DRIVER=carpet|carpetx, chosen by `jw setup` from
# ActiveThorns and frozen in .sim_data/config) lives in this section:
#   carpet  : CarpetIOHDF5 writes <file>.chkpt.it_<N>[.file_<p>].h5 and announces the
#             termination checkpoint with
#             "Dumping termination checkpoint at iteration N, simulation time T"
#   carpetx : CarpetX writes <file>.chkpt.it<NNNNNNNN>.<bp5|bp4|bp|h5|silo> (zero padded;
#             openPMD/ADIOS2 BP5 is a directory) plus an index <file>.openpmd.visit, and
#             announces with "Checkpointing before terminating at iteration N, time T, run time H h".
#             The announcement precedes the write, so the write must be confirmed separately
#             (jw_term_write_ok): Cactus must reach its clean shutdown ("Done.") afterwards, or
#             print a "... skipping checkpointing" line; older CarpetX printed "OutputOpenPMD done.".

# jw_active_thorns <parfile>: the thorn names of every ActiveThorns statement, one per line.
jw_active_thorns() {
  awk '
    !inq && tolower($0) ~ /^[ \t]*activethorns[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); sub(/^"/, ""); inq = 1 }
    inq { if (match($0, /"/)) { print substr($0, 1, RSTART - 1); inq = 0 } else print }
  ' "$1" | tr -s ' \t' '\n' | grep -v '^$'
}

# jw_checkpoint_iters: every checkpoint iteration in CHECKPOINT_DIR, ascending, unpadded, unique.
jw_checkpoint_iters() {
  local p
  case $DRIVER in
    carpetx)
      for p in "$CHECKPOINT_DIR"/*.chkpt.it[0-9]*.*; do
        [[ $p =~ \.it0*([0-9]+)\.(bp5|bp4|bp|h5|silo)$ ]] && echo "${BASH_REMATCH[1]}"
      done ;;
    *)
      for p in "$CHECKPOINT_DIR"/*.chkpt.it_[0-9]*.h5; do
        [[ $p =~ \.it_([0-9]+)\. ]] && echo "${BASH_REMATCH[1]}"
      done ;;
  esac | sort -n | uniq
}
jw_latest_checkpoint_iter() { jw_checkpoint_iters | tail -n1; }
jw_checkpoint_exists() {    # <iteration>
  local i
  [[ ${1:-} =~ ^[0-9]+$ ]] || return 1
  for i in $(jw_checkpoint_iters); do [ "$i" -eq "$(( 10#$1 ))" ] && return 0; done
  return 1
}
jw_checkpoint_pattern() { case $DRIVER in carpetx) echo '*.chkpt.it<NNNNNNNN>.<bp5|bp4|bp|h5|silo>' ;; *) echo '*.chkpt.it_<N>.*.h5' ;; esac; }

# jw_term_checkpoint <cactus-output>: prints "<iteration> <time>" of the (last) termination
# checkpoint announcement; returns 1 when Cactus never announced one.
jw_term_checkpoint() {
  local line it t=""
  case $DRIVER in
    carpetx) line=$(grep -E 'Checkpointing before terminating at iteration [0-9]+' "$1" | tail -n1) ;;
    *)       line=$(grep -E 'Dumping termination checkpoint at iteration [0-9]+' "$1" | tail -n1) ;;
  esac
  [[ $line =~ at\ iteration\ ([0-9]+) ]] || return 1
  it=${BASH_REMATCH[1]}
  [[ $line =~ (simulation\ )?time\ ([-+0-9.eE]+) ]] && t=${BASH_REMATCH[2]}
  echo "$it $t"
}

# jw_term_write_ok <cactus-output> <iteration> <checkpoint-method>: for CarpetX, require that
# the write announced by the termination line was completed. CarpetX prints nothing when a
# checkpoint is finished, so the evidence is the flesh's clean shutdown line "Done." after the
# announcement (a job killed inside the write never prints it), a "... skipping checkpointing"
# line, or "OutputOpenPMD done." from older CarpetX versions. Prints the reason on stdout and
# returns 1 when unconfirmed; always 0 for Carpet (its line is printed after the write).
jw_term_write_ok() {
  local out=$1 it=$2 method=$3 n
  [ "$DRIVER" = carpetx ] || return 0
  n=$(grep -nE 'Checkpointing before terminating at iteration ' "$out" | tail -n1 | cut -d: -f1)
  [ -n "$n" ] || { echo "no announcement found"; return 1; }
  tail -n +"$(( n + 1 ))" "$out" | grep -qE '^Done\.$|OutputOpenPMD done\.|at iteration '"$it"'; skipping checkpointing' && return 0
  echo "the write was never confirmed (Cactus never reached its 'Done.' shutdown line after the announcement): it died inside the checkpoint write, the directory on disk is incomplete"
  return 1
}

# ---------------------------------------------------------------- Slurm
# All scheduler commands go through jw_slurm so that a compute node without
# working client commands can fall back to ssh'ing to MASTERNODE.
jw_slurm() {                # <cmd> args...
  local out rc
  if command -v "$1" >/dev/null 2>&1; then
    out=$("$@" 2>&1); rc=$?
    [ $rc -eq 0 ] && { printf '%s\n' "$out"; return 0; }
  else
    out="$1: command not found"; rc=127
  fi
  if [ -n "$MASTERNODE" ] && [ -n "${SLURM_JOB_ID:-}" ]; then
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$MASTERNODE" "cd $(printf %q "$PWD") && $(printf '%q ' "$@")" 2>&1); rc=$?
    [ $rc -eq 0 ] && { printf '%s\n' "$out"; return 0; }
  fi
  printf '%s\n' "$out" >&2
  return $rc
}

# jw_sbatch args... -> job id on stdout, nothing on failure.
jw_sbatch() {
  local out
  out=$(jw_slurm sbatch --parsable --export="$SBATCH_EXPORT" "$@") || return 1
  out=${out%%;*}
  [[ $out =~ ^[0-9]+$ ]] || { jw_warn "sbatch returned unexpected output: $out"; return 1; }
  echo "$out"
}

# jw_job_state <jobid> -> Slurm state (PENDING, RUNNING, COMPLETED, ...) or "" if unknown to the controller.
# Returns 1 if the query itself failed (distinguishes "gone" from "cannot tell").
jw_job_state() {
  local out
  [ -n "$1" ] || { echo ""; return 0; }
  if out=$(jw_slurm squeue -h -j "$1" -o %T 2>&1); then
    echo "${out%%$'\n'*}"; return 0
  fi
  # After MinJobAge the controller forgets a finished job and squeue -j fails with this message.
  [[ $out == *"Invalid job id specified"* ]] && { echo ""; return 0; }
  printf '%s\n' "$out" >&2
  return 1
}
# jw_job_in_queue <jobid>: 0 = still pending/running, 1 = finished or unknown, 2 = query failed.
jw_job_in_queue() {
  local st; st=$(jw_job_state "$1") || return 2
  case $st in PENDING|RUNNING|SUSPENDED|CONFIGURING|COMPLETING|REQUEUED|RESIZING|REVOKED|SIGNALING|STAGE_OUT) return 0 ;; esac
  return 1
}
jw_scancel() { [ -n "$1" ] && jw_slurm scancel "$1" >/dev/null 2>&1; }

# jw_cancel_successors <N>: cancel every queued Run beyond N (marks them CANCELLED).
jw_cancel_successors() {
  local n=$1 dir m st job
  for dir in $(jw_run_dirs); do
    m=$(jw_run_index "$dir"); (( m > n )) || continue
    st=$(jw_status_get "$dir/status" state); job=$(jw_status_get "$dir/status" jobid)
    case $st in
      QUEUED|PREPARED)
        [ -n "$job" ] && jw_scancel "$job"
        jw_status_set "$dir/status" state=CANCELLED reason="cancelled by Run$n" end="$(date +%s)"
        jw_log "Run$m" "$job" CANCELLED "by Run$n" ;;
    esac
  done
}

# ---------------------------------------------------------------- mail
# jw_mail <event> <subject>; body on stdin. Honours MAIL_EVENTS. Never fails the caller.
jw_mail() {
  local event=$1 subject=$2 body
  body=$(cat)
  [[ ",$MAIL_EVENTS," == *",$event,"* ]] || return 0
  [ -n "$MAIL" ] || return 0
  if command -v mail >/dev/null 2>&1 && printf '%s\n' "$body" | mail -s "$subject" "$MAIL" 2>/dev/null; then return 0; fi
  if [ -n "$MASTERNODE" ]; then
    printf '%s\n' "$body" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$MASTERNODE" \
      "mail -s $(printf %q "$subject") $(printf %q "$MAIL")" 2>/dev/null && return 0
  fi
  jw_warn "could not send mail: $subject"
  return 0
}

# ---------------------------------------------------------------- run creation
# jw_prepare_run <N>: create Run<N> with filled sub + parfile and a hard link to the executable.
# Refuses if the directory exists and holds anything but PREPARED files.
jw_prepare_run() {
  local n=$1 dir="$SIMDIR/Run$1" sd="$SIMDIR/.sim_data"
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
    jw_warn "Run$n exists and is not empty"; return 1
  fi
  mkdir -p "$dir" || return 1
  local RUN=$n MAX_RUNTIME WALLTIME_MIN WALLTIME_HOURS
  WALLTIME_MIN=$(jw_walltime_minutes "$WALLTIME") || return 1
  MAX_RUNTIME=$(( WALLTIME_MIN - RUNTIME_MARGIN_MIN ))
  (( MAX_RUNTIME > 0 )) || { jw_warn "WALLTIME $WALLTIME minus RUNTIME_MARGIN_MIN $RUNTIME_MARGIN_MIN is not positive"; return 1; }
  WALLTIME_HOURS=$(awk -v m="$WALLTIME_MIN" 'BEGIN{printf "%g", m / 60}')   # for TerminationTrigger::max_walltime
  # optional header lines: rendered only when the value is set
  local SBATCH_MEM="" SBATCH_PARTITION="" SBATCH_ACCOUNT="" SBATCH_QOS=""
  [ -n "$MEM" ]       && SBATCH_MEM="#SBATCH --mem=$MEM"
  [ -n "$PARTITION" ] && SBATCH_PARTITION="#SBATCH --partition=$PARTITION"
  [ -n "$ACCOUNT" ]   && SBATCH_ACCOUNT="#SBATCH --account=$ACCOUNT"
  [ -n "$QOS" ]       && SBATCH_QOS="#SBATCH --qos=$QOS"
  jw_fill_template "$sd/sub.template" "$dir/sub" \
      SIMNAME RUN SBATCH_PARTITION SBATCH_ACCOUNT SBATCH_QOS SBATCH_MEM PARTITION WALLTIME NODES TASKS_PER_NODE CPUS_PER_TASK \
      MAIL SLURM_MAIL_TYPE SBATCH_EXTRA || return 1
  jw_fill_template "$sd/parfile.template" "$dir/$PARFILE" \
      CHECKPOINT_DIR MAX_RUNTIME WALLTIME_HOURS RUNTIME_MARGIN_MIN SIMDIR SIMNAME RUN DATADIRNAME || return 1
  ln "$sd/$EXE" "$dir/$EXE" 2>/dev/null || cp "$sd/$EXE" "$dir/$EXE" || return 1
  jw_status_set "$dir/status" state=PREPARED created="$(date +%s)"
  echo "$dir"
}

# jw_remove_unrun_run <N>: delete a run directory in which Cactus never ran
# (state PREPARED, QUEUED or CANCELLED and no cactus_*.out). Returns 1 if it refuses.
jw_remove_unrun_run() {
  local dir="${SIMDIR:?}/Run${1:?}" f st
  [ -d "$dir" ] || return 0
  st=$(jw_status_get "$dir/status" state)
  case $st in PREPARED|QUEUED|CANCELLED|"") ;; *) return 1 ;; esac
  ls "$dir"/cactus_*.out >/dev/null 2>&1 && return 1
  for f in sub "$PARFILE" "$EXE" status .jobid; do
    [ -n "$f" ] && [ -f "$dir/$f" ] && rm -f "$dir/${f:?}"
  done
  rm -f "$dir"/stdout_*.out "$dir"/status.tmp*
  rmdir "$dir" 2>/dev/null || return 1
}
jw_clear_prepared() { jw_remove_unrun_run "$1"; }

# jw_submit_run <N> [prevjobid]: sbatch Run<N>/sub, afterok on prevjobid when that job is still queued/running.
# Prints the new job id.
jw_submit_run() {
  local n=$1 prev=${2:-} dir="$SIMDIR/Run$1" dep=() job
  if [ -n "$prev" ]; then
    jw_job_in_queue "$prev"
    case $? in
      0) dep=(--dependency=afterok:"$prev" --kill-on-invalid-dep=yes) ;;
      1) jw_info "job $prev is no longer in the queue; submitting Run$n without a dependency" ;;
      *) jw_warn "cannot query job $prev; not submitting Run$n"; return 1 ;;
    esac
  fi
  job=$( cd "$dir" && jw_sbatch "${dep[@]}" sub ) || return 1
  echo "$job" > "$dir/.jobid"
  jw_status_set "$dir/status" state=QUEUED jobid="$job" submitted="$(date +%s)" depends="${dep[0]:+$prev}" predecessor="${prev:-none}"
  [ ${#dep[@]} -eq 0 ] && jw_status_set "$dir/status" depends=none
  jw_log "Run$n" "$job" QUEUED "${dep[0]:-no-dependency}"
  echo "$job"
}

# jw_ensure_successors <N> <jobid-of-N>: keep QUEUE_DEPTH successors of Run<N> queued, chained by afterok.
jw_ensure_successors() {
  local n=$1 prevjob=$2 d m dir st job
  for (( d=1; d<=QUEUE_DEPTH; d++ )); do
    m=$(( n + d )); dir="$SIMDIR/Run$m"
    if (( m > MAX_RUNS )); then jw_info "MAX_RUNS=$MAX_RUNS reached; not queuing Run$m"; return 0; fi
    if [ -e "$SIMDIR/STOP" ]; then jw_info "STOP file present; not queuing Run$m"; return 0; fi
    if [ -d "$dir" ]; then
      st=$(jw_status_get "$dir/status" state); job=$(jw_status_get "$dir/status" jobid)
      case $st in
        QUEUED|RUNNING)
          jw_job_in_queue "$job"
          case $? in
            0) prevjob=$job; continue ;;
            1) jw_warn "Run$m claims job $job but Slurm no longer runs it; moving the directory aside"
               mv "$dir" "$dir.stale.$(date +%s)" || return 1 ;;
            *) jw_warn "cannot determine the state of job $job for Run$m; leaving the chain as is"; return 1 ;;
          esac ;;
        PREPARED) jw_clear_prepared "$m" ;;
        "") [ -n "$(ls -A "$dir")" ] && { jw_warn "Run$m exists without a status file; not queuing beyond it"; return 1; } ;;
        *) jw_warn "Run$m exists with state '$st'; not queuing beyond it"; return 1 ;;
      esac
    fi
    jw_prepare_run "$m" >/dev/null || return 1
    job=$(jw_submit_run "$m" "$prevjob") || return 1
    prevjob=$job
  done
}
