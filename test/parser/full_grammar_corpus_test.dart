import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  const queries = <String>[
    'MATCH (n) RETURN n',
    'OPTIONAL MATCH (n)-[r]->(m) WHERE r.weight > 0 RETURN n, m',
    'CREATE (n:Person {name: "A"}) RETURN n',
    'MERGE (n:Person {id: \$id}) SET n.updatedAt = timestamp() RETURN n',
    'MATCH (n) WITH n.name AS name RETURN name ORDER BY name SKIP 1 LIMIT 10',
    'MATCH (n) REMOVE n.temp DELETE n',
  ];

  test('corpus parses without fatal diagnostics', () {
    for (final query in queries) {
      final result = Cypher.parse(query);
      expect(
        result.hasErrors,
        isFalse,
        reason: 'query failed: $query -> ${result.diagnostics}',
      );
      expect(result.document, isNotNull);
    }
  });
}
