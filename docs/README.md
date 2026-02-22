# DevRel Docs

This folder contains practical documentation for `cypher_dart` users and maintainers.

## Recommended Reading Order

1. [`getting-started.md`](getting-started.md): install, import, parse, diagnostics, AST, and formatting.
2. [`execution-engine.md`](execution-engine.md): in-memory execution model, supported flows, and engine-safe usage.
3. [`benchmarking.md`](benchmarking.md): repeatable performance checks with `tool/benchmark_engine.dart`.
4. [`../paper/technical_report.tex`](../paper/technical_report.tex): arXiv-style technical report source.

## Scope Map

| Area | Covers | Does not cover |
| --- | --- | --- |
| Parser (`Cypher.parse`) | Clause-level query structure, diagnostics, feature gates, parse options, clause ordering checks. | Executing queries against graph data. |
| Formatter (`CypherPrinter.format`) | Canonical keyword style and normalized spacing from parsed AST. | Semantic rewrites or optimization. |
| Engine (`CypherEngine.execute`) | Experimental in-memory query execution over `InMemoryGraphStore`. | Full database behavior, production query planning, external storage. |

## Entry Points

- Recommended import: `package:cypher_dart/cypher_dart.dart`
- Lower-level import: `package:cypher_dart/opencypher.dart`
