import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('allows alias reuse across consecutive WITH clauses', () {
    final result = Cypher.parse('WITH 1 AS x WITH x + 1 AS x RETURN x');

    expect(result.diagnostics.any((d) => d.code == 'CYP301'), isFalse);
  });

  test('rejects duplicate aliases within a single projection clause', () {
    final result = Cypher.parse('RETURN 1 AS a, 2 AS a');

    expect(result.diagnostics.any((d) => d.code == 'CYP301'), isTrue);
  });

  test('does not split ON CREATE into a separate CREATE clause', () {
    final result =
        Cypher.parse('MERGE (n) ON CREATE SET n.created = 1 RETURN n');

    expect(result.hasErrors, isFalse);
  });

  test('ignores subquery-internal clause keywords for outer ordering rules',
      () {
    final result = Cypher.parse(
      'MATCH (n) WHERE exists { MATCH (n)-->(m) WHERE n.prop = m.prop RETURN m } RETURN n',
      options: const CypherParseOptions(dialect: CypherDialect.neo4j5),
    );

    expect(result.diagnostics.any((d) => d.code == 'CYP300'), isFalse);
  });
}
