# cypher_dart

[한국어 README](README.ko.md)

`cypher_dart` is a pure Dart package for parsing and formatting Cypher queries.
It is designed for tools that need query validation, editor feedback, and normalized query output in Dart or Flutter.

## Why use it

- Parse Cypher text into a typed AST.
- Get diagnostics with source locations (`line`, `column`, offsets).
- Use strict OpenCypher by default, or enable Neo4j-specific features explicitly.
- Format parsed queries into stable, canonical output.
- Run the same API on VM and Flutter (mobile/web/desktop).

## Scope (version `0.1.0`)

- Clause-level OpenCypher parsing for common query flows.
- Partial semantic validation (clause ordering, duplicate aliases, feature gating).
- Experimental in-memory execution engine for query flows plus writes (`MATCH`/`WHERE`/`WITH`/`RETURN`/`ORDER BY`/`SKIP`/`LIMIT`/`UNWIND`/`UNION`/`CREATE`/`MERGE`/`SET`/`REMOVE`/`DELETE`/`DETACH DELETE`/`CALL`).

## Install

```bash
dart pub add cypher_dart
```

## Import

Recommended entrypoint:

```dart
import 'package:cypher_dart/cypher_dart.dart';
```

Equivalent lower-level entrypoint:

```dart
import 'package:cypher_dart/opencypher.dart';
```

## Documentation

- [DevRel docs index](docs/devrel/README.md)
- [Getting started](docs/devrel/getting-started.md)
- [Execution engine](docs/devrel/execution-engine.md)
- [Benchmarking](docs/devrel/benchmarking.md)
- [Technical report (LaTeX)](docs/paper/technical_report.tex)
- [Technical report build guide](docs/paper/README.md)

## Quick start

```dart
import 'package:cypher_dart/cypher_dart.dart';

void main() {
  const query = '''
MATCH (n:Person)
WHERE n.age > 30
RETURN n.name AS name
ORDER BY name
LIMIT 5
''';

  final result = Cypher.parse(query);

  if (result.hasErrors) {
    for (final d in result.diagnostics) {
      print('${d.code} ${d.severity.name}: ${d.message}');
      print('at ${d.span.start.line + 1}:${d.span.start.column + 1}');
    }
    return;
  }

  final formatted = CypherPrinter.format(result.document!);
  print(formatted);
}
```

## Common usage patterns

### 1) Fail-fast validation (API/server)

Use default options (`recoverErrors: false`) when invalid queries must be rejected.

```dart
final result = Cypher.parse(userQuery);
if (result.hasErrors) {
  throw FormatException(result.diagnostics.first.message);
}
```

### 2) Recovery mode (editor/IDE)

Use `recoverErrors: true` while users are typing incomplete queries.

```dart
final result = Cypher.parse(
  userTypingQuery,
  options: const CypherParseOptions(recoverErrors: true),
);

// You can still inspect result.document with diagnostics.
```

### 3) Strict mode vs Neo4j extensions

Strict OpenCypher is default. Enable extensions explicitly when needed.

```dart
final strictResult = Cypher.parse('USE neo4j MATCH (n) RETURN n');
// -> CYP204 in strict mode

final relaxedResult = Cypher.parse(
  'USE neo4j MATCH (n) RETURN n',
  options: const CypherParseOptions(
    recoverErrors: true,
    enabledFeatures: <CypherFeature>{
      CypherFeature.neo4jUseClause,
    },
  ),
);
```

### 4) Neo4j dialect mode

If your app is Neo4j-first, use `CypherDialect.neo4j5`.

```dart
final result = Cypher.parse(
  query,
  options: const CypherParseOptions(dialect: CypherDialect.neo4j5),
);
```

### 5) Canonical formatting

```dart
final result = Cypher.parse('MATCH (n)   RETURN   n  ORDER BY n.name   LIMIT 3');
if (!result.hasErrors && result.document != null) {
  final pretty = CypherPrinter.format(result.document!);
  print(pretty);
}
```

### 6) AST to JSON (logging/testing)

```dart
final result = Cypher.parse('MATCH (n) RETURN n');
if (result.document != null) {
  final jsonMap = cypherNodeToJson(result.document!);
  print(jsonMap);
}
```

