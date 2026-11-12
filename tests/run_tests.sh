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
export JW_CLUSTER=$JW_HOME/tests/cluster.conf
export JW_CONFIG=$T/userconfig
cat > "$JW_CONFIG" <<EOF
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
printf 'IO::out_dir = "data#1" # trailing comment\nIO::recover = autoprobe # c\n' > "$T/par0"
check "par_get keeps # inside quotes, strips comments" '[ "$(jw_par_get "$T/par0" IO::out_dir)" = "data#1" ] && [ "$(jw_par_get "$T/par0" IO::recover)" = autoprobe ]'
check "walltime rejects garbage"     '! jw_walltime_minutes "two days" 2>/dev/null'
printf '$itlast = 64 * 16\n$final_time = 1000\nCactus::cctk_itlast = $itlast\nCactus::cctk_final_time = $final_time\n' > "$T/par1"
check "job exports the environment to srun tasks despite --export=NONE" 'grep -q "^export SLURM_EXPORT_ENV=ALL" "$JW_HOME/lib/jw_job.sh"'
check "par_value resolves parfile variables" '[ "$(jw_num "$(jw_par_value "$T/par1" cactus::cctk_itlast)")" = 1024 ] && [ "$(jw_num "$(jw_par_value "$T/par1" cactus::cctk_final_time)")" = 1000 ]'

echo "== configure: the user config file (setup script and personal defaults)"
UC=$T/cfg/config; printf '#!/bin/bash\nexport FROM_SETUP_SCRIPT=1\n' > "$T/setup.sh"
check "configure creates the file with the setup script and a default" \
  'JW_CONFIG=$UC "$JW" configure --setup-script "$T/setup.sh" --partition long > "$T/cfg1.log" 2>&1 && grep -q "^SETUP_SCRIPT=\"$T/setup.sh\"$" "$UC" && grep -q "^PARTITION=\"long\"$" "$UC"'
check "KEY=VALUE replaces the key in place (one line, last value wins)" \
  'JW_CONFIG=$UC "$JW" configure PARTITION=debug > /dev/null 2>&1 && [ "$(grep -c "^PARTITION=" "$UC")" = 1 ] && grep -q "^PARTITION=\"debug\"$" "$UC"'
check "a missing setup script is refused and the file is left alone" \
  '! JW_CONFIG=$UC "$JW" configure --setup-script "$T/nope.sh" > /dev/null 2>&1 && grep -q "^SETUP_SCRIPT=\"$T/setup.sh\"$" "$UC"'
check "a bad walltime and a non-integer node count are refused" \
  '! JW_CONFIG=$UC "$JW" configure --time "two days" > /dev/null 2>&1 && ! JW_CONFIG=$UC "$JW" configure --nodes many > /dev/null 2>&1 && ! grep -q "^WALLTIME=\|^NODES=" "$UC"'
check "--unset removes a key, --show prints the file" \
  'JW_CONFIG=$UC "$JW" configure --unset PARTITION > /dev/null 2>&1 && ! grep -q "^PARTITION=" "$UC" && JW_CONFIG=$UC "$JW" configure --show | grep -q "^SETUP_SCRIPT="'
check "an unknown key is stored with a warning" \
  'JW_CONFIG=$UC "$JW" configure MYKEY=1 > "$T/cfg2.log" 2>&1 && grep -q "^MYKEY=\"1\"$" "$UC" && grep -q "not a key" "$T/cfg2.log"'
H=$T/home; mkdir -p "$H"
check "default location is \$XDG_CONFIG_HOME/jobwatcher/config, else ~/.config/jobwatcher/config" \
  '[ "$(env -u JW_CONFIG HOME=$H XDG_CONFIG_HOME=$T/xdg "$JW" configure --show | head -1)" = "# $T/xdg/jobwatcher/config" ] && [ "$(env -u JW_CONFIG -u XDG_CONFIG_HOME HOME=$H "$JW" configure --show | head -1)" = "# $H/.config/jobwatcher/config" ]'
mkdir -p "$T/xdgsim"; mkpar "$T/xdgsim/p.par" 100
check "jw configure creates ~/.config/jobwatcher/config and jw setup reads it" \
  'env -u JW_CONFIG -u XDG_CONFIG_HOME HOME=$H "$JW" configure PARTITION=xdgloc > /dev/null 2>&1 && grep -q "^PARTITION=\"xdgloc\"$" "$H/.config/jobwatcher/config" && ( cd "$T/xdgsim" && env -u JW_CONFIG -u XDG_CONFIG_HOME HOME=$H "$JW" setup --yes --name xdg --parfile p.par --exe "$JW_HOME/tests/fakecactus" > setup.log 2>&1 ) && grep -q "^PARTITION=xdgloc$" "$T/xdgsim/.sim_data/config"'
