#!/bin/bash
# lazev_combine.sh - POST_RUN_HOOK (or called by archive_run.sh): rebuild <simdir>/combine/
# from the output directories of every successful run, in run order.
#
#   usage: lazev_combine.sh <rundir> <state>
#
# Replaces the old combo.sh/newcollect.sh/olderdata dance. It is idempotent: combine/ is
# rebuilt from scratch each time, so a resumed chain never duplicates data.  For every file
# in the list below (plus *rad_obs_* files and pk* files), the pieces from Run1, Run2, ...
# are concatenated; where consecutive runs overlap in time (a resumed run recovering from an
# earlier periodic checkpoint), rows of the earlier run at or after the first time of the
# later run are dropped. Rows are compared on the first whitespace-separated column, which
# is the time for .tl/.gp/.asc files; lines starting with '#' are kept only from the first run.
# Afterwards ~/Scripts/pitrack.sh is run inside combine/ if it exists.

set -uo pipefail
RUNDIR=$(cd "${1:?rundir}" && pwd -P)
SIMDIR=$(cd "$RUNDIR/.." && pwd -P)
. "$SIMDIR/.sim_data/jw_common.sh"
jw_load_sim "$SIMDIR" || exit 1

FILES="LazEvPunctures
tracked_punct_x.x.asc tracked_punct_x.y.asc tracked_punct_y.x.asc tracked_punct_y.y.asc
tracked_punct_z.x.asc tracked_punct_z.y.asc
horizon2_1_circumferences.tl horizon2_1_kill_dir.tl horizon2_1_kill_spin.tl horizon2_1_naive_dir.tl
horizon2_1_naive_mom.tl horizon2_1_vel_dir.tl horizon2_2_circumferences.tl horizon2_2_kill_dir.tl
horizon2_2_kill_spin.tl horizon2_2_naive_dir.tl horizon2_2_naive_mom.tl horizon2_2_vel_dir.tl
horizon2_3_circumferences.tl horizon2_3_kill_dir.tl horizon2_3_kill_spin.tl horizon2_3_naive_dir.tl
horizon2_3_naive_mom.tl horizon2_3_vel_dir.tl
BH_diagnostics.ah1.gp BH_diagnostics.ah2.gp BH_diagnostics.ah3.gp
ADMBASE::alp_horizon_avg_1.tl ADMBASE::alp_horizon_avg_2.tl
ADMCONSTRAINTS::ham_horizon_avg_1.tl ADMCONSTRAINTS::ham_horizon_avg_2.tl
ADMCONSTRAINTS::MOMENTUM_horizon_vector_flux_1.tl ADMCONSTRAINTS::MOMENTUM_horizon_vector_flux_2.tl
ADMCONSTRAINTS::momx_horizon_avg_1.tl ADMCONSTRAINTS::momx_horizon_avg_2.tl
ADMCONSTRAINTS::momy_horizon_avg_1.tl ADMCONSTRAINTS::momy_horizon_avg_2.tl
ADMCONSTRAINTS::momz_horizon_avg_1.tl ADMCONSTRAINTS::momz_horizon_avg_2.tl
alp.norm2.asc HC.norm2.asc
LAZEV::ADMCONSTRAINTS_VECTOR_horizon_vector_flux_1.tl LAZEV::ADMCONSTRAINTS_VECTOR_horizon_vector_flux_2.tl
LAZEV::BSSNCONSTRAINTS_horizon_vector_flux_1.tl LAZEV::BSSNCONSTRAINTS_horizon_vector_flux_2.tl
LAZEV::gtCx_horizon_avg_1.tl LAZEV::gtCx_horizon_avg_2.tl LAZEV::gtCy_horizon_avg_1.tl LAZEV::gtCy_horizon_avg_2.tl
LAZEV::gtCz_horizon_avg_1.tl LAZEV::gtCz_horizon_avg_2.tl LAZEV::gtxx_horizon_avg_1.tl LAZEV::gtxx_horizon_avg_2.tl
LAZEV::gtxy_horizon_avg_1.tl LAZEV::gtxy_horizon_avg_2.tl LAZEV::gtxz_horizon_avg_1.tl LAZEV::gtxz_horizon_avg_2.tl
LAZEV::gtyy_horizon_avg_1.tl LAZEV::gtyy_horizon_avg_2.tl LAZEV::gtyz_horizon_avg_1.tl LAZEV::gtyz_horizon_avg_2.tl
LAZEV::gtzz_horizon_avg_1.tl LAZEV::gtzz_horizon_avg_2.tl LAZEV::HC_horizon_avg_1.tl LAZEV::HC_horizon_avg_2.tl
LAZEV::mCx_horizon_avg_1.tl LAZEV::mCx_horizon_avg_2.tl LAZEV::mCy_horizon_avg_1.tl LAZEV::mCy_horizon_avg_2.tl
LAZEV::mCz_horizon_avg_1.tl LAZEV::mCz_horizon_avg_2.tl LAZEV::xi_horizon_avg_1.tl LAZEV::xi_horizon_avg_2.tl
mCx.norm2.asc mCy.norm2.asc mCz.norm2.asc xi.norm2.asc spd_properdistance.tl"

