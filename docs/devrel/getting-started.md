# Getting Started

This guide is for:

- package users integrating `cypher_dart` in apps, services, or tooling
- maintainers validating behavior and extending docs/examples

## Install

```bash
dart pub add cypher_dart
```

## Import

Use the consolidated entrypoint:

```dart
import 'package:cypher_dart/cypher_dart.dart';
```

## Parse a Query

```dart
import 'package:cypher_dart/cypher_dart.dart';

void main() {
  const query = '''
MATCH (n:Person)
WHERE n.age >= 30
RETURN n.name AS name
ORDER BY name
LIMIT 5
''';

  final result = Cypher.parse(query);

  if (result.hasErrors) {
    for (final d in result.diagnostics) {
      print('${d.code}: ${d.message}');
      print('at ${d.span.start.line + 1}:${d.span.start.column + 1}');
    }
    return;
  }

  final document = result.document!;
  print('Parsed ${document.statements.length} statement(s).');
}
```

Fail-fast behavior is the default (`recoverErrors: false`), so `result.document` is `null` when errors are present.

## Recovery Mode for Editors and IDEs

Use recovery mode when users are actively typing:

```dart
final result = Cypher.parse(
  'WHERE n.age > 30 RETURN n',
  options: const CypherParseOptions(recoverErrors: true),
);

print(result.hasErrors); // true
print(result.document != null); // true (partial document)
```

## Strict vs Neo4j-Style Syntax

Strict mode is default (`CypherDialect.openCypher9`). You can either enable specific features or switch dialect.

```dart
// Strict mode: reports CYP204 for USE clause.
final strict = Cypher.parse('USE neo4j MATCH (n) RETURN n');

// Allow just USE in strict mode.
final featureEnabled = Cypher.parse(
  'USE neo4j MATCH (n) RETURN n',
  options: const CypherParseOptions(
    recoverErrors: true,
    enabledFeatures: <CypherFeature>{CypherFeature.neo4jUseClause},
  ),
);

// Neo4j dialect: enables all extension features in this package.
final neo4j = Cypher.parse(
  'USE neo4j MATCH (n) RETURN n',
  options: const CypherParseOptions(dialect: CypherDialect.neo4j5),
);

print(strict.hasErrors);
print(featureEnabled.hasErrors);
print(neo4j.hasErrors);
```

## Format a Parsed Query

Formatting uses the parsed AST and emits canonical clause keywords and normalized spacing.

```dart
final parsed = Cypher.parse(
  'MATCH (n)   RETURN n.name AS name  ORDER   BY name   LIMIT 3',
);

if (!parsed.hasErrors && parsed.document != null) {
  final formatted = CypherPrinter.format(parsed.document!);
  print(formatted);
}
```

## Access AST and JSON

Clause bodies remain as text fields on clause nodes, with source spans for mapping.

```dart
final parsed = Cypher.parse('MATCH (n:Person) RETURN n');

if (parsed.document != null) {
  final statement =
      parsed.document!.statements.single as CypherQueryStatement;
  final match = statement.clauses.first as MatchClause;

  print(match.pattern); // (n:Person)
  print(cypherNodeToJson(parsed.document!));
}
```

## Parser Scope vs Engine Scope

- Parser scope:
  - identifies clause structure (MATCH/WHERE/RETURN/etc.)
  - emits diagnostics with source location
  - validates selected ordering and alias rules
- Engine scope:
  - executes query semantics against an `InMemoryGraphStore`
  - can still fail at runtime for unsupported semantics or type errors

A query can parse successfully but still fail at execution time. Keep parse and execution handling separate.

## Known Limitations and Safe Usage

- The parser is clause-oriented and intentionally lightweight.
- Extension diagnostics are feature-gated; strict mode reports `CYP20x` for disabled Neo4j syntax.
- In fail-fast mode, always guard access to `result.document`.
- For editor workflows, prefer `recoverErrors: true` and render diagnostics continuously.
- For server/API validation, prefer fail-fast mode and reject on `result.hasErrors`.

