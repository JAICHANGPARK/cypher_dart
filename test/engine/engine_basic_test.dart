import 'package:cypher_dart/cypher_dart.dart';
import 'package:test/test.dart';

void main() {
  group('CypherEngine', () {
    test('executes MATCH/WHERE/RETURN', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'Alice', 'age': 34},
        )
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'Bob', 'age': 27},
        );

      final result = CypherEngine.execute(
        'MATCH (n:Person) WHERE n.age >= 30 RETURN n.name AS name',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.columns, <String>['name']);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'name': 'Alice'},
      ]);
    });

    test('applies ORDER BY, SKIP, LIMIT', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'Alice'},
        )
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'Bob'},
        )
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'Carol'},
        );

      final result = CypherEngine.execute(
        'MATCH (n:Person) RETURN n.name AS name ORDER BY name DESC SKIP 1 LIMIT 1',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'name': 'Bob'},
      ]);
    });

    test('supports UNWIND', () {
      final graph = InMemoryGraphStore();

      final result = CypherEngine.execute(
        'UNWIND [1, 2, 3] AS n RETURN n',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.columns, <String>['n']);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'n': 1},
        <String, Object?>{'n': 2},
        <String, Object?>{'n': 3},
      ]);
    });

    test('matches relationship patterns with direction and type', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'Alice'},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'Bob'},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
        properties: <String, Object?>{'since': 2020},
      );

      final result = CypherEngine.execute(
        'MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a.name AS a, b.name AS b, r.since AS since',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'a': 'Alice', 'b': 'Bob', 'since': 2020},
      ]);
    });

    test('supports grouping with WITH and count aggregation', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'A', 'age': 30},
        )
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'B', 'age': 30},
        )
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'C', 'age': 40},
        );

      final result = CypherEngine.execute(
        'MATCH (n:Person) WITH n.age AS age, count(*) AS c RETURN age, c ORDER BY age',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'age': 30, 'c': 2},
        <String, Object?>{'age': 40, 'c': 1},
      ]);
    });

    test('supports UNION and UNION ALL', () {
      final graph = InMemoryGraphStore();

      final union = CypherEngine.execute(
        'RETURN 1 AS n UNION RETURN 1 AS n',
        graph: graph,
      );
      final unionAll = CypherEngine.execute(
        'RETURN 1 AS n UNION ALL RETURN 1 AS n',
        graph: graph,
      );

      expect(union.hasErrors, isFalse);
      expect(union.records, <Map<String, Object?>>[
        <String, Object?>{'n': 1},
      ]);

      expect(unionAll.hasErrors, isFalse);
      expect(unionAll.records, <Map<String, Object?>>[
        <String, Object?>{'n': 1},
        <String, Object?>{'n': 1},
      ]);
    });

    test('supports CREATE and SET for nodes', () {
      final graph = InMemoryGraphStore();

      final create = CypherEngine.execute(
        "CREATE (n:Person {name: 'A'}) RETURN n.name AS name",
        graph: graph,
      );
      expect(create.hasErrors, isFalse);
      expect(create.records, <Map<String, Object?>>[
        <String, Object?>{'name': 'A'},
      ]);

      final set = CypherEngine.execute(
        "MATCH (n:Person {name: 'A'}) SET n.age = 35 RETURN n.age AS age",
        graph: graph,
      );
      expect(set.hasErrors, isFalse);
      expect(set.records, <Map<String, Object?>>[
        <String, Object?>{'age': 35},
      ]);
    });

    test('supports CREATE relationship from bound nodes', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'A'},
        )
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'B'},
        );

      final result = CypherEngine.execute(
        "MATCH (a:Person {name: 'A'}), (b:Person {name: 'B'}) CREATE (a)-[r:KNOWS {since: 2024}]->(b) RETURN r.since AS since",
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'since': 2024},
      ]);
    });

    test('supports SET for relationship properties', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'A'},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
        properties: <String, Object?>{'since': 2020},
      );

      final result = CypherEngine.execute(
        'MATCH (a:Person)-[r:KNOWS]->(b:Person) SET r.since = 2025 RETURN r.since AS since',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'since': 2025},
      ]);
    });

    test('supports REMOVE for labels and properties', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person', 'Employee'},
        properties: <String, Object?>{'name': 'A', 'age': 30},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
        properties: <String, Object?>{'since': 2020},
      );

      final removeNode = CypherEngine.execute(
        "MATCH (n:Person {name: 'A'}) REMOVE n:Employee, n.age RETURN n.age AS age",
        graph: graph,
      );
      expect(removeNode.hasErrors, isFalse);
      expect(removeNode.records, <Map<String, Object?>>[
        <String, Object?>{'age': null},
      ]);

      final verifyLabel = CypherEngine.execute(
        "MATCH (n:Employee {name: 'A'}) RETURN n",
        graph: graph,
      );
      expect(verifyLabel.hasErrors, isFalse);
      expect(verifyLabel.records, isEmpty);

      final removeRel = CypherEngine.execute(
        "MATCH (a {name: 'A'})-[r:KNOWS]->(b {name: 'B'}) REMOVE r.since RETURN r.since AS since",
        graph: graph,
      );
      expect(removeRel.hasErrors, isFalse);
      expect(removeRel.records, <Map<String, Object?>>[
        <String, Object?>{'since': null},
      ]);
    });

    test('supports DELETE for nodes without relationships', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'A'},
        );

      final delete = CypherEngine.execute(
        "MATCH (n:Person {name: 'A'}) DELETE n",
        graph: graph,
      );
      expect(delete.hasErrors, isFalse);

      final verify = CypherEngine.execute(
        'MATCH (n:Person) RETURN n',
        graph: graph,
      );
      expect(verify.hasErrors, isFalse);
      expect(verify.records, isEmpty);
    });

    test('supports MERGE for nodes and relationships', () {
      final graph = InMemoryGraphStore();

      final mergeNode1 = CypherEngine.execute(
        "MERGE (n:Person {name: 'A'}) RETURN n.name AS name",
        graph: graph,
      );
      expect(mergeNode1.hasErrors, isFalse);
      expect(mergeNode1.records, <Map<String, Object?>>[
        <String, Object?>{'name': 'A'},
      ]);

      final mergeNode2 = CypherEngine.execute(
        "MERGE (n:Person {name: 'A'}) RETURN n.name AS name",
        graph: graph,
      );
      expect(mergeNode2.hasErrors, isFalse);
      expect(graph.nodes.length, 1);

      graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );

      final mergeRel1 = CypherEngine.execute(
        "MATCH (a:Person {name: 'A'}), (b:Person {name: 'B'}) MERGE (a)-[r:KNOWS {since: 2024}]->(b) RETURN r.since AS since",
        graph: graph,
      );
      expect(mergeRel1.hasErrors, isFalse);
      expect(mergeRel1.records, <Map<String, Object?>>[
        <String, Object?>{'since': 2024},
      ]);

      final mergeRel2 = CypherEngine.execute(
        "MATCH (a:Person {name: 'A'}), (b:Person {name: 'B'}) MERGE (a)-[r:KNOWS {since: 2024}]->(b) RETURN r.since AS since",
        graph: graph,
      );
      expect(mergeRel2.hasErrors, isFalse);
      expect(graph.relationships.length, 1);
    });

    test('supports MERGE path variable binding', () {
      final graph = InMemoryGraphStore();
      final result = CypherEngine.execute(
        "MERGE (a:Person {name: 'A'}) MERGE (b:Person {name: 'B'}) MERGE p = (a)-[r:KNOWS]->(b) RETURN length(p) AS length, type(r) AS relType",
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(
        result.records.single,
        <String, Object?>{
          'length': 1,
          'relType': 'KNOWS',
        },
      );
    });

    test('supports DETACH DELETE for connected nodes', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'A'},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
      );

      final result = CypherEngine.execute(
        "MATCH (a:Person {name: 'A'}) DETACH DELETE a",
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(graph.nodes.length, 1);
      expect(graph.relationships, isEmpty);
      expect(graph.nodes.single.properties['name'], 'B');
    });

    test('supports relationship type alternation in MATCH', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'A'},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );
      final carol = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'C'},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
        properties: <String, Object?>{'since': 1},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: carol.id,
        type: 'LIKES',
        properties: <String, Object?>{'since': 2},
      );

      final result = CypherEngine.execute(
        'MATCH (a:Person)-[r:KNOWS|:LIKES]->(b:Person) RETURN r.since AS since ORDER BY since',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{'since': 1},
        <String, Object?>{'since': 2},
      ]);
    });

    test('supports path variable binding in MATCH', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'A'},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
      );

      final result = CypherEngine.execute(
        "MATCH p = (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) RETURN p",
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      final path = result.records.single['p'];
      expect(path, isA<CypherGraphPath>());
      final typed = path! as CypherGraphPath;
      expect(typed.nodes.map((node) => node.properties['name']).toList(),
          <Object?>['A', 'B']);
      expect(typed.relationships.single.type, 'KNOWS');
    });

    test('supports MERGE ON CREATE SET and ON MATCH SET', () {
      final graph = InMemoryGraphStore();

      final first = CypherEngine.execute(
        "MERGE (n:Person {name: 'A'}) ON CREATE SET n.created = true ON MATCH SET n.matched = true RETURN n.created AS created, n.matched AS matched",
        graph: graph,
      );
      expect(first.hasErrors, isFalse);
      expect(first.records, <Map<String, Object?>>[
        <String, Object?>{'created': true, 'matched': null},
      ]);

      final second = CypherEngine.execute(
        "MERGE (n:Person {name: 'A'}) ON CREATE SET n.created = true ON MATCH SET n.matched = true RETURN n.created AS created, n.matched AS matched",
        graph: graph,
      );
      expect(second.hasErrors, isFalse);
      expect(second.records, <Map<String, Object?>>[
        <String, Object?>{'created': true, 'matched': true},
      ]);
    });

    test('supports CALL built-in procedures', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'A'},
        )
        ..createNode(
          labels: <String>{'Company'},
          properties: <String, Object?>{'name': 'Acme'},
        );

      final labels = CypherEngine.execute(
        'CALL db.labels() YIELD label RETURN label ORDER BY label',
        graph: graph,
      );
      expect(labels.hasErrors, isFalse);
      expect(labels.records, <Map<String, Object?>>[
        <String, Object?>{'label': 'Company'},
        <String, Object?>{'label': 'Person'},
      ]);

      final keys = CypherEngine.execute(
        'CALL db.propertyKeys() YIELD propertyKey AS key RETURN key ORDER BY key',
        graph: graph,
      );
      expect(keys.hasErrors, isFalse);
      expect(keys.records, <Map<String, Object?>>[
        <String, Object?>{'key': 'name'},
      ]);
    });

    test('supports test procedures and standalone YIELD *', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: <String>{'Person'},
          properties: <String, Object?>{'name': 'A'},
        );

      final noParen = CypherEngine.execute(
        'CALL test.doNothing RETURN 1 AS n',
        graph: graph,
      );
      expect(noParen.hasErrors, isFalse);
      expect(noParen.records, <Map<String, Object?>>[
        <String, Object?>{'n': 1},
      ]);

      final quotedAlias = CypherEngine.execute(
        'MATCH (n:Person) CALL test.doNothing() RETURN n.name AS `name`',
        graph: graph,
      );
      expect(quotedAlias.hasErrors, isFalse);
      expect(quotedAlias.records, <Map<String, Object?>>[
        <String, Object?>{'name': 'A'},
      ]);

      final yielded = CypherEngine.execute(
        "CALL test.my.proc('Seoul', 'KR') YIELD city, country_code RETURN city, country_code",
        graph: graph,
      );
      expect(yielded.hasErrors, isFalse);
      expect(yielded.records, <Map<String, Object?>>[
        <String, Object?>{'city': 'Seoul', 'country_code': 'KR'},
      ]);

      final yieldStar = CypherEngine.execute(
        "CALL test.my.proc('A', 'B') YIELD * RETURN out, a, b, city, country_code",
        graph: graph,
      );
      expect(yieldStar.hasErrors, isFalse);
      expect(yieldStar.records, <Map<String, Object?>>[
        <String, Object?>{
          'out': 'A',
          'a': 'A',
          'b': 'B',
          'city': 'A',
          'country_code': 'B',
        },
      ]);
    });

    test('supports optional matches with null bindings and path equality', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'Alice'},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'Bob'},
      );
      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
      );

      final result = CypherEngine.execute(
        "MATCH (a:Person {name: 'Alice'}) OPTIONAL MATCH p = (a)-[r:KNOWS]->(b:Person {name: 'Bob'}) RETURN a.name AS anchor, b.name AS buddy, r AS rel, p AS path",
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      final row = result.records.single;
      expect(row['anchor'], 'Alice');
      expect(row['buddy'], 'Bob');
      expect(row['rel'], isA<CypherGraphRelationship>());
      expect(row['path'], isA<CypherGraphPath>());

      final pathEquality = CypherEngine.execute(
        "MATCH p = (a:Person {name: 'Alice'})-[:KNOWS]->(b:Person {name: 'Bob'}) WITH p WHERE p = p RETURN p",
        graph: graph,
      );
      expect(pathEquality.hasErrors, isFalse);
      expect(pathEquality.records.length, 1);

      final optionalRelationshipMiss = CypherEngine.execute(
        "MATCH (a:Person {name: 'Alice'}) OPTIONAL MATCH q = (a)-[:FRIEND]->(g:Person {name: 'Ghost'}) RETURN a AS anchor, q AS missingPath, g AS missingNode",
        graph: graph,
      );
      expect(optionalRelationshipMiss.hasErrors, isFalse);
      final missedRow = optionalRelationshipMiss.records.single;
      expect(missedRow['anchor'], isA<CypherGraphNode>());
      expect(missedRow['missingPath'], isNull);
      expect(missedRow['missingNode'], isNull);

      final optionalNodeOnly = CypherEngine.execute(
        'OPTIONAL MATCH lone = (n:Ghost) RETURN n, lone',
        graph: graph,
      );
      expect(optionalNodeOnly.hasErrors, isFalse);
      expect(optionalNodeOnly.records.single['n'], isNull);
      expect(optionalNodeOnly.records.single['lone'], isNull);
    });

    test('supports incoming and undirected relationship matching', () {
      final graph = InMemoryGraphStore();
      final alice = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'Alice'},
      );
      final bob = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'Bob'},
      );
      final loop = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'Loop'},
      );

      graph.createRelationship(
        startNodeId: alice.id,
        endNodeId: bob.id,
        type: 'KNOWS',
      );
      graph.createRelationship(
        startNodeId: loop.id,
        endNodeId: loop.id,
        type: 'SELF',
      );

      final incoming = CypherEngine.execute(
        "MATCH (b:Person {name: 'Bob'})<-[r:KNOWS]-(a:Person {name: 'Alice'}) RETURN a.name AS a, b.name AS b",
        graph: graph,
      );
      expect(incoming.hasErrors, isFalse,
          reason:
              'runtime=${incoming.runtimeErrors} parse=${incoming.parseResult.diagnostics.map((d) => d.message).toList()}');
      expect(incoming.records, <Map<String, Object?>>[
        <String, Object?>{'a': 'Alice', 'b': 'Bob'},
      ]);

      final undirected = CypherEngine.execute(
        'MATCH (x)-[r:KNOWS]-(y) RETURN x.name AS x, y.name AS y ORDER BY x',
        graph: graph,
      );
      expect(undirected.hasErrors, isFalse);
      expect(undirected.records, <Map<String, Object?>>[
        <String, Object?>{'x': 'Alice', 'y': 'Bob'},
        <String, Object?>{'x': 'Bob', 'y': 'Alice'},
      ]);

      final selfLoop = CypherEngine.execute(
        'MATCH (x)-[r:SELF]-(y) RETURN x.name AS x, y.name AS y',
        graph: graph,
      );
      expect(selfLoop.hasErrors, isFalse);
      expect(selfLoop.records, <Map<String, Object?>>[
        <String, Object?>{'x': 'Loop', 'y': 'Loop'},
      ]);
    });

    test('supports wildcard projection and CALL without explicit YIELD', () {
      final graph = InMemoryGraphStore()
        ..createNode(labels: <String>{'Person'})
        ..createNode(labels: <String>{'Company'});

      final wildcard = CypherEngine.execute(
        "MERGE (n:Person {name: 'A'}) ON CREATE SET n.created = true RETURN *",
        graph: graph,
      );
      expect(wildcard.hasErrors, isFalse);
      expect(wildcard.columns, contains('n'));
      expect(wildcard.columns.any((column) => column.startsWith('\u0000')),
          isFalse);

      final call = CypherEngine.execute(
        'CALL db.labels() RETURN label ORDER BY label',
        graph: graph,
      );
      expect(call.hasErrors, isFalse);
      expect(call.records, <Map<String, Object?>>[
        <String, Object?>{'label': 'Company'},
        <String, Object?>{'label': 'Person'},
      ]);
    });

    test('supports boolean expressions and mixed scalar expression evaluation',
        () {
      final nonBooleanWhereError = CypherEngine.execute(
        'WITH 1 AS v WHERE v RETURN v',
        graph: InMemoryGraphStore(),
      );
      expect(nonBooleanWhereError.hasErrors, isTrue);

      final logical = CypherEngine.execute(
        'WITH true AS a, false AS b WHERE NOT b AND a OR b RETURN a AS ok',
        graph: InMemoryGraphStore(),
      );
      expect(logical.hasErrors, isFalse);
      expect(logical.records.single['ok'], isTrue);

      final mixedOrder = CypherEngine.execute(
        "UNWIND [null, 5, 3.5, true, 'z'] AS orderValue RETURN orderValue ORDER BY orderValue",
        graph: InMemoryGraphStore(),
      );
      expect(mixedOrder.hasErrors, isFalse);
      expect(mixedOrder.records.length, 5);

      final scalarFunctions = CypherEngine.execute(
        "RETURN size([1, 2, 3]) AS listSize, coalesce(null, 'fallback') AS fallback, toInteger('5') AS parsedInt, toFloat('2.5') AS parsedFloat",
        graph: InMemoryGraphStore(),
      );
      expect(scalarFunctions.hasErrors, isFalse);
      final functionRow = scalarFunctions.records.single;
      expect(functionRow['listSize'], 3);
      expect(functionRow['fallback'], 'fallback');
      expect(functionRow['parsedInt'], 5);
      expect(functionRow['parsedFloat'], 2.5);

      final caseAndListOps = CypherEngine.execute(
        "WITH [1, 2] AS list, 3 AS x RETURN CASE WHEN x > 2 THEN reverse(list + x) ELSE [] END AS v",
        graph: InMemoryGraphStore(),
      );
      expect(caseAndListOps.hasErrors, isFalse);
      expect(caseAndListOps.records.single['v'], <Object?>[3, 2, 1]);

      for (final comparison in <String>[
        'v < 2',
        'v <= 1',
        'v > 0',
        'v >= 1',
        'v != 2',
        'v <> 2',
      ]) {
        final comparisonResult = CypherEngine.execute(
          'UNWIND [1] AS v WITH v WHERE $comparison RETURN v',
          graph: InMemoryGraphStore(),
        );
        expect(comparisonResult.hasErrors, isFalse);
        expect(comparisonResult.records.length, 1);
      }

      final listMapEquality = CypherEngine.execute(
        "UNWIND [1] AS n WITH n WHERE [1, 2] = [1, 2] AND {a: 'A', b: 2} = {b: 2, a: 'A'} RETURN n",
        graph: InMemoryGraphStore(),
      );
      expect(listMapEquality.hasErrors, isFalse);
      expect(listMapEquality.records, <Map<String, Object?>>[
        <String, Object?>{'n': 1},
      ]);
    });

    test('supports no-projection columns and aggregation defaults', () {
      final graph = InMemoryGraphStore();

      final createOnly = CypherEngine.execute(
        "CREATE (n:Seed {name: 'seed'})",
        graph: graph,
      );
      expect(createOnly.hasErrors, isFalse);
      expect(createOnly.columns, <String>['n']);
      expect(createOnly.records.single['n'], isA<CypherGraphNode>());

      final emptyAgg = CypherEngine.execute(
        'MATCH (n:Missing) RETURN count(*) AS c, sum(1) AS s, avg(1) AS a, min(1) AS mn, max(1) AS mx',
        graph: graph,
      );
      expect(emptyAgg.hasErrors, isFalse);
      expect(emptyAgg.records, <Map<String, Object?>>[
        <String, Object?>{
          'c': 0,
          's': 0,
          'a': null,
          'mn': null,
          'mx': null,
        },
      ]);

      final minMax = CypherEngine.execute(
        'UNWIND [3, 1, 2] AS n RETURN min(n) AS mn, max(n) AS mx',
        graph: graph,
      );
      expect(minMax.hasErrors, isFalse);
      expect(minMax.records, <Map<String, Object?>>[
        <String, Object?>{'mn': 1, 'mx': 3},
      ]);
    });

    test('supports ordering on node, relationship, and path values', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'A'},
      );
      final b = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );
      final c = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'C'},
      );
      graph.createRelationship(startNodeId: a.id, endNodeId: b.id, type: 'R');
      graph.createRelationship(startNodeId: b.id, endNodeId: c.id, type: 'R');

      final nodeOrder = CypherEngine.execute(
        'MATCH (n:Person) RETURN n ORDER BY n ASC',
        graph: graph,
      );
      expect(nodeOrder.hasErrors, isFalse);
      expect(nodeOrder.records.length, 3);

      final relOrder = CypherEngine.execute(
        'MATCH ()-[r:R]->() RETURN r ORDER BY r',
        graph: graph,
      );
      expect(relOrder.hasErrors, isFalse);
      expect(relOrder.records.length, 2);

      final pathOrder = CypherEngine.execute(
        'MATCH p = ()-[r:R]->() RETURN p ORDER BY p',
        graph: graph,
      );
      expect(pathOrder.hasErrors, isFalse);
      expect(pathOrder.records.length, 2);
    });

    test('handles UNWIND null items and SKIP/LIMIT edge cases', () {
      final result = CypherEngine.execute(
        'UNWIND [null, [1, 2]] AS xs UNWIND xs AS n RETURN n SKIP 10 LIMIT 0',
        graph: InMemoryGraphStore(),
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, isEmpty);
    });

    test('supports additional CALL procedures and key collection', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'A', 'age': 30},
      );
      final b = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'B'},
      );
      graph.createRelationship(
        startNodeId: a.id,
        endNodeId: b.id,
        type: 'KNOWS',
        properties: <String, Object?>{'since': 2020},
      );
      graph.createRelationship(
        startNodeId: b.id,
        endNodeId: a.id,
        type: 'LIKES',
        properties: <String, Object?>{'weight': 1},
      );

      final relationshipTypes = CypherEngine.execute(
        'CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType ORDER BY relationshipType',
        graph: graph,
      );
      expect(relationshipTypes.hasErrors, isFalse);
      expect(relationshipTypes.records, <Map<String, Object?>>[
        <String, Object?>{'relationshipType': 'KNOWS'},
        <String, Object?>{'relationshipType': 'LIKES'},
      ]);

      final propertyKeys = CypherEngine.execute(
        'CALL db.propertyKeys() YIELD propertyKey RETURN propertyKey ORDER BY propertyKey',
        graph: graph,
      );
      expect(propertyKeys.hasErrors, isFalse);
      expect(
        propertyKeys.records,
        containsAll(<Map<String, Object?>>[
          <String, Object?>{'propertyKey': 'age'},
          <String, Object?>{'propertyKey': 'name'},
          <String, Object?>{'propertyKey': 'since'},
          <String, Object?>{'propertyKey': 'weight'},
        ]),
      );
    });

    test('supports aggregate edge cases with null and updates', () {
      final graph = InMemoryGraphStore();

      final countStar = CypherEngine.execute(
        'RETURN count(*) AS c',
        graph: graph,
      );
      expect(countStar.hasErrors, isFalse);
      expect(countStar.records.single['c'], 1);

      final countExpr = CypherEngine.execute(
        'UNWIND [1, null] AS n RETURN count(n) AS c',
        graph: graph,
      );
      expect(countExpr.hasErrors, isFalse);
      expect(countExpr.records.single['c'], 1);

      final sumWithNull = CypherEngine.execute(
        'UNWIND [1, null, 2] AS n RETURN sum(n) AS s',
        graph: graph,
      );
      expect(sumWithNull.hasErrors, isFalse);
      expect(sumWithNull.records.single['s'], 3);

      final avgAllNull = CypherEngine.execute(
        'UNWIND [null] AS n RETURN avg(n) AS a',
        graph: graph,
      );
      expect(avgAllNull.hasErrors, isFalse);
      expect(avgAllNull.records.single['a'], isNull);

      final minValue = CypherEngine.execute(
        'UNWIND [3, 1, 2] AS n RETURN min(n) AS m',
        graph: graph,
      );
      expect(minValue.hasErrors, isFalse);
      expect(minValue.records.single['m'], 1);

      final maxValue = CypherEngine.execute(
        'UNWIND [1, 3, 2] AS n RETURN max(n) AS m',
        graph: graph,
      );
      expect(maxValue.hasErrors, isFalse);
      expect(maxValue.records.single['m'], 3);
    });

    test('supports null-aware comparisons and strict WHERE booleans', () {
      final lessThanNull = CypherEngine.execute(
        'WITH 1 AS x WHERE null < x RETURN x',
        graph: InMemoryGraphStore(),
      );
      expect(lessThanNull.hasErrors, isFalse);
      expect(lessThanNull.records, isEmpty);

      final greaterThanNull = CypherEngine.execute(
        'WITH 1 AS x WHERE x > null RETURN x',
        graph: InMemoryGraphStore(),
      );
      expect(greaterThanNull.hasErrors, isFalse);
      expect(greaterThanNull.records, isEmpty);

      final scalarIdentifierError = CypherEngine.execute(
        'WITH 1 AS n WHERE n RETURN n',
        graph: InMemoryGraphStore(),
      );
      expect(scalarIdentifierError.hasErrors, isTrue);
      expect(
        scalarIdentifierError.runtimeErrors.single,
        contains('WHERE clause expression'),
      );

      final graph = InMemoryGraphStore()
        ..createNode(properties: <String, Object?>{'name': 'A'});
      final nodePredicateError = CypherEngine.execute(
        'MATCH (n) WHERE n RETURN n',
        graph: graph,
      );
      expect(nodePredicateError.hasErrors, isTrue);
      expect(
        nodePredicateError.runtimeErrors.single,
        contains('WHERE clause expression'),
      );
    });

    test('supports UNION de-duplication for null/list/map values', () {
      final graph = InMemoryGraphStore();

      final nullUnion = CypherEngine.execute(
        'RETURN null AS v UNION RETURN null AS v',
        graph: graph,
      );
      expect(nullUnion.hasErrors, isFalse);
      expect(nullUnion.records.length, 1);

      final listUnion = CypherEngine.execute(
        'RETURN [1, 2] AS v UNION RETURN [1, 2] AS v',
        graph: graph,
      );
      expect(listUnion.hasErrors, isFalse);
      expect(listUnion.records.length, 1);

      final mapUnion = CypherEngine.execute(
        "RETURN {b: 2, a: 1} AS v UNION RETURN {a: 1, b: 2} AS v",
        graph: graph,
      );
      expect(mapUnion.hasErrors, isFalse);
      expect(mapUnion.records.length, 1);
    });

    test('handles keyword splitting with quoted and backtick content', () {
      final quoted = CypherEngine.execute(
        "WITH true AS t WHERE ('a OR b' = 'a OR b') OR t RETURN t",
        graph: InMemoryGraphStore(),
      );
      expect(quoted.hasErrors, isFalse);
      expect(quoted.records.single['t'], isTrue);

      final backtickOr = CypherEngine.execute(
        'WITH true AS t, false AS `x OR y` WHERE t OR `x OR y` RETURN t',
        graph: InMemoryGraphStore(),
      );
      expect(backtickOr.hasErrors, isFalse);
      expect(backtickOr.records.single['t'], isTrue);

      final backtickAnd = CypherEngine.execute(
        'WITH false AS t, true AS `x AND y` WHERE t AND `x AND y` RETURN t',
        graph: InMemoryGraphStore(),
      );
      expect(backtickAnd.hasErrors, isFalse);
      expect(backtickAnd.records, isEmpty);
    });

    test('supports chained patterns and shorthand arrow syntax', () {
      final graph = InMemoryGraphStore();
      final seed = CypherEngine.execute(
        "CREATE (:Person {name: 'A'})-[:KNOWS]->(:Person {name: 'B'})-[:KNOWS]->(:Person {name: 'C'})",
        graph: graph,
      );
      expect(seed.hasErrors, isFalse);

      final chainMatch = CypherEngine.execute(
        "MATCH p = (a:Person {name: 'A'})-->(b:Person)-->(c:Person {name: 'C'}) RETURN b.name AS b, length(p) AS l",
        graph: graph,
      );
      expect(chainMatch.hasErrors, isFalse);
      expect(chainMatch.records.single, <String, Object?>{'b': 'B', 'l': 2});

      final incomingShorthand = CypherEngine.execute(
        "MATCH (c:Person {name: 'C'})<--(b:Person)<--(a:Person {name: 'A'}) RETURN b.name AS b",
        graph: graph,
      );
      expect(incomingShorthand.hasErrors, isFalse);
      expect(
        incomingShorthand.records.single,
        <String, Object?>{'b': 'B'},
      );
    });

    test('supports arithmetic, collect/type, and index expressions', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(
        labels: const <String>{'Person'},
        properties: const <String, Object?>{'name': 'A'},
      );
      final b = graph.createNode(
        labels: const <String>{'Person'},
        properties: const <String, Object?>{'name': 'B'},
      );
      graph.createRelationship(
        startNodeId: a.id,
        endNodeId: b.id,
        type: 'KNOWS',
      );

      final moduloAndCollect = CypherEngine.execute(
        'UNWIND [1, 2, 3, 4] AS n WITH n WHERE n % 2 = 0 RETURN collect(n) AS evens',
        graph: graph,
      );
      expect(moduloAndCollect.hasErrors, isFalse);
      expect(moduloAndCollect.records.single['evens'], <Object?>[2, 4]);

      final relType = CypherEngine.execute(
        'MATCH ()-[r:KNOWS]->() RETURN type(r) AS t',
        graph: graph,
      );
      expect(relType.hasErrors, isFalse);
      expect(relType.records.single['t'], 'KNOWS');

      final indexAccess = CypherEngine.execute(
        'WITH {key: [10, 20, 30]} AS m, 1 AS i RETURN m.key[i] AS v',
        graph: graph,
      );
      expect(indexAccess.hasErrors, isFalse);
      expect(indexAccess.records.single['v'], 20);

      final arithmetic = CypherEngine.execute(
        'RETURN (1 + 2) * 3 AS v',
        graph: graph,
      );
      expect(arithmetic.hasErrors, isFalse);
      expect(arithmetic.records.single['v'], 9);
    });

    test('supports power arithmetic, scalar math functions, and rand', () {
      final graph = InMemoryGraphStore();
      final result = CypherEngine.execute(
        "RETURN 2 ^ 3 ^ 2 AS p, abs(-3.5) AS absValue, ceil(1.2) AS ceilValue, floor(1.8) AS floorValue, rand() AS randomValue, range(1, 5, 2) AS rangeValue, toBoolean('false') AS boolValue",
        graph: graph,
      );
      expect(result.hasErrors, isFalse);
      expect(result.records.single['p'], 512.0);
      expect(result.records.single['absValue'], 3.5);
      expect(result.records.single['ceilValue'], 2);
      expect(result.records.single['floorValue'], 1);
      expect(result.records.single['rangeValue'], <Object?>[1, 3, 5]);
      expect(result.records.single['boolValue'], isFalse);
      final randomValue = result.records.single['randomValue'];
      expect(randomValue, isA<double>());
      expect(randomValue as double, inInclusiveRange(0, 1));

      final nanDivision = CypherEngine.execute(
        'RETURN 0.0 / 0.0 AS n',
        graph: graph,
      );
      expect(nanDivision.hasErrors, isFalse);
      expect((nanDivision.records.single['n'] as double).isNaN, isTrue);
    });

    test('supports list slicing and parameterized arithmetic expressions', () {
      final graph = InMemoryGraphStore();

      final slices = CypherEngine.execute(
        'WITH [1, 2, 3, 4, 5] AS list RETURN list[1..3] AS mid, list[1..] AS fromOne, list[..2] AS toTwo, list[-3..-1] AS negative, list[3..1] AS empty',
        graph: graph,
      );
      expect(slices.hasErrors, isFalse);
      final row = slices.records.single;
      expect(row['mid'], <Object?>[2, 3]);
      expect(row['fromOne'], <Object?>[2, 3, 4, 5]);
      expect(row['toTwo'], <Object?>[1, 2]);
      expect(row['negative'], <Object?>[3, 4]);
      expect(row['empty'], <Object?>[]);

      final nullBound = CypherEngine.execute(
        'WITH [1, 2, 3] AS list RETURN list[null..2] AS r',
        graph: graph,
      );
      expect(nullBound.hasErrors, isFalse);
      expect(nullBound.records.single['r'], isNull);

      final chained = CypherEngine.execute(
        'RETURN [1, 2, 3][0] AS first, [1, 2, 3][1..3][0] AS slicedFirst',
        graph: graph,
      );
      expect(chained.hasErrors, isFalse);
      expect(chained.records.single['first'], 1);
      expect(chained.records.single['slicedFirst'], 2);

      final parameterArithmetic = CypherEngine.execute(
        r'UNWIND [1, 2, 3] AS person RETURN $age + avg(person) - 1000 AS v',
        graph: graph,
        parameters: const <String, Object?>{'age': 30},
      );
      expect(parameterArithmetic.hasErrors, isFalse);
      expect(parameterArithmetic.records.single['v'], -968.0);
    });

    test('supports SET with parenthesized targets', () {
      final graph = InMemoryGraphStore();
      final setNode = CypherEngine.execute(
        "CREATE (n) SET (n).name = 'neo4j', n:Foo:Bar RETURN labels(n) AS labels, n.name AS name",
        graph: graph,
      );
      expect(setNode.hasErrors, isFalse);
      final labels = setNode.records.single['labels'] as List<Object?>;
      expect(labels.toSet(), containsAll(<Object?>['Foo', 'Bar']));
      expect(setNode.records.single['name'], 'neo4j');

      final setRel = CypherEngine.execute(
        "CREATE (a), (b), (a)-[r:REL]->(b) SET (r).name = 'rel' RETURN r.name AS name",
        graph: graph,
      );
      expect(setRel.hasErrors, isFalse);
      expect(setRel.records.single['name'], 'rel');

      final spacedLabels = CypherEngine.execute(
        "MATCH (n) SET n :Foo :Bar RETURN labels(n) AS labels",
        graph: graph,
      );
      expect(spacedLabels.hasErrors, isFalse);
      for (final record in spacedLabels.records) {
        expect(
          (record['labels'] as List<Object?>).toSet(),
          containsAll(<Object?>['Foo', 'Bar']),
        );
      }
    });

    test(
      'supports graph helper functions and dynamic property access expressions',
      () {
        final graph = InMemoryGraphStore();
        final a = graph.createNode(
          labels: const <String>{'User', 'Admin'},
          properties: const <String, Object?>{'id': 1, 'name': 'A'},
        );
        final b = graph.createNode(
          labels: const <String>{'User'},
          properties: const <String, Object?>{'id': 2},
        );
        graph.createRelationship(
          startNodeId: a.id,
          endNodeId: b.id,
          type: 'KNOWS',
          properties: const <String, Object?>{'since': 2020},
        );

        final result = CypherEngine.execute(
          "MATCH p = (a)-[r:KNOWS]->(b) RETURN labels(a) AS labelsA, keys(a) AS keysA, keys(r) AS keysR, startNode(r).id AS startId, endNode(r).id AS endId, nodes(p)[0].id AS firstNodeId, type(relationships(p)[0]) AS firstRelType, split('one1two', '1')[1] AS splitPart, head([1, 2, 3]) AS headValue, last([1, 2, 3]) AS lastValue, tail([1, 2, 3]) AS tailValue, toLower('ABC') AS lowerValue, toUpper('abc') AS upperValue",
          graph: graph,
        );
        expect(result.hasErrors, isFalse);

        final row = result.records.single;
        expect(row['labelsA'], isA<List<Object?>>());
        expect((row['labelsA'] as List<Object?>).toSet(),
            containsAll(<Object?>['User', 'Admin']));
        expect((row['keysA'] as List<Object?>).toSet(),
            containsAll(<Object?>['id', 'name']));
        expect(row['keysR'], <Object?>['since']);
        expect(row['startId'], 1);
        expect(row['endId'], 2);
        expect(row['firstNodeId'], 1);
        expect(row['firstRelType'], 'KNOWS');
        expect(row['splitPart'], 'two');
        expect(row['headValue'], 1);
        expect(row['lastValue'], 3);
        expect(row['tailValue'], <Object?>[2, 3]);
        expect(row['lowerValue'], 'abc');
        expect(row['upperValue'], 'ABC');

        final dynamicProperty = CypherEngine.execute(
          "MATCH (n) RETURN n['na' + 'me'] AS name ORDER BY name",
          graph: graph,
        );
        expect(dynamicProperty.hasErrors, isFalse);
        expect(
          dynamicProperty.records,
          <Map<String, Object?>>[
            <String, Object?>{'name': 'A'},
            <String, Object?>{'name': null},
          ],
        );

        final parameterizedDynamicProperty = CypherEngine.execute(
          'CREATE (n {name: \'Apa\'}) RETURN n[\$idx] AS value',
          graph: InMemoryGraphStore(),
          parameters: const <String, Object?>{'idx': 'name'},
        );
        expect(parameterizedDynamicProperty.hasErrors, isFalse);
        expect(parameterizedDynamicProperty.records.single['value'], 'Apa');
      },
    );

    test('supports ORDER BY on projected aggregate expressions', () {
      final graph = InMemoryGraphStore();

      final grouped = CypherEngine.execute(
        'UNWIND [1, 1, 2] AS n RETURN n, count(*) ORDER BY count(*) DESC, n ASC',
        graph: graph,
      );
      expect(grouped.hasErrors, isFalse);
      expect(grouped.records.length, 2);
      expect(grouped.records.first['n'], 1);
      expect(grouped.records.first['count(*)'], 2);
      expect(grouped.records.last['n'], 2);
      expect(grouped.records.last['count(*)'], 1);

      final groupedWithAlias = CypherEngine.execute(
        'UNWIND [1, 1, 2] AS n RETURN n, count(*) AS total ORDER BY count(*) DESC, n ASC',
        graph: graph,
      );
      expect(groupedWithAlias.hasErrors, isFalse);
      expect(groupedWithAlias.records.first['n'], 1);
      expect(groupedWithAlias.records.first['total'], 2);
      expect(groupedWithAlias.records.last['n'], 2);
      expect(groupedWithAlias.records.last['total'], 1);

      final single = CypherEngine.execute(
        'UNWIND [1, 2, 3] AS n RETURN count(*) ORDER BY count(*)',
        graph: graph,
      );
      expect(single.hasErrors, isFalse);
      expect(single.records.single['count(*)'], 3);
    });

    test('supports label predicates, IN, IS NULL, and pattern predicates', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(
        labels: const <String>{'Person'},
        properties: const <String, Object?>{'name': 'A'},
      );
      final b = graph.createNode(
        labels: const <String>{'Person'},
        properties: const <String, Object?>{'name': 'B'},
      );
      graph.createRelationship(
        startNodeId: a.id,
        endNodeId: b.id,
        type: 'KNOWS',
      );

      final labelAndIn = CypherEngine.execute(
        "MATCH (a)-[:KNOWS]->(b) WHERE a:Person AND b.name IN ['B', 'C'] RETURN b.name AS b",
        graph: graph,
      );
      expect(labelAndIn.hasErrors, isFalse);
      expect(labelAndIn.records.single['b'], 'B');

      final patternPredicate = CypherEngine.execute(
        "MATCH (a:Person {name: 'A'}), (b:Person {name: 'B'}) WHERE (a)-[:KNOWS]->(b) RETURN b.name AS b",
        graph: graph,
      );
      expect(patternPredicate.hasErrors, isFalse);
      expect(patternPredicate.records.single['b'], 'B');

      final isNullProjection = CypherEngine.execute(
        "MATCH (a:Person {name: 'A'}) OPTIONAL MATCH (a)-[:FRIEND]->(f) RETURN f IS NULL AS missing",
        graph: graph,
      );
      expect(isNullProjection.hasErrors, isFalse);
      expect(isNullProjection.records.single['missing'], isTrue);

      final patternWithOr = CypherEngine.execute(
        "MATCH (a), (b) WHERE a.name = 'A' AND (a)-[:KNOWS]->(b:Person) OR (a)-[:KNOWS*]->(b:MissingLabel) RETURN DISTINCT b.name AS name",
        graph: graph,
      );
      expect(patternWithOr.hasErrors, isFalse);
      expect(patternWithOr.records.single['name'], 'B');
    });

    test('supports DELETE targets from expressions and path values', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(
        labels: const <String>{'User'},
        properties: const <String, Object?>{'id': 1},
      );
      final b = graph.createNode(
        labels: const <String>{'User'},
        properties: const <String, Object?>{'id': 2},
      );
      final c = graph.createNode(
        labels: const <String>{'User'},
        properties: const <String, Object?>{'id': 3},
      );
      graph.createRelationship(
          startNodeId: a.id, endNodeId: b.id, type: 'FRIEND');
      graph.createRelationship(
          startNodeId: b.id, endNodeId: c.id, type: 'FRIEND');

      final deleteFromList = CypherEngine.execute(
        'MATCH (:User)-[r:FRIEND]->() WITH collect(r) AS rels DELETE rels[0] RETURN count(*) AS c',
        graph: graph,
      );
      expect(deleteFromList.hasErrors, isFalse);

      final remainingAfterListDelete = CypherEngine.execute(
        'MATCH ()-[r:FRIEND]->() RETURN count(r) AS c',
        graph: graph,
      );
      expect(remainingAfterListDelete.hasErrors, isFalse);
      expect(remainingAfterListDelete.records.single['c'], 1);

      final deletePath = CypherEngine.execute(
        'MATCH p = (:User {id: 2})-[:FRIEND]->(:User {id: 3}) DETACH DELETE p RETURN count(*) AS c',
        graph: graph,
      );
      expect(deletePath.hasErrors, isFalse);

      final remainingAfterPathDelete = CypherEngine.execute(
        'MATCH ()-[r:FRIEND]->() RETURN count(r) AS c',
        graph: graph,
      );
      expect(remainingAfterPathDelete.hasErrors, isFalse);
      expect(remainingAfterPathDelete.records.single['c'], 0);
    });

    test('supports DISTINCT in RETURN and WITH projections', () {
      final graph = InMemoryGraphStore();

      final distinctReturn = CypherEngine.execute(
        'UNWIND [1, 1, 2] AS n RETURN DISTINCT n AS n ORDER BY n',
        graph: graph,
      );
      expect(distinctReturn.hasErrors, isFalse);
      expect(
        distinctReturn.records,
        <Map<String, Object?>>[
          <String, Object?>{'n': 1},
          <String, Object?>{'n': 2},
        ],
      );

      final distinctWith = CypherEngine.execute(
        'UNWIND [1, 1, 2] AS n WITH DISTINCT n AS v RETURN count(v) AS c',
        graph: graph,
      );
      expect(distinctWith.hasErrors, isFalse);
      expect(distinctWith.records.single['c'], 2);

      final distinctAggregateArgs = CypherEngine.execute(
        'UNWIND [1, 1, 2, null] AS n RETURN count(DISTINCT n) AS c, collect(DISTINCT n) AS values',
        graph: graph,
      );
      expect(distinctAggregateArgs.hasErrors, isFalse);
      expect(distinctAggregateArgs.records.single['c'], 2);
      expect(
        distinctAggregateArgs.records.single['values'],
        <Object?>[1, 2],
      );

      final distinctAcrossNumericTypes = CypherEngine.execute(
        'UNWIND [1, 1.0, 2, 2.0, null] AS n RETURN count(DISTINCT n) AS c, sum(DISTINCT n) AS s, avg(DISTINCT n) AS a, min(DISTINCT n) AS minValue, max(DISTINCT n) AS maxValue',
        graph: graph,
      );
      expect(distinctAcrossNumericTypes.hasErrors, isFalse);
      expect(distinctAcrossNumericTypes.records.single['c'], 2);
      expect(distinctAcrossNumericTypes.records.single['s'], 3);
      expect(distinctAcrossNumericTypes.records.single['a'], 1.5);
      expect(distinctAcrossNumericTypes.records.single['minValue'], 1);
      expect(distinctAcrossNumericTypes.records.single['maxValue'], 2);
    });

    test('supports nested aggregate expressions in maps and lists', () {
      final graph = InMemoryGraphStore()
        ..createNode(
          labels: const <String>{'User'},
          properties: const <String, Object?>{'id': 1},
        )
        ..createNode(
          labels: const <String>{'User'},
          properties: const <String, Object?>{'id': 2},
        );

      final mapAggregate = CypherEngine.execute(
        'MATCH (u:User) WITH {key: collect(u.id)} AS nodeMap RETURN size(nodeMap.key) AS c, nodeMap.key[0] IS NULL AS isNull',
        graph: graph,
      );
      expect(mapAggregate.hasErrors, isFalse);
      expect(mapAggregate.records.single['c'], 2);
      expect(mapAggregate.records.single['isNull'], isFalse);

      final listAggregate = CypherEngine.execute(
        'MATCH (u:User) RETURN [collect(u.id), count(*)] AS payload',
        graph: graph,
      );
      expect(listAggregate.hasErrors, isFalse);
      final payload = listAggregate.records.single['payload'] as List<Object?>;
      expect((payload[0] as List<Object?>).length, 2);
      expect(payload[1], 2);
    });

    test('supports boolean precedence and three-valued logic', () {
      final graph = InMemoryGraphStore();
      final result = CypherEngine.execute(
        'RETURN true OR true XOR true AS a, true XOR false AND false AS b, NOT false >= false AS c, false = true IS NULL AS d, null AND true AS andNull, null OR false AS orNull, null XOR true AS xorNull, NOT null AS notNull',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      final row = result.records.single;
      expect(row['a'], isTrue);
      expect(row['b'], isTrue);
      expect(row['c'], isFalse);
      expect(row['d'], isTrue);
      expect(row['andNull'], isNull);
      expect(row['orNull'], isNull);
      expect(row['xorNull'], isNull);
      expect(row['notNull'], isNull);
    });

    test('supports chained comparison ranges', () {
      final graph = InMemoryGraphStore();
      final numbers = CypherEngine.execute(
        'UNWIND [1, 2, 3] AS n WITH n WHERE 1 < n < 3 RETURN collect(n) AS values',
        graph: graph,
      );
      expect(numbers.hasErrors, isFalse);
      expect(numbers.records.single['values'], <Object?>[2]);

      final strings = CypherEngine.execute(
        "UNWIND ['a', 'b', 'c'] AS n WITH n WHERE 'a' <= n < 'c' RETURN collect(n) AS values",
        graph: graph,
      );
      expect(strings.hasErrors, isFalse);
      expect(strings.records.single['values'], <Object?>['a', 'b']);
    });

    test('supports string predicates STARTS WITH, ENDS WITH, and CONTAINS', () {
      final graph = InMemoryGraphStore();
      final result = CypherEngine.execute(
        "RETURN 'ABCDEF' STARTS WITH 'ABC' AS startsWith, 'ABCDEF' ENDS WITH 'DEF' AS endsWith, 'ABCDEF' CONTAINS 'CD' AS containsValue, 'ABCDEF' STARTS WITH null AS startsWithNull, 1 STARTS WITH '1' AS nonString",
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      final row = result.records.single;
      expect(row['startsWith'], isTrue);
      expect(row['endsWith'], isTrue);
      expect(row['containsValue'], isTrue);
      expect(row['startsWithNull'], isNull);
      expect(row['nonString'], isNull);
    });

    test('supports list and pattern comprehensions', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(
        properties: const <String, Object?>{'name': 'A'},
      );
      final b = graph.createNode(
        properties: const <String, Object?>{'name': 'B'},
      );
      final c = graph.createNode();
      graph.createRelationship(startNodeId: a.id, endNodeId: b.id, type: 'T');
      graph.createRelationship(startNodeId: b.id, endNodeId: c.id, type: 'T');

      final result = CypherEngine.execute(
        'MATCH (n) RETURN id(n) AS id, size([p = (n)-->() | p]) AS pathCount, [(n)-->(m) | m.name] AS names ORDER BY id',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      expect(result.records, <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'pathCount': 1,
          'names': <Object?>['B']
        },
        <String, Object?>{
          'id': 2,
          'pathCount': 1,
          'names': <Object?>[null]
        },
        <String, Object?>{'id': 3, 'pathCount': 0, 'names': <Object?>[]},
      ]);
    });

    test('supports list predicate functions all/any/none/single', () {
      final graph = InMemoryGraphStore();
      final result = CypherEngine.execute(
        'WITH [true, null] AS values RETURN all(x IN values WHERE x) AS allValue, any(x IN values WHERE x) AS anyValue, none(x IN values WHERE x) AS noneValue, single(x IN values WHERE x) AS singleValue',
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      final row = result.records.single;
      expect(row['allValue'], isNull);
      expect(row['anyValue'], isTrue);
      expect(row['noneValue'], isFalse);
      expect(row['singleValue'], isNull);
    });

    test('supports toString and list comprehension conversion', () {
      final graph = InMemoryGraphStore();
      final result = CypherEngine.execute(
        "RETURN toString(42) AS i, toString(true) AS b, toString(1 < 0) AS boolValue, [x IN [1, 2.3, true, 'apa'] | toString(x)] AS list",
        graph: graph,
      );

      expect(result.hasErrors, isFalse);
      final row = result.records.single;
      expect(row['i'], '42');
      expect(row['b'], 'true');
      expect(row['boolValue'], 'false');
      expect(row['list'], <Object?>['1', '2.3', 'true', 'apa']);
    });

    test('supports SET map replacement/merge and null targets', () {
      final graph = InMemoryGraphStore();
      graph.createNode(
        labels: const <String>{'X'},
        properties: const <String, Object?>{'name': 'A', 'name2': 'B'},
      );

      final replace = CypherEngine.execute(
        "MATCH (n:X) SET n = {name: 'B', baz: 'C'} RETURN n.name AS name, n.name2 AS name2, n.baz AS baz",
        graph: graph,
      );
      expect(replace.hasErrors, isFalse);
      expect(replace.records.single, <String, Object?>{
        'name': 'B',
        'name2': null,
        'baz': 'C',
      });

      final merge = CypherEngine.execute(
        'MATCH (n:X) SET n += {baz: null, age: 10} RETURN n.name AS name, n.baz AS baz, n.age AS age',
        graph: graph,
      );
      expect(merge.hasErrors, isFalse);
      expect(merge.records.single, <String, Object?>{
        'name': 'B',
        'baz': null,
        'age': 10,
      });

      final optionalNull = CypherEngine.execute(
        'OPTIONAL MATCH (a:DoesNotExist) SET a = {num: 42} RETURN a',
        graph: graph,
      );
      expect(optionalNull.hasErrors, isFalse);
      expect(optionalNull.records.single['a'], isNull);
    });

    test('supports variable-length relationship patterns in MATCH', () {
      final graph = InMemoryGraphStore();
      final n1 = graph.createNode(
        labels: const <String>{'N'},
        properties: const <String, Object?>{'id': 1},
      );
      final n2 = graph.createNode(
        labels: const <String>{'N'},
        properties: const <String, Object?>{'id': 2},
      );
      final n3 = graph.createNode(
        labels: const <String>{'N'},
        properties: const <String, Object?>{'id': 3},
      );
      graph.createRelationship(startNodeId: n1.id, endNodeId: n2.id, type: 'R');
      graph.createRelationship(startNodeId: n2.id, endNodeId: n3.id, type: 'R');

      final fixedLength = CypherEngine.execute(
        'MATCH p = (:N {id: 1})-[r:R*2]->(:N {id: 3}) RETURN length(p) AS l, size(r) AS s',
        graph: graph,
      );
      expect(fixedLength.hasErrors, isFalse);
      expect(fixedLength.records.single['l'], 2);
      expect(fixedLength.records.single['s'], 2);

      final rangeLength = CypherEngine.execute(
        'MATCH (:N {id: 1})-[r:R*0..1]->(n) RETURN count(*) AS c',
        graph: graph,
      );
      expect(rangeLength.hasErrors, isFalse);
      expect(rangeLength.records.single['c'], 2);

      final singleHopStar = CypherEngine.execute(
        'MATCH (:N {id: 1})-[r:R*1]->(:N {id: 2}) RETURN r AS rels, size(r) AS s, type(r[0]) AS t',
        graph: graph,
      );
      expect(singleHopStar.hasErrors, isFalse);
      expect(singleHopStar.records.single['rels'], isA<List<Object?>>());
      expect(singleHopStar.records.single['s'], 1);
      expect(singleHopStar.records.single['t'], 'R');

      final plainSingleHop = CypherEngine.execute(
        'MATCH (:N {id: 1})-[r:R]->(:N {id: 2}) RETURN r AS rel, type(r) AS t',
        graph: graph,
      );
      expect(plainSingleHop.hasErrors, isFalse);
      expect(
          plainSingleHop.records.single['rel'], isA<CypherGraphRelationship>());
      expect(plainSingleHop.records.single['t'], 'R');
    });
  });
}
