import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('strict mode blocks USE clause', () {
    final result = Cypher.parse('USE neo4j MATCH (n) RETURN n');

    expect(result.hasErrors, isTrue);
    expect(result.diagnostics.any((d) => d.code == 'CYP204'), isTrue);
    expect(result.document, isNull);
  });

  test('feature flag allows USE clause', () {
    final result = Cypher.parse(
      'USE neo4j MATCH (n) RETURN n',
      options: const CypherParseOptions(
        recoverErrors: true,
        enabledFeatures: <CypherFeature>{CypherFeature.neo4jUseClause},
      ),
    );

    expect(result.diagnostics.where((d) => d.code == 'CYP204'), isEmpty);
  });
}