check "JW_CLUSTER: a name in clusters/, a path, or the single shipped file; a bad name is refused" \
  'env JW_CLUSTER=$(basename -s .conf "$(ls "$JW_HOME"/clusters/*.conf | head -1)") "$JW" configure --show > /dev/null 2>&1 && env -u JW_CLUSTER "$JW" configure --show > /dev/null 2>&1 && ! env JW_CLUSTER=nonexistent JW_CONFIG=$T/cfgx "$JW" configure PARTITION=x > "$T/cfgx.log" 2>&1 && grep -q "not found" "$T/cfgx.log" && [ ! -e "$T/cfgx" ]'
mkdir -p "$T/nopart"; mkpar "$T/nopart/p.par" 100
check "empty PARTITION leaves the --partition line out of the batch script" \
  '( cd "$T/nopart" && "$JW" setup --yes --name np --parfile p.par --exe "$JW_HOME/tests/fakecactus" --partition "" > setup.log 2>&1 && "$JW" start > start.log 2>&1 ) && ! grep -q -- "--partition" "$T/nopart/Run1/sub" && grep -q -- "--time=1:00:00" "$T/nopart/Run1/sub"'
mkdir -p "$T/acct"; mkpar "$T/acct/p.par" 100
check "ACCOUNT and QOS render as #SBATCH lines, and are absent when unset" \
  '( cd "$T/acct" && "$JW" setup --yes --name ac --parfile p.par --exe "$JW_HOME/tests/fakecactus" --account abc123 --qos high > setup.log 2>&1 && "$JW" start > start.log 2>&1 ) && grep -q "^#SBATCH --account=abc123$" "$T/acct/Run1/sub" && grep -q "^#SBATCH --qos=high$" "$T/acct/Run1/sub" && ! grep -q -- "--account\|--qos" "$T/nopart/Run1/sub"'
mkdir -p "$T/clusters" "$T/ovsim"; cp "$JW_HOME/tests/cluster.conf" "$T/clusters/ov.conf"; mkpar "$T/ovsim/p.par" 100
{ cat "$JW_HOME/templates/slurm/sub.template"; } | sed "s|^@REP{SBATCH_EXTRA}|#SBATCH --comment=cluster-override\n@REP{SBATCH_EXTRA}|" > "$T/clusters/ov.sub.template"
check "clusters/<cluster>.sub.template overrides templates/slurm/sub.template" \
  '( cd "$T/ovsim" && JW_CLUSTER=$T/clusters/ov.conf "$JW" setup --yes --name ov --parfile p.par --exe "$JW_HOME/tests/fakecactus" > setup.log 2>&1 && JW_CLUSTER=$T/clusters/ov.conf "$JW" start > start.log 2>&1 ) && grep -q "^#SBATCH --comment=cluster-override$" "$T/ovsim/Run1/sub" && grep -q "^#SBATCH --time=1:00:00$" "$T/ovsim/Run1/sub"'
mkdir -p "$T/cfgsim"; mkpar "$T/cfgsim/p.par" 100
check "jw setup --yes takes the configured setup script" \
  '( cd "$T/cfgsim" && JW_CONFIG=$UC "$JW" setup --yes --name cfg --parfile p.par --exe "$JW_HOME/tests/fakecactus" > setup.log 2>&1 ) && grep -q "^SETUP_SCRIPT=$T/setup.sh$" "$T/cfgsim/.sim_data/config"'
check "jw setup warns when no setup script is configured" \
  'mkdir -p "$T/cfgsim2" && mkpar "$T/cfgsim2/p.par" 100 && ( cd "$T/cfgsim2" && "$JW" setup --yes --name cfg2 --parfile p.par --exe "$JW_HOME/tests/fakecactus" > setup.log 2>&1 ) && grep -q "no SETUP_SCRIPT" "$T/cfgsim2/setup.log" && grep -q "^SETUP_SCRIPT=..$" "$T/cfgsim2/.sim_data/config"'

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