# Output directories of successful runs, in order (the current run has not been marked yet).
dirs=()
for d in $(jw_run_dirs); do
  st=$(jw_status_get "$d/status" state)
  if [ "$d" = "$RUNDIR" ] || [ "$st" = SUCCESS ] || [ "$st" = COMPLETE ]; then
    [ -d "$d/$DATADIRNAME" ] && dirs+=( "$d/$DATADIRNAME" )
  fi
done
[ ${#dirs[@]} -gt 0 ] || { echo "lazev_combine: no output directories found"; exit 1; }

# Full file list: the static list plus every *rad_obs_* file and pk* file seen in any run.
names=$(printf '%s\n' $FILES; for d in "${dirs[@]}"; do ls "$d" 2>/dev/null | grep -E 'rad_obs_|^pk'; done)
names=$(printf '%s\n' "$names" | sort -u)

new=$SIMDIR/combine.new; rm -rf "$new"; mkdir -p "$new" || exit 1
# combine_file <name>: concatenate with overlap trimming.
combine_file() {
  local name=$1 d out="$new/$1" first=yes i next_t
  for (( i=0; i<${#dirs[@]}; i++ )); do
    d=${dirs[i]}
    [ -f "$d/$name" ] || continue
    next_t=""
    if (( i+1 < ${#dirs[@]} )) && [ -f "${dirs[i+1]}/$name" ]; then
      next_t=$(grep -v '^#' "${dirs[i+1]}/$name" | awk 'NF{print $1; exit}')
    fi
    awk -v first="$first" -v tnext="$next_t" '
      /^#/ { if (first=="yes") print; next }
      NF==0 { next }
      tnext!="" && $1+0 >= tnext+0 { next }
      { print }' "$d/$name" >> "$out"
    first=no
  done
}
for name in $names; do
  case $name in
    pk*) for d in "${dirs[@]}"; do [ -f "$d/$name" ] && [ ! -f "$new/$name" ] && cp "$d/$name" "$new/"; done ;;
    *)   combine_file "$name" ;;
  esac
done
[ -x "$HOME/Scripts/pitrack.sh" ] && ( cd "$new" && [ -f LazEvPunctures ] && "$HOME/Scripts/pitrack.sh" )
rm -rf "$SIMDIR/combine.old"
[ -d "$SIMDIR/combine" ] && mv "$SIMDIR/combine" "$SIMDIR/combine.old"
mv "$new" "$SIMDIR/combine" && rm -rf "$SIMDIR/combine.old"
echo "lazev_combine: rebuilt $SIMDIR/combine from ${#dirs[@]} run(s): $(ls "$SIMDIR/combine" | wc -l) files"
exit 0
