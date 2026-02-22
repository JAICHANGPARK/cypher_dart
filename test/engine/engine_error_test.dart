import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void _expectRuntimeError(
  String query, {
  required InMemoryGraphStore graph,
  required String messageContains,
  Map<String, Object?> parameters = const <String, Object?>{},
}) {
  final result = CypherEngine.execute(
    query,
    graph: graph,
    parameters: parameters,
  );

  expect(result.hasErrors, isTrue);
  expect(result.runtimeErrors, isNotEmpty);
  expect(result.runtimeErrors.single, contains(messageContains));
}

void main() {
  group('CypherEngine error paths', () {
    test('short-circuits on parse errors before execution', () {
      final result = CypherEngine.execute(
        'this is not cypher',
        graph: InMemoryGraphStore(),
      );

      expect(result.hasErrors, isTrue);
      expect(result.parseResult.hasErrors, isTrue);
      expect(result.runtimeErrors, isEmpty);
    });

    test('reports runtime errors for invalid UNION shapes', () {
      _expectRuntimeError(
        'RETURN 1 AS n UNION',
        graph: InMemoryGraphStore(),
        messageContains: 'UNION cannot have an empty query part',
      );

      _expectRuntimeError(
        'RETURN 1 AS a UNION RETURN 2 AS b',
        graph: InMemoryGraphStore(),
        messageContains: 'must project the same columns',
      );
    });

    test('reports delete and detach constraints', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(properties: <String, Object?>{'name': 'A'});
      final b = graph.createNode(properties: <String, Object?>{'name': 'B'});
      graph.createRelationship(
          startNodeId: a.id, endNodeId: b.id, type: 'KNOWS');

      _expectRuntimeError(
        "MATCH (n {name: 'A'}) DELETE n",
        graph: graph,
        messageContains: 'Cannot delete node',
      );
    });

    test('reports unsupported target forms in SET, REMOVE, and DELETE', () {
      _expectRuntimeError(
        'CREATE (n) SET n += 1 RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'expects a map, node, or relationship value',
      );

      _expectRuntimeError(
        'CREATE (n) REMOVE 1 RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'Unsupported REMOVE item',
      );

      _expectRuntimeError(
        "CREATE (n {name: 'A'}) DELETE n.name",
        graph: InMemoryGraphStore(),
        messageContains: 'must resolve to a node, relationship, path, or list',
      );
    });

    test('reports type errors in REMOVE/SET label operations', () {
      _expectRuntimeError(
        'WITH 1 AS x SET x:Label RETURN x',
        graph: InMemoryGraphStore(),
        messageContains: 'must be a node',
      );

      _expectRuntimeError(
        'WITH 1 AS x REMOVE x:Label RETURN x',
        graph: InMemoryGraphStore(),
        messageContains: 'must be a node',
      );
    });

    test('reports UNWIND and LIMIT validation errors', () {
      _expectRuntimeError(
        'UNWIND 1 AS n RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'must evaluate to a list',
      );

      _expectRuntimeError(
        'RETURN 1 AS n LIMIT 1.5',
        graph: InMemoryGraphStore(),
        messageContains: 'LIMIT value must be an integer',
      );

      _expectRuntimeError(
        'RETURN 1 AS n LIMIT -1',
        graph: InMemoryGraphStore(),
        messageContains: 'cannot be negative',
      );
    });

    test('reports expression and function validation errors', () {
      _expectRuntimeError(
        'RETURN unknownFn(1) AS x',
        graph: InMemoryGraphStore(),
        messageContains: 'Unsupported function',
      );

      _expectRuntimeError(
        'WITH 1 AS x RETURN x.a AS a',
        graph: InMemoryGraphStore(),
        messageContains: 'Cannot read property',
      );

      _expectRuntimeError(
        'RETURN {1: 2} AS m',
        graph: InMemoryGraphStore(),
        messageContains: 'Unsupported map key',
      );

      _expectRuntimeError(
        r'RETURN $missing AS value',
        graph: InMemoryGraphStore(),
        messageContains: 'Missing parameter',
      );

      _expectRuntimeError(
        'RETURN toInteger([1]) AS value',
        graph: InMemoryGraphStore(),
        messageContains: 'Cannot convert',
      );

      _expectRuntimeError(
        'RETURN toFloat({a: 1}) AS value',
        graph: InMemoryGraphStore(),
        messageContains: 'Cannot convert',
      );

      _expectRuntimeError(
        'RETURN size(1) AS value',
        graph: InMemoryGraphStore(),
        messageContains: 'does not support',
      );
    });

    test('reports aggregation misuse errors', () {
      _expectRuntimeError(
        'RETURN *, count(*) AS c',
        graph: InMemoryGraphStore(),
        messageContains: 'Wildcard projection with aggregation',
      );

      _expectRuntimeError(
        'UNWIND [1] AS n RETURN count(n, n) AS c',
        graph: InMemoryGraphStore(),
        messageContains: 'count expects either * or 1 argument',
      );

      _expectRuntimeError(
        "UNWIND ['x'] AS n RETURN sum(n) AS s",
        graph: InMemoryGraphStore(),
        messageContains: 'sum expects numeric values',
      );

      _expectRuntimeError(
        "UNWIND ['x'] AS n RETURN avg(n) AS a",
        graph: InMemoryGraphStore(),
        messageContains: 'avg expects numeric values',
      );

      _expectRuntimeError(
        'UNWIND [1] AS n RETURN min(n, n) AS m',
        graph: InMemoryGraphStore(),
        messageContains: 'min expects 1 argument',
      );
    });

    test('reports CALL parsing and procedure errors', () {
      _expectRuntimeError(
        'CALL db.labels RETURN 1 AS n',
        graph: InMemoryGraphStore(),
        messageContains: 'Unsupported CALL invocation',
      );

      _expectRuntimeError(
        'CALL db.unknown()',
        graph: InMemoryGraphStore(),
        messageContains: 'Unsupported CALL procedure',
      );

      final graph = InMemoryGraphStore();
      graph.createNode(labels: <String>{'User'});
      _expectRuntimeError(
        'CALL db.labels() YIELD missing RETURN missing',
        graph: graph,
        messageContains: 'does not yield',
      );

      _expectRuntimeError(
        "MATCH (n) CALL test.my.proc('A') YIELD * RETURN n",
        graph: InMemoryGraphStore()..createNode(),
        messageContains: 'YIELD * is only supported for standalone CALL',
      );
    });

    test('reports MERGE and CREATE pattern constraints', () {
      _expectRuntimeError(
        'CREATE (a)-[r:A|:B]->(b) RETURN r',
        graph: InMemoryGraphStore(),
        messageContains: 'requires exactly one type',
      );

      _expectRuntimeError(
        'MATCH (n) SET n.created = true ON CREATE RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'must directly follow MERGE',
      );

      _expectRuntimeError(
        'CREATE (a)-[:R*2]->(b)',
        graph: InMemoryGraphStore(),
        messageContains:
            'CREATE does not support variable-length relationships',
      );

      _expectRuntimeError(
        'MERGE (a)-[:R*2]->(b)',
        graph: InMemoryGraphStore(),
        messageContains:
            'Variable-length relationships are not supported in MERGE',
      );
    });

    test('reports pattern parsing and structural validation errors', () {
      _expectRuntimeError(
        'MATCH (a)-[r:KNOWS]-[s:KNOWS]->(b) RETURN a',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid pattern in MATCH',
      );

      _expectRuntimeError(
        'MATCH 1p = (n) RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid path variable',
      );

      _expectRuntimeError(
        'MATCH n RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'parenthesized node patterns',
      );

      _expectRuntimeError(
        'MATCH (1n) RETURN 1 AS n',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid node variable',
      );

      _expectRuntimeError(
        'MATCH (n:1Label) RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid node label',
      );

      _expectRuntimeError(
        'MATCH (a)-[1r:KNOWS]->(b) RETURN a',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid relationship variable',
      );

      _expectRuntimeError(
        'MATCH (a)-[:]->(b) RETURN a',
        graph: InMemoryGraphStore(),
        messageContains: 'Relationship type cannot be empty',
      );

      _expectRuntimeError(
        'MATCH (a)-[r:KN:OWS]->(b) RETURN a',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid relationship type',
      );
    });

    test('reports variable binding violations in MERGE and CREATE', () {
      _expectRuntimeError(
        'WITH 1 AS n MERGE (n) RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'is not bound to a node in MERGE',
      );

      _expectRuntimeError(
        "CREATE (n:Person {name: 'A'}) WITH n MERGE (n:Other) RETURN n",
        graph: InMemoryGraphStore(),
        messageContains: 'does not satisfy MERGE pattern constraints',
      );

      _expectRuntimeError(
        'CREATE (a), (b) WITH a, b, 1 AS r MERGE (a)-[r:KNOWS]->(b) RETURN r',
        graph: InMemoryGraphStore(),
        messageContains: 'is not bound to a relationship in MERGE',
      );

      _expectRuntimeError(
        "CREATE (a:Person {name: 'A'}), (b:Person {name: 'B'}) CREATE (a)-[r:LIKES]->(b) WITH a, b, r MERGE (a)-[r:KNOWS]->(b) RETURN r",
        graph: InMemoryGraphStore(),
        messageContains: 'does not satisfy MERGE relationship constraints',
      );

      _expectRuntimeError(
        'WITH 1 AS n CREATE (n) RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'is not bound to a node in CREATE',
      );

      _expectRuntimeError(
        "CREATE (n:Person {name: 'A'}) WITH n CREATE (n:Other) RETURN n",
        graph: InMemoryGraphStore(),
        messageContains: 'does not satisfy CREATE pattern constraints',
      );
    });

    test('reports expression, aggregate, and CALL/YIELD syntax errors', () {
      _expectRuntimeError(
        r'RETURN $1x AS v',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid parameter name',
      );

      _expectRuntimeError(
        'WITH 1 AS n WHERE n = RETURN n',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid comparison expression',
      );

      _expectRuntimeError(
        'RETURN {a} AS m',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid map entry',
      );

      _expectRuntimeError(
        'RETURN {a:} AS m',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid map entry',
      );

      _expectRuntimeError(
        'RETURN 1 + true AS n',
        graph: InMemoryGraphStore(),
        messageContains: 'Operator + expects numeric, list, or string operands',
      );

      _expectRuntimeError(
        'RETURN toInteger() AS n',
        graph: InMemoryGraphStore(),
        messageContains: 'toInteger expects 1 argument',
      );

      _expectRuntimeError(
        'RETURN toFloat() AS n',
        graph: InMemoryGraphStore(),
        messageContains: 'toFloat expects 1 argument',
      );

      _expectRuntimeError(
        "RETURN size('a', 'b') AS n",
        graph: InMemoryGraphStore(),
        messageContains: 'size expects 1 argument',
      );

      _expectRuntimeError(
        'UNWIND [1] AS n RETURN sum(n, n) AS s',
        graph: InMemoryGraphStore(),
        messageContains: 'sum expects 1 argument',
      );

      _expectRuntimeError(
        'UNWIND [1] AS n RETURN avg(n, n) AS a',
        graph: InMemoryGraphStore(),
        messageContains: 'avg expects 1 argument',
      );

      _expectRuntimeError(
        'UNWIND [1] AS n RETURN max() AS m',
        graph: InMemoryGraphStore(),
        messageContains: 'max expects 1 argument',
      );

      _expectRuntimeError(
        'CALL db.labels() YIELD , RETURN 1 AS n',
        graph: InMemoryGraphStore(),
        messageContains: 'YIELD requires at least one item',
      );

      _expectRuntimeError(
        'CALL db.labels() YIELD 1 RETURN 1 AS n',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid YIELD item',
      );

      _expectRuntimeError(
        'CALL db.labels() YIELD label AS 1x RETURN label',
        graph: InMemoryGraphStore(),
        messageContains: 'Invalid YIELD item',
      );
    });

    test('reports procedure argument and unsupported merge-shape errors', () {
      _expectRuntimeError(
        'CALL db.labels(1)',
        graph: InMemoryGraphStore(),
        messageContains: 'does not accept args',
      );

      _expectRuntimeError(
        'CALL db.relationshipTypes(1)',
        graph: InMemoryGraphStore(),
        messageContains: 'does not accept args',
      );

      _expectRuntimeError(
        'CALL db.propertyKeys(1)',
        graph: InMemoryGraphStore(),
        messageContains: 'does not accept args',
      );

      _expectRuntimeError(
        'MERGE ON CREATE',
        graph: InMemoryGraphStore(),
        messageContains: 'MERGE pattern cannot be empty',
      );

      _expectRuntimeError(
        'RETURN util.fn(1) AS v',
        graph: InMemoryGraphStore(),
        messageContains: 'Unsupported function',
      );
    });
  });
}
