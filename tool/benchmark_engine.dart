import 'dart:math';

import 'package:cypher_dart/cypher_dart.dart';

Object? _blackHole;

void main(List<String> args) {
  final iterations = _readIntArg(args, '--iterations', fallback: 300);
  final warmup = _readIntArg(args, '--warmup', fallback: 60);
  final nodeCount = _readIntArg(args, '--nodes', fallback: 2000);

  final readGraph = _buildPersonGraph(nodeCount);
  final relGraph = _buildRelationshipGraph(max(400, nodeCount ~/ 2));

  final scenarios = <_Scenario>[
    _Scenario(
      name: 'parse_simple',
      run: () => Cypher.parse(
        'MATCH (n:Person) WHERE n.age >= 30 RETURN n.name AS name ORDER BY name LIMIT 20',
      ),
    ),
    _Scenario(
      name: 'parse_complex',
      run: () => Cypher.parse(
        'MATCH (a:Person)-[r:KNOWS]->(b:Person) '
        'WHERE a.age >= 30 AND (b.city = "Seoul" OR b.city = "Busan") '
        'WITH a.city AS city, count(*) AS c '
        'RETURN city, c ORDER BY c DESC LIMIT 10',
      ),
    ),
    _Scenario(
      name: 'execute_filter_projection',
      run: () => CypherEngine.execute(
        'MATCH (n:Person) WHERE n.age >= 40 RETURN n.name AS name ORDER BY name LIMIT 20',
        graph: readGraph,
      ).records.length,
    ),
    _Scenario(
      name: 'execute_relationship_match',
      run: () => CypherEngine.execute(
        'MATCH (a:Person)-[r:KNOWS]->(b:Person) '
        'WHERE r.since >= 2015 RETURN a.name AS a, b.name AS b, r.since AS y '
        'ORDER BY y DESC LIMIT 50',
        graph: relGraph,
      ).records.length,
    ),
    _Scenario(
      name: 'execute_aggregation',
      run: () => CypherEngine.execute(
        'MATCH (n:Person) WITH n.city AS city, count(*) AS c '
        'RETURN city, c ORDER BY c DESC LIMIT 10',
        graph: readGraph,
      ).records.length,
    ),
    _Scenario(
      name: 'execute_merge_on_match',
      run: () => CypherEngine.execute(
        'MERGE (n:Person {name: "seed"}) '
        'ON CREATE SET n.created = true '
        'ON MATCH SET n.hit = true '
        'RETURN n.hit',
        graph: _buildSeedGraph(),
      ).records.single['n.hit'],
    ),
  ];

  final results = <_Result>[];
  for (final scenario in scenarios) {
    results.add(
      _measure(
        scenario: scenario,
        warmup: warmup,
        iterations: iterations,
      ),
    );
  }

  print('cypher_dart benchmark');
  print(
    'iterations=$iterations warmup=$warmup nodes=$nodeCount '
    '(launcher-dependent, indicative only)',
  );
  print('');
  print('scenario                          avg_ms/op     ops/s');
  print('-------------------------------------------------------');
  for (final result in results) {
    final name = result.name.padRight(32);
    final avgMs = result.avgMicroseconds / 1000.0;
    final avgStr = avgMs.toStringAsFixed(4).padLeft(10);
    final opsStr = result.opsPerSecond.toStringAsFixed(1).padLeft(10);
    print('$name  $avgStr  $opsStr');
  }
}

_Result _measure({
  required _Scenario scenario,
  required int warmup,
  required int iterations,
}) {
  for (var i = 0; i < warmup; i++) {
    _blackHole = scenario.run();
  }

  final sw = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    _blackHole = scenario.run();
  }
  sw.stop();

  // Prevent dead-code elimination in future optimized modes.
  if (_blackHole == const Object()) {
    throw StateError('Unreachable');
  }

  final totalMicros = max(1, sw.elapsedMicroseconds);
  final avgMicros = totalMicros / iterations;
  final opsPerSecond = iterations * 1000000 / totalMicros;

  return _Result(
    name: scenario.name,
    avgMicroseconds: avgMicros,
    opsPerSecond: opsPerSecond,
  );
}

int _readIntArg(List<String> args, String key, {required int fallback}) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == key) {
      final parsed = int.tryParse(args[i + 1]);
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
  }
  return fallback;
}

InMemoryGraphStore _buildPersonGraph(int count) {
  final graph = InMemoryGraphStore();
  final cities = <String>['Seoul', 'Busan', 'Incheon', 'Daegu', 'Daejeon'];
  for (var i = 0; i < count; i++) {
    graph.createNode(
      labels: <String>{'Person'},
      properties: <String, Object?>{
        'name': 'user_$i',
        'age': 18 + (i % 55),
        'city': cities[i % cities.length],
      },
    );
  }
  return graph;
}

InMemoryGraphStore _buildRelationshipGraph(int count) {
  final graph = InMemoryGraphStore();
  final ids = <int>[];
  for (var i = 0; i < count; i++) {
    ids.add(
      graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{
          'name': 'p_$i',
          'age': 20 + (i % 45),
          'city': i.isEven ? 'Seoul' : 'Busan',
        },
      ).id,
    );
  }
  for (var i = 0; i < ids.length - 1; i++) {
    graph.createRelationship(
      startNodeId: ids[i],
      endNodeId: ids[i + 1],
      type: 'KNOWS',
      properties: <String, Object?>{'since': 2000 + (i % 26)},
    );
  }
  return graph;
}

InMemoryGraphStore _buildSeedGraph() {
  final graph = InMemoryGraphStore();
  graph.createNode(
    labels: <String>{'Person'},
    properties: <String, Object?>{'name': 'seed'},
  );
  return graph;
}

final class _Scenario {
  const _Scenario({
    required this.name,
    required this.run,
  });

  final String name;
  final Object? Function() run;
}

final class _Result {
  const _Result({
    required this.name,
    required this.avgMicroseconds,
    required this.opsPerSecond,
  });

  final String name;
  final double avgMicroseconds;
  final double opsPerSecond;
}
