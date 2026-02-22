# Benchmarking

This guide explains how to benchmark parser and engine performance with:

- `tool/benchmark_engine.dart`

Use it for quick local trend checks and regression tracking. The benchmark output is intentionally indicative, not a substitute for production workload testing.

## Run the Benchmark

From the repository root:

```bash
dart run tool/benchmark_engine.dart
```

Default values:

- `--iterations 300`
- `--warmup 60`
- `--nodes 2000`

You can override them:

```bash
dart run tool/benchmark_engine.dart --iterations 1000 --warmup 200 --nodes 5000
```

## What Is Measured

Current scenarios include:

- `parse_simple`
- `parse_complex`
- `execute_filter_projection`
- `execute_relationship_match`
- `execute_aggregation`
- `execute_merge_on_match`

The script pre-builds in-memory graphs and reports:

- `avg_ms/op`: average milliseconds per scenario iteration
- `ops/s`: operations per second

Sample output shape:

```text
cypher_dart benchmark
iterations=300 warmup=60 nodes=2000 (launcher-dependent, indicative only)

scenario                          avg_ms/op     ops/s
-------------------------------------------------------
parse_simple                          0.0998     10020.0
...
```

## Interpreting Results

- Treat parser and execution scenarios separately.
  - Parser scenarios mainly reflect lexing, clause extraction, AST building, and diagnostics.
  - Execution scenarios include parse + runtime traversal/evaluation cost.
- Compare relative deltas, not single-run absolute numbers.
- Large shifts in one scenario usually indicate a localized regression in that path.
- `--nodes` mostly impacts execution scenarios that traverse graph data.

## Practical Benchmark Protocol

For maintainers, use a consistent protocol:

1. Keep Dart SDK version and machine class constant.
2. Run the same command at least 3-5 times.
3. Compare medians (or trimmed mean), not one run.
4. Record command + git revision with each result.
5. Investigate regressions by scenario, then confirm with targeted tests.

## Safety Notes

- The benchmark uses synthetic workloads and an in-memory graph store.
- Numbers are useful for package-internal trend tracking, not SLA claims.
- Avoid mixing background-heavy tasks while collecting measurements.

