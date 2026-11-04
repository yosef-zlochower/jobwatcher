#!/bin/bash
# run_tests.sh - end-to-end tests of jw against a fake Slurm and a fake Cactus.
# Usage: tests/run_tests.sh [workdir]   (default: a fresh mktemp directory; kept on failure)

set -u
JW_HOME=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd -P)
T=${1:-$(mktemp -d "${TMPDIR:-/tmp}/jwtest.XXXXXX")}
export FAKE_SLURM_DIR=$T/fakeslurm
mkdir -p "$T/bin" "$FAKE_SLURM_DIR"
for c in sbatch squeue scancel srun mail runqueue; do ln -sf "$JW_HOME/tests/fakeslurm" "$T/bin/$c"; done
export PATH=$T/bin:$PATH
export JW_CONFIG=$T/userconfig
cat > "$JW_CONFIG" <<EOF
SETUP_SCRIPT=""
LAUNCHER="srun --mpi=pmix"
MASTERNODE=""
MAIL=tester
MAIL_EVENTS=start,success,fail,complete,stopped
RUNTIME_MARGIN_MIN=5
WALLTIME=1:00:00
NODES=1
EOF
JW=$JW_HOME/bin/jw
pass=0; failn=0
ok()   { echo "  ok   - $1"; pass=$((pass+1)); }
fail() { echo "  FAIL - $1"; failn=$((failn+1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }   # <desc> <condition>
state() { sed -n 's/^state=//p' "$1/status" 2>/dev/null | tail -n1; }

mkpar() {  # <file> <itlast>
cat > "$1" <<EOF
ActiveThorns = "Carpet CarpetIOHDF5"
IO::out_dir = \$parfile
cactus::terminate = "iteration"
cactus::cctk_itlast = $2
# cactus::max_runtime = 20
CarpetIOHDF5::checkpoint = "no"
IO::checkpoint_every = 100
IO::checkpoint_on_terminate = no
IO::checkpoint_dir = "checkpoints"
IO::recover_dir = "checkpoints"
IO::recover = "autoprobe"
EOF
}

echo "== unit: walltime parsing and templating"
. "$JW_HOME/lib/jw_common.sh"
check "walltime 24:00:00 -> 1440"  '[ "$(jw_walltime_minutes 24:00:00)" = 1440 ]'
check "walltime 2-00:00:00 -> 2880" '[ "$(jw_walltime_minutes 2-00:00:00)" = 2880 ]'
check "walltime 1-12 -> 2160"      '[ "$(jw_walltime_minutes 1-12)" = 2160 ]'
check "walltime 90 -> 90"          '[ "$(jw_walltime_minutes 90)" = 90 ]'
check "walltime 08:30:00 -> 510"   '[ "$(jw_walltime_minutes 08:30:00)" = 510 ]'
printf 'a=@REP{X} b=@REP{Y}\n' > "$T/tpl"; X='/path/with/slashes & ampersand' Y='$NN' jw_fill_template "$T/tpl" "$T/out" X Y
check "template keeps / & and \$"  '[ "$(cat "$T/out")" = "a=/path/with/slashes & ampersand b=\$NN" ]'

echo "== scenario A: chain runs to completion (cctk_itlast reached) and cancels the queued successor"
A=$T/simA; mkdir -p "$A"; mkpar "$T/bbh.par" 1700
( cd "$A" && "$JW" setup --yes --name simA --parfile "$T/bbh.par" --exe "$JW_HOME/tests/fakecactus" --max-runs 20 --mem 4G > setup.log 2>&1 ) || { fail "setup A"; cat "$A/setup.log"; }
check "setup created config"            '[ -f "$A/.sim_data/config" ]'
check "parfile adapted: max_runtime placeholder" 'grep -q "cactus::max_runtime = @REP{MAX_RUNTIME}" "$A/.sim_data/parfile.template"'
check "parfile adapted: checkpoint dir"  'grep -q "IO::checkpoint_dir = \"@REP{CHECKPOINT_DIR}\"" "$A/.sim_data/parfile.template"'
check "parfile adapted: terminate any"   'grep -qi "cactus::terminate = \"any\"" "$A/.sim_data/parfile.template"'
check "parfile adapted: final_time sentinel so 'any' does not stop at t=0" 'grep -q "cactus::cctk_final_time = 1e30" "$A/.sim_data/parfile.template"'
check "parfile adapted: checkpoint yes"  'grep -q "CarpetIOHDF5::checkpoint = \"yes\"" "$A/.sim_data/parfile.template"'
( cd "$A" && "$JW" start > start.log 2>&1 ) || { fail "start A"; cat "$A/start.log"; }
check "Run1 queued, Run2 queued with dependency" '[ "$(state "$A/Run1")" = QUEUED ] && [ "$(state "$A/Run2")" = QUEUED ] && grep -q afterok "$A/chain.log"'
check "filled parfile has max_runtime 55" 'grep -q "cactus::max_runtime = 55" "$A/Run1/bbh.par"'
check "sub has --mem=4G"   'grep -q "^#SBATCH --mem=4G$" "$A/Run1/sub"'
runqueue > "$A/queue.log" 2>&1
check "Run1..3 SUCCESS"  '[ "$(state "$A/Run1")" = SUCCESS ] && [ "$(state "$A/Run2")" = SUCCESS ] && [ "$(state "$A/Run3")" = SUCCESS ]'
check "Run4 COMPLETE at 1700" '[ "$(state "$A/Run4")" = COMPLETE ] && grep -q "^iter=1700" "$A/Run4/status"'
check "Run5 cancelled, no Run6" '[ "$(state "$A/Run5")" = CANCELLED ] && [ ! -d "$A/Run6" ]'
check "last = 1700"       '[ "$(cat "$A/.sim_data/last")" = 1700 ]'
check "complete mail sent" 'grep -q "simA COMPLETE" "$FAKE_SLURM_DIR/mail.log"'
check "status runs"        '( cd "$A" && "$JW" status > status.log 2>&1 ) && grep -q "Run4 *COMPLETE" "$A/status.log"'
check "Run2 checked predecessor+checkpoint" 'grep -q "jw_job: Run2 SUCCESS" "$A/Run2/stdout_"*.out'
sed -i '/cctk_final_time = 1e30/d' "$A/.sim_data/parfile.template"
( cd "$A" && "$JW" sync --parfile > sync.log 2>&1 ) || fail "sync --parfile"
check "sync --parfile re-adapts the template" 'grep -q "cactus::cctk_final_time = 1e30" "$A/.sim_data/parfile.template" && ls "$A"/.sim_data/parfile.template.bak.* >/dev/null 2>&1'

echo "== scenario B: crash in Run2, successor cancelled, resume, MAX_RUNS honoured"
B=$T/simB; mkdir -p "$B"; mkpar "$T/bbh.par" 0
( cd "$B" && "$JW" setup --yes --name simB --parfile "$T/bbh.par" --exe "$JW_HOME/tests/fakecactus" --max-runs 4 > setup.log 2>&1 ) || fail "setup B"
check "terminate=runtime when itlast=0 and no final time" 'grep -qi "cactus::terminate = \"runtime\"" "$B/.sim_data/parfile.template"'
( cd "$B" && "$JW" start > start.log 2>&1 ) || fail "start B"
FAKE_CRASH_DIRS="Run2" runqueue > "$B/queue1.log" 2>&1
check "Run1 SUCCESS, Run2 FAILED, Run3 CANCELLED" '[ "$(state "$B/Run1")" = SUCCESS ] && [ "$(state "$B/Run2")" = FAILED ] && [ "$(state "$B/Run3")" = CANCELLED ]'
check "fail mail with output tail"  'grep -q "simB Run2 FAILED" "$FAKE_SLURM_DIR/mail.log" && grep -q "received signal 11" "$FAKE_SLURM_DIR/mail.log"'
check "last still 500"              '[ "$(cat "$B/.sim_data/last")" = 500 ]'
( cd "$B" && "$JW" resume > resume.log 2>&1 ) || { fail "resume B"; cat "$B/resume.log"; }
check "failed Run2 moved aside, never-run Run3 removed" 'ls -d "$B"/Run2.failed.* >/dev/null 2>&1 && [ ! -d "$B/Run3" ] || [ "$(state "$B/Run3")" = QUEUED ]'
check "new Run2 queued without dependency" '[ "$(state "$B/Run2")" = QUEUED ] && grep -q "^depends=none" "$B/Run2/status"'
runqueue > "$B/queue2.log" 2>&1
check "Run2..4 SUCCESS after resume"  '[ "$(state "$B/Run2")" = SUCCESS ] && [ "$(state "$B/Run3")" = SUCCESS ] && [ "$(state "$B/Run4")" = SUCCESS ]'
check "MAX_RUNS=4: no Run5"           '[ ! -d "$B/Run5" ] && grep -q "MAX_RUNS" "$B/Run4/stdout_"*.out'
check "last = 2000"                   '[ "$(cat "$B/.sim_data/last")" = 2000 ]'

echo "== scenario C: stop and resume, no-progress failure, missing checkpoint file"
C=$T/simC; mkdir -p "$C"; mkpar "$T/bbh.par" 0
( cd "$C" && "$JW" setup --yes --name simC --parfile "$T/bbh.par" --exe "$JW_HOME/tests/fakecactus" --max-runs 10 > setup.log 2>&1 ) || fail "setup C"
( cd "$C" && "$JW" start > start.log 2>&1 ) || fail "start C"
runqueue --one > "$C/queue1.log" 2>&1
check "after one job: Run1 SUCCESS, Run2 QUEUED" '[ "$(state "$C/Run1")" = SUCCESS ] && [ "$(state "$C/Run2")" = QUEUED ]'
( cd "$C" && "$JW" stop > stop.log 2>&1 ) || fail "stop C"
check "stop cancelled Run2 and created STOP" '[ "$(state "$C/Run2")" = CANCELLED ] && [ -e "$C/STOP" ]'
runqueue > "$C/queue2.log" 2>&1
check "nothing ran while stopped" '[ "$(state "$C/Run2")" = CANCELLED ] && [ ! -d "$C/Run3" ]'
( cd "$C" && "$JW" resume > resume.log 2>&1 ) || { fail "resume C"; cat "$C/resume.log"; }
check "resume removed STOP and re-queued Run2" '[ ! -e "$C/STOP" ] && [ "$(state "$C/Run2")" = QUEUED ]'
FAKE_STEP=10 runqueue --one > "$C/queue3.log" 2>&1
check "no-progress run FAILED with MIN_PROGRESS message" '[ "$(state "$C/Run2")" = FAILED ] && grep -q "MIN_PROGRESS" "$C/Run2/status"'
check "last unchanged after failed run" '[ "$(cat "$C/.sim_data/last")" = 500 ]'
( cd "$C" && "$JW" resume > resume2.log 2>&1 ) || fail "resume C 2"
FAKE_NOCHECKPOINT=1 runqueue --one > "$C/queue4.log" 2>&1
check "announced but missing checkpoint -> FAILED" '[ "$(state "$C/Run2")" = FAILED ] && grep -q "no file" "$C/Run2/status"'
( cd "$C" && "$JW" resume > resume3.log 2>&1 ) || fail "resume C 3"
runqueue --one > "$C/queue5.log" 2>&1
check "chain continues, recovering from the periodic checkpoint 510 (non-strict): Run2 SUCCESS at 1010" \
      '[ "$(state "$C/Run2")" = SUCCESS ] && [ "$(cat "$C/.sim_data/last")" = 1010 ] && grep -q "newest checkpoint is iteration 510" "$C/Run2/stdout_"*.out'
check "resume refuses while a job is queued" '! ( cd "$C" && "$JW" resume > resume4.log 2>&1 ) && grep -q "still" "$C/resume4.log"'
check "log has START/SUCCESS/FAILED/MOVED events" 'grep -q " START " "$C/chain.log" && grep -q " FAILED " "$C/chain.log" && grep -q " MOVED " "$C/chain.log"'

echo
echo "passed: $pass  failed: $failn  (workdir $T)"
[ $failn -eq 0 ] && { [ -n "${1:-}" ] || rm -rf "$T"; exit 0; }
exit 1
