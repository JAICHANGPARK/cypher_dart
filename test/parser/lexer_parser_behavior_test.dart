import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('reports missing recognizable clauses for unknown text', () {
    final result = Cypher.parse('just some text');

    expect(result.hasErrors, isTrue);
    expect(
      result.diagnostics.any(
        (d) =>
            d.message.contains('known Cypher clause keyword') ||
            d.message.contains('recognizable Cypher'),
      ),
      isTrue,
    );
  });

  test('reports unexpected tokens before first clause', () {
    final result = Cypher.parse('noise MATCH (n) RETURN n');

    expect(result.hasErrors, isTrue);
    expect(
      result.diagnostics.any(
        (d) => d.message.contains('Unexpected tokens before first clause'),
      ),
      isTrue,
    );
  });

  test('reports missing body for clauses that require one', () {
    final result = Cypher.parse('MATCH');

    expect(result.hasErrors, isTrue);
    expect(
      result.diagnostics.any(
        (d) => d.message.contains('Clause "MATCH" is missing a body'),
      ),
      isTrue,
    );
  });

  test('allows empty UNION body in lexer stage', () {
    final result = Cypher.parse('RETURN 1 AS n UNION');

    expect(
      result.diagnostics.where(
        (d) => d.message.contains('missing a body expression'),
      ),
      isEmpty,
    );
  });

  test('does not treat ON CREATE and ON MATCH as standalone clause keywords',
      () {
    final result = Cypher.parse(
      'MERGE (n) ON CREATE SET n.created = true ON MATCH SET n.matched = true RETURN n',
      options: const CypherParseOptions(recoverErrors: true),
    );

    final statement =
        result.document!.statements.single as CypherQueryStatement;
    final keywords = statement.clauses.map((c) => c.keyword).toList();
    expect(
      keywords,
      <String>['MERGE', 'SET', 'SET', 'RETURN'],
    );
  });

  test('reports no-clause diagnostics for separator-only non-empty input', () {
    final result = Cypher.parse(';');

    expect(result.hasErrors, isTrue);
    expect(
      result.diagnostics.any(
        (d) => d.message.contains('Could not locate any recognizable Cypher'),
      ),
      isTrue,
    );
  });

  test('splits statements by top-level semicolon', () {
    final result = Cypher.parse("RETURN ';' AS s; RETURN 1 AS n");

    expect(result.hasErrors, isFalse);
    expect(result.document, isNotNull);
    expect(result.document!.statements.length, 2);
  });
}
