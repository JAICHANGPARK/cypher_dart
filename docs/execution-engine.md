# Execution Engine

`CypherEngine` is an experimental in-memory execution engine intended for local workflows, tests, demos, and tooling prototypes.

## Parser Scope vs Engine Scope

Keep these responsibilities separate:

- Parser (`Cypher.parse`):
  - parses query text into clause-level AST
  - reports diagnostics (`CYPxxx`) with spans
- Engine (`CypherEngine.execute`):
  - parses first, then executes against `InMemoryGraphStore`
  - returns runtime errors for unsupported operations or invalid runtime types

Execution only runs when parsing succeeded and `parseResult.document` is non-null.

## Minimal Execution Flow

```dart
import 'package:cypher_dart/cypher_dart.dart';

void main() {
  final graph = InMemoryGraphStore()
    ..createNode(
      labels: {'Person'},
      properties: {'name': 'Alice', 'age': 34},
    )
    ..createNode(
      labels: {'Person'},
      properties: {'name': 'Bob', 'age': 27},
    );

  final result = CypherEngine.execute(
    'MATCH (n:Person) WHERE n.age >= 30 RETURN n.name AS name ORDER BY name',
    graph: graph,
  );

  if (result.hasErrors) {
    print(result.parseResult.diagnostics);
    print(result.runtimeErrors);
    return;
  }

  print(result.columns); // [name]
  print(result.records); // [{name: Alice}]
}
```

## Parameterized Execution

Parameters are available as `$name` in expressions.

```dart
final graph = InMemoryGraphStore()
  ..createNode(
    labels: {'Person'},
    properties: {'name': 'A', 'age': 30},
  )
  ..createNode(
    labels: {'Person'},
    properties: {'name': 'B', 'age': 45},
  );

final result = CypherEngine.execute(
  r'MATCH (n:Person) WHERE n.age >= $minAge RETURN n.name AS name ORDER BY name',
  graph: graph,
  parameters: const <String, Object?>{'minAge': 40},
);

print(result.records); // [{name: B}]
```

## Distinguish Parse Errors and Runtime Errors

```dart
final graph = InMemoryGraphStore();

final parseFail = CypherEngine.execute('this is not cypher', graph: graph);
print(parseFail.parseResult.hasErrors); // true
print(parseFail.runtimeErrors.isEmpty); // true

final runtimeFail = CypherEngine.execute('UNWIND 1 AS n RETURN n', graph: graph);
print(runtimeFail.parseResult.hasErrors); // false
print(runtimeFail.runtimeErrors); // runtime validation message(s)
```

## Parse Options for Execution

Execution uses parser options internally. Default execution options enable pattern comprehension support while staying on strict dialect defaults.

```dart
final result = CypherEngine.execute(
  'USE neo4j MATCH (n) RETURN n',
  graph: InMemoryGraphStore(),
  options: const CypherExecutionOptions(
    parseOptions: CypherParseOptions(dialect: CypherDialect.neo4j5),
  ),
);
```

## Supported Coverage (Current MVP)

The engine currently handles broad query flows across:

- read clauses: `MATCH`, `OPTIONAL MATCH`, `WHERE`, `WITH`, `RETURN`
- result shaping: `ORDER BY`, `SKIP`, `LIMIT`, `UNWIND`, `UNION`, `UNION ALL`
- writes: `CREATE`, `MERGE`, `SET`, `REMOVE`, `DELETE`, `DETACH DELETE`
- procedure calls: `CALL` for selected built-ins (`db.labels()`, `db.relationshipTypes()`, `db.propertyKeys()`)
- relationship matching:
  - directional and undirected
  - type alternation (for example `:KNOWS|:LIKES`)
  - variable-length patterns in `MATCH`

## Known Limitations

- The engine is in-memory only (`InMemoryGraphStore`), not a database server.
- This is not full openCypher coverage; unsupported forms fail with runtime errors.
- `MERGE` currently supports at most one relationship segment and does not support variable-length relationships in `MERGE`.
- `CREATE` does not support variable-length relationships.
- `CALL` supports only a limited procedure set; unknown procedures fail.
- `YIELD *` is only supported for standalone `CALL` clauses.

## Safe Usage Guidance

- Treat engine results as local execution behavior, not as authoritative database parity.
- Always check `result.hasErrors` before using records.
- Inspect both:
  - `result.parseResult.diagnostics`
  - `result.runtimeErrors`
- Keep graphs bounded when queries include variable-length matches to avoid expensive traversals.
- For production systems, use this engine for tests/tooling and validate behavior against the target graph database before rollout.

