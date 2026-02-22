import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('strict mode blocks EXISTS subquery syntax', () {
    final result = Cypher.parse(
      'MATCH (n) WHERE EXISTS { MATCH (n)-->(m) RETURN m } RETURN n',
    );

    expect(result.diagnostics.any((d) => d.code == 'CYP201'), isTrue);
    expect(result.document, isNull);
  });

  test('feature flag allows EXISTS subquery syntax', () {
    final result = Cypher.parse(
      'MATCH (n) WHERE EXISTS { MATCH (n)-->(m) RETURN m } RETURN n',
      options: const CypherParseOptions(
        recoverErrors: true,
        enabledFeatures: <CypherFeature>{CypherFeature.neo4jExistsSubquery},
      ),
    );

    expect(result.diagnostics.any((d) => d.code == 'CYP201'), isFalse);
  });

  test('strict mode blocks CALL subquery in transactions', () {
    final result = Cypher.parse(
      'CALL { RETURN 1 AS n } IN TRANSACTIONS RETURN n',
      options: const CypherParseOptions(recoverErrors: true),
    );

    expect(result.diagnostics.any((d) => d.code == 'CYP202'), isTrue);
  });

  test('strict mode blocks pattern comprehension', () {
    final result = Cypher.parse(
      'MATCH (n) RETURN [(n)-->(m) | m] AS xs',
      options: const CypherParseOptions(recoverErrors: true),
    );

    expect(result.diagnostics.any((d) => d.code == 'CYP203'), isTrue);
  });

  test('does not flag list comprehension as pattern comprehension', () {
    final result = Cypher.parse(
      'RETURN [x IN [1, 2, 3] | x] AS xs',
      options: const CypherParseOptions(recoverErrors: true),
    );

    expect(result.diagnostics.any((d) => d.code == 'CYP203'), isFalse);
  });

  test('neo4j dialect bypasses strict extension diagnostics', () {
    final result = Cypher.parse(
      'USE neo4j MATCH (n) WHERE EXISTS { MATCH (n)-->(m) RETURN m } RETURN n',
      options: const CypherParseOptions(
        recoverErrors: true,
        dialect: CypherDialect.neo4j5,
      ),
    );

    expect(
      result.diagnostics.where((d) => d.code.startsWith('CYP20')),
      isEmpty,
    );
  });
}
