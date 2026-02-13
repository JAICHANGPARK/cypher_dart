# cypher_dart

`cypher_dart` is a Pure Dart package for parsing and formatting Cypher queries.
It is designed for apps that need query validation, editor feedback, and canonical formatting in Dart or Flutter.

## What you can do

- Parse Cypher query text into a typed AST.
- Collect diagnostics with source spans (`line`, `column`, offsets).
- Run in strict mode (default) or enable Neo4j-specific features explicitly.
- Format parsed queries into normalized, consistent output.
- Use the same API on VM and Flutter Web/Desktop/Mobile.

## Current scope (`0.1.0`)

- Clause-level OpenCypher parsing for common query flows.
- Partial semantic validation (ordering rules, duplicate aliases, feature gating).
- No query execution engine (this package does not run queries against Neo4j DB).

## Install

```bash
dart pub add cypher_dart
```

## Recommended import

```dart
import 'package:cypher_dart/cypher_dart.dart';
```

You can also import `package:cypher_dart/opencypher.dart`, but `cypher_dart.dart` is the default entrypoint.

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

## Real usage patterns

### 1) Fail-fast validation (API/server)

Use default settings (`recoverErrors: false`) when invalid queries should be rejected immediately.

```dart
final result = Cypher.parse(userQuery);
if (result.hasErrors) {
  throw FormatException(result.diagnostics.first.message);
}
```

### 2) Recovery mode (editor/IDE input)

Use `recoverErrors: true` when users are typing incomplete queries and you still want partial AST/feedback.

```dart
final result = Cypher.parse(
  userTypingQuery,
  options: const CypherParseOptions(recoverErrors: true),
);

// You can still inspect result.document even with diagnostics.
```

### 3) Strict mode vs Neo4j extensions

Strict OpenCypher is default.
If your app allows Neo4j-specific syntax, enable features explicitly.

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

If your application is Neo4j-first, set dialect to `neo4j5`.

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

### 6) AST to JSON (for logs/testing)

```dart
final result = Cypher.parse('MATCH (n) RETURN n');
if (result.document != null) {
  final jsonMap = cypherNodeToJson(result.document!);
  print(jsonMap);
}
```

## Parse options

- `dialect`: `CypherDialect.openCypher9` (default) or `CypherDialect.neo4j5`
- `enabledFeatures`: explicit Neo4j extension allow-list
- `recoverErrors`: `false` (fail-fast) or `true` (best-effort parse + diagnostics)

## Diagnostic codes

- `CYP1xx`: syntax/parser errors
- `CYP2xx`: extension/feature-gate violations
- `CYP3xx`: semantic validation errors
- `CYP9xx`: internal parser failures

## Flutter usage

The package itself is Pure Dart and does not use `dart:io` in `lib/`.

Practical integration flow in Flutter:

1. Bind query text to `TextEditingController`.
2. Call `Cypher.parse` on change (usually with debounce + `recoverErrors: true`).
3. Show `result.diagnostics` in UI.
4. If valid, show `CypherPrinter.format(result.document!)` preview.

A working sample exists at:

- `/Users/jaichang/Documents/GitHub/cypher_dart/example/flutter_cypher_lab/lib/main.dart`

## Examples and tests

- CLI example: `/Users/jaichang/Documents/GitHub/cypher_dart/example/main.dart`
- Parser tests: `/Users/jaichang/Documents/GitHub/cypher_dart/test/parser`
- Diagnostic tests: `/Users/jaichang/Documents/GitHub/cypher_dart/test/diagnostics`
- Feature-gate tests: `/Users/jaichang/Documents/GitHub/cypher_dart/test/extensions`
- Browser compatibility test: `/Users/jaichang/Documents/GitHub/cypher_dart/test/web/web_platform_test.dart`

## Local development

```bash
./tool/release_check.sh
```

This runs format, analyze, tests, docs, parser generation, and generated file sync checks.

If you want ANTLR generation mode, place the runtime jar in:

- `/Users/jaichang/Documents/GitHub/cypher_dart/tool/antlr/antlr-4.13.2-complete.jar`

Details: `/Users/jaichang/Documents/GitHub/cypher_dart/tool/antlr/README.md`

## License

MIT