echo "== scenario D: jobs forgotten by the controller (MinJobAge), STOP kept when resume refuses"
( cd "$C" && "$JW" stop > stop2.log 2>&1 )     # the fake queue is shared: cancel C's queued Run3 so it cannot run here
D=$T/simD; mkdir -p "$D"; mkpar "$T/bbh.par" 0
( cd "$D" && "$JW" setup --yes --name simD --parfile "$T/bbh.par" --exe "$JW_HOME/tests/fakecactus" --max-runs 10 > setup.log 2>&1 ) || fail "setup D"
( cd "$D" && "$JW" start > start.log 2>&1 ) || fail "start D"
runqueue --one > "$D/queue1.log" 2>&1
check "after one job: Run1 SUCCESS, Run2 QUEUED" '[ "$(state "$D/Run1")" = SUCCESS ] && [ "$(state "$D/Run2")" = QUEUED ]'
touch "$D/STOP"
check "resume refuses while Run2 is queued and leaves STOP in place" '! ( cd "$D" && "$JW" resume > resume0.log 2>&1 ) && grep -q "still" "$D/resume0.log" && [ -e "$D/STOP" ]'
# Pretend Run2 started, was killed by the time limit, and more than MinJobAge has passed: squeue no longer knows either job.
j1=$(sed -n 's/^jobid=//p' "$D/Run1/status" | tail -n1); j2=$(sed -n 's/^jobid=//p' "$D/Run2/status" | tail -n1)
sed -i 's/^state=.*/state=RUNNING/' "$D/Run2/status"; rm -f "$FAKE_SLURM_DIR/jobs/$j1" "$FAKE_SLURM_DIR/jobs/$j2"
check "status shows the lost run as gone" '( cd "$D" && "$JW" status > status.log 2>&1 ) && grep -q "Run2 *RUNNING *[0-9]* *gone" "$D/status.log"'
( cd "$D" && "$JW" resume > resume1.log 2>&1 ) || { fail "resume D with forgotten jobs"; cat "$D/resume1.log"; }
check "resume moved the lost Run2 aside, removed STOP, re-queued Run2 without dependency" \
      'ls -d "$D"/Run2.failed.* >/dev/null 2>&1 && [ ! -e "$D/STOP" ] && [ "$(state "$D/Run2")" = QUEUED ] && grep -q "^depends=none" "$D/Run2/status"'
runqueue --one > "$D/queue2.log" 2>&1
check "chain continues after resume: Run2 SUCCESS at 1000" '[ "$(state "$D/Run2")" = SUCCESS ] && [ "$(cat "$D/.sim_data/last")" = 1000 ]'

echo "== scenario E: CarpetX driver (padded .bp5 checkpoint directories, announce-then-confirm termination)"
( cd "$D" && "$JW" stop > stop2.log 2>&1 )     # cancel D's queued Run3 (shared fake queue)
mkparx() {  # <file> <final_time>
cat > "$1" <<EOF
ActiveThorns = "
  CarpetX IOUtil
  TerminationTrigger
"
\$final_time = $2
IO::out_dir = \$parfile
Cactus::terminate = "time"
Cactus::cctk_final_time = \$final_time
Cactus::cctk_itlast = 64       # ignored by terminate = "time", must not survive the switch to "any"
IO::checkpoint_every = 512
IO::checkpoint_on_terminate = no
IO::checkpoint_dir = "checkpoint"
IO::recover_dir = "checkpoint"
IO::recover = "autoprobe"
CarpetX::checkpoint_method = "error"
TerminationTrigger::max_walltime = 48
TerminationTrigger::on_remaining_walltime = 30
EOF
}
export FAKE_DRIVER=carpetx
E=$T/simE; mkdir -p "$E"; mkparx "$T/bbhx.par" 1.0
( cd "$E" && "$JW" setup --yes --name simE --parfile "$T/bbhx.par" --exe "$JW_HOME/tests/fakecactus" --max-runs 10 > setup.log 2>&1 ) || { fail "setup E"; cat "$E/setup.log"; }
check "driver detected from ActiveThorns" 'grep -q "^DRIVER=carpetx$" "$E/.sim_data/config" && grep -q "driver: carpetx" "$E/setup.log"'
check "CarpetX checkpoint/recover method set to openpmd, no CarpetIOHDF5 line" \
      'grep -q "CarpetX::checkpoint_method = \"openpmd\"" "$E/.sim_data/parfile.template" && grep -q "CarpetX::recover_method = \"openpmd\"" "$E/.sim_data/parfile.template" && ! grep -q CarpetIOHDF5 "$E/.sim_data/parfile.template"'