### 7) Experimental in-memory execution

```dart
final graph = InMemoryGraphStore()
  ..createNode(
    labels: {'Person'},
    properties: {'name': 'Alice', 'age': 34},
  );

final execution = CypherEngine.execute(
  'MATCH (n:Person) WHERE n.age >= 30 RETURN n.name AS name',
  graph: graph,
);

print(execution.records); // [{name: Alice}]
```

Engine notes:
- Supports relationship pattern matching for single-hop patterns like `(a)-[r:TYPE]->(b)`.
- Supports relationship type alternation like `[r:T1|:T2]` and path variables in `MATCH` like `p = (a)-[r]->(b)`.
- Supports basic aggregation in `WITH`/`RETURN` (`count`, `sum`, `avg`, `min`, `max`).
- `MERGE ... ON CREATE SET ... ON MATCH SET ...` is supported for clause-local `SET` chains.
- `CALL` supports built-in in-memory procedures: `db.labels()`, `db.relationshipTypes()`, `db.propertyKeys()`.

## Parse options

- `dialect`: `CypherDialect.openCypher9` (default) or `CypherDialect.neo4j5`
- `enabledFeatures`: explicit Neo4j extension allow-list
- `recoverErrors`: `false` (fail-fast) or `true` (best-effort parse)

## Glossary

- `AST` (Abstract Syntax Tree): A tree representation of a query, split into structured nodes instead of raw text.
- `Cypher`: A query language for graph databases.
- `OpenCypher`: A vendor-neutral Cypher specification.
- `Neo4j`: A graph database that extends OpenCypher with additional syntax and features.
- `Dialect`: Parser behavior preset (for example, strict OpenCypher vs Neo4j mode).
- `Feature gate`: A switch that explicitly allows/disallows specific syntax features.
- `Parse`: The process of converting query text into a structured model (AST).
- `Parser`: The component that performs parsing and produces diagnostics.
- `Clause`: A major query unit such as `MATCH`, `WHERE`, `RETURN`, `ORDER BY`.
- `Diagnostic`: A parser/validator message with code, severity, and source location.
- `Span`: The source range (`start` and `end`) tied to a node or diagnostic.
- `Offset`: Character index in the original query text.
- `Fail-fast`: Stop on errors and return no usable document (`recoverErrors: false`).
- `Recovery mode`: Continue parsing after errors to keep partial structure (`recoverErrors: true`).
- `Canonical formatting`: Converting equivalent queries into a consistent output style.

## Supported clause node types

- `MatchClause` (`OPTIONAL MATCH` included)
- `WhereClause`
- `WithClause`
- `ReturnClause`
- `OrderByClause`
- `LimitClause`
- `SkipClause`
- `CreateClause`
- `MergeClause`
- `SetClause`
- `RemoveClause`
- `DeleteClause`
- `UnwindClause`
- `CallClause`
- `UnionClause` (`UNION`, `UNION ALL`)

## Diagnostic code ranges

- `CYP1xx`: syntax/parser errors
- `CYP2xx`: extension/feature-gate violations
- `CYP3xx`: semantic validation errors
- `CYP9xx`: internal parser failures

## Flutter integration notes

The library is pure Dart and does not depend on `dart:io` in `lib/`.

Typical Flutter flow:

1. Bind query input to `TextEditingController`.
2. Parse on text changes (usually with debounce + `recoverErrors: true`).
3. Render `result.diagnostics` in UI.
4. Render `CypherPrinter.format(result.document!)` when parse succeeds.

Sample app: `example/flutter_cypher_lab/lib/main.dart`

## Examples and tests

- CLI example: `example/main.dart`
- Parser tests: `test/parser`
- Diagnostics tests: `test/diagnostics`
- Feature-gate tests: `test/extensions`
- Browser compatibility test: `test/web/web_platform_test.dart`

## Local development

```bash
./tool/release_check.sh
```

This runs format, analyze, tests, browser tests (if Chrome exists), docs validation, parser generation, and generated-file sync checks.

ANTLR setup details: `tool/antlr/README.md`

## License

MIT
