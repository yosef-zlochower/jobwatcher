#!/bin/bash
# archive_run.sh - POST_RUN_HOOK: tar the run's Cactus output directory into <simdir>/Archive.
#
#   usage (by jw_job.sh): archive_run.sh <rundir> <SUCCESS|COMPLETE>
#
# Produces <simdir>/Archive/<DATADIRNAME>_RunN.tar.gz containing the output directory, the
# Cactus stdout, the filled parfile and the status file. The output directory itself is left
# in place (set JW_ARCHIVE_REMOVE=yes in EXTRA_ENV to delete it after a verified tar).
# Then, if hooks/lazev_combine.sh is present next to this script, it is run as well.

set -uo pipefail
RUNDIR=$(cd "${1:?rundir}" && pwd -P); STATE=${2:-SUCCESS}
SIMDIR=$(cd "$RUNDIR/.." && pwd -P)
. "$SIMDIR/.sim_data/jw_common.sh"
jw_load_sim "$SIMDIR" || exit 1
RUN=$(jw_run_index "$RUNDIR")
ARCH=$SIMDIR/Archive
mkdir -p "$ARCH" || exit 1

cd "$RUNDIR" || exit 1
[ -d "$DATADIRNAME" ] || { echo "archive_run: no output directory $DATADIRNAME in $RUNDIR"; exit 1; }
tarball=$ARCH/${DATADIRNAME}_Run${RUN}.tar.gz
extras=( "$PARFILE" status )
ls cactus_*.out >/dev/null 2>&1 && extras+=( cactus_*.out )
echo "archive_run: writing $tarball"
tar czf "$tarball.part" "$DATADIRNAME" "${extras[@]}" && mv -f "$tarball.part" "$tarball" || { rm -f "$tarball.part"; echo "archive_run: tar failed"; exit 1; }
if [ "${JW_ARCHIVE_REMOVE:-no}" = yes ]; then
  tar tzf "$tarball" >/dev/null && rm -rf "${RUNDIR:?}/${DATADIRNAME:?}" && echo "archive_run: removed $RUNDIR/$DATADIRNAME"
fi
ls -l "$tarball"

combine=$(dirname "$(readlink -f "$0")")/lazev_combine.sh
if [ -x "$combine" ]; then "$combine" "$RUNDIR" "$STATE"; fi
exit 0