check "terminate time -> any keeps \$final_time, itlast gets the sentinel" 'grep -q "cactus::cctk_itlast = 1000000000" "$E/.sim_data/parfile.template" && grep -q "cctk_final_time = \$final_time" "$E/.sim_data/parfile.template"'
check "TerminationTrigger follows WALLTIME and the margin" 'grep -q "TerminationTrigger::max_walltime = @REP{WALLTIME_HOURS}" "$E/.sim_data/parfile.template"'
check "sbatch is called with --export=NONE" 'grep -q "^SBATCH_EXPORT=NONE$" "$E/.sim_data/config"'
( cd "$E" && "$JW" start > start.log 2>&1 ) || { fail "start E"; cat "$E/start.log"; }
check "filled parfile: max_walltime 1 h, on_remaining_walltime 5" 'grep -q "TerminationTrigger::max_walltime = 1$" "$E/Run1/bbhx.par" && grep -q "TerminationTrigger::on_remaining_walltime = 5$" "$E/Run1/bbhx.par"'
runqueue > "$E/queue.log" 2>&1
check "Run1,2 SUCCESS, Run3 COMPLETE at t>=1.0, Run4 cancelled" '[ "$(state "$E/Run1")" = SUCCESS ] && [ "$(state "$E/Run2")" = SUCCESS ] && [ "$(state "$E/Run3")" = COMPLETE ] && [ "$(state "$E/Run4")" = CANCELLED ]'
check "padded bp5 directories, last = 1500" '[ -d "$E/CheckPoint/checkpoint.chkpt.it00001500.bp5" ] && [ "$(cat "$E/.sim_data/last")" = 1500 ]'
mkdir -p "$E/CheckPoint/checkpoint.chkpt.it00009999.bp5_bad"
check "status ignores .openpmd.visit and a renamed _bad directory" '( cd "$E" && "$JW" status > status.log 2>&1 ) && grep -q "newest checkpoint: 1500 " "$E/status.log"'
check "Run2 recovered from the padded checkpoint 500" 'grep -q "Recovering from checkpoint at iteration 500" "$E/Run2/cactus_"*.out'

E2=$T/simE2; mkdir -p "$E2"; mkparx "$T/bbhx2.par" 1000
( cd "$E2" && "$JW" setup --yes --name simE2 --parfile "$T/bbhx2.par" --exe "$JW_HOME/tests/fakecactus" --max-runs 10 > setup.log 2>&1 ) || fail "setup E2"
( cd "$E2" && "$JW" start > start.log 2>&1 ) || fail "start E2"
runqueue --one > "$E2/queue1.log" 2>&1
FAKE_NODONE=1 runqueue --one > "$E2/queue2.log" 2>&1
check "announced but unconfirmed write (killed inside it) -> FAILED, successor cancelled, last kept" \
      '[ "$(state "$E2/Run2")" = FAILED ] && grep -q "never confirmed" "$E2/Run2/status" && [ "$(state "$E2/Run3")" = CANCELLED ] && [ "$(cat "$E2/.sim_data/last")" = 500 ]'
check "the incomplete directory is left on disk (never deleted)" '[ -d "$E2/CheckPoint/checkpoint.chkpt.it00001000.bp5" ]'
( cd "$E2" && "$JW" resume > resume1.log 2>&1 ) || { fail "resume E2"; cat "$E2/resume1.log"; }
FAKE_ALREADY=1 runqueue --one > "$E2/queue3.log" 2>&1
check "'Already wrote checkpoint ... skipping' counts as a confirmed write: Run2 SUCCESS at 1500" '[ "$(state "$E2/Run2")" = SUCCESS ] && grep -q "^iter=1500" "$E2/Run2/status"'
FAKE_STEP=0 runqueue --one > "$E2/queue4.log" 2>&1
check "'Recovered from checkpoint ... skipping' (no progress) -> FAILED by MIN_PROGRESS" '[ "$(state "$E2/Run3")" = FAILED ] && grep -q "MIN_PROGRESS" "$E2/Run3/status"'
unset FAKE_DRIVER

echo
echo "passed: $pass  failed: $failn  (workdir $T)"
[ $failn -eq 0 ] && { [ -n "${1:-}" ] || rm -rf "$T"; exit 0; }
exit 1
