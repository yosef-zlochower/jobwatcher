# Open work

Items noticed during use that are not implemented yet. Larger pieces (other schedulers) are in
EXTENDING_JOBWATCHER.md.

- **Per-partition node description.** `CORES_PER_NODE` is one number per cluster, but the
  core count (and memory) differs between partitions: a debug or large-memory partition
  often has bigger nodes than the default one. Today the only effect is a misleading warning
  from `jw setup` when TASKS_PER_NODE*CPUS_PER_TASK does not match the cluster-wide value.
  Wanted: let the cluster config describe each partition, e.g.
  `PARTITION_CORES[debug]=48 PARTITION_MEM[debug]=390G` (bash associative arrays) or a
  `partitions/` table, and have `jw setup`/`jw configure` take the defaults and the sanity
  check from the selected partition, with the cluster-wide value as fallback. The same table
  could later feed sensible defaults for `--tasks-per-node`/`--cpus-per-task` and `MEM`.
  Also add `--cores-per-node` to `jw setup` for a one-off override.
