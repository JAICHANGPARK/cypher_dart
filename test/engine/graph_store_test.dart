import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryGraphStore', () {
    test('creates nodes and relationships and resolves lookups', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(
        labels: <String>{'Person'},
        properties: <String, Object?>{'name': 'A'},
      );
      final b = graph.createNode(properties: <String, Object?>{'name': 'B'});
      final rel = graph.createRelationship(
        startNodeId: a.id,
        endNodeId: b.id,
        type: 'KNOWS',
        properties: <String, Object?>{'since': 2020},
      );

      expect(graph.nodeById(a.id)!.properties['name'], 'A');
      expect(graph.relationshipById(rel.id)!.type, 'KNOWS');
      expect(graph.relationshipById(9999), isNull);
      expect(graph.relationshipsForNode(a.id).single.id, rel.id);
      expect(graph.relationshipsForNode(b.id).single.id, rel.id);
    });

    test('throws for unknown relationship endpoints', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode();

      expect(
        () => graph.createRelationship(
          startNodeId: 999,
          endNodeId: a.id,
          type: 'KNOWS',
        ),
        throwsArgumentError,
      );
      expect(
        () => graph.createRelationship(
          startNodeId: a.id,
          endNodeId: 999,
          type: 'KNOWS',
        ),
        throwsArgumentError,
      );
    });

    test('updates node and relationship properties', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode(properties: <String, Object?>{'name': 'A'});
      final b = graph.createNode();
      final rel = graph.createRelationship(
        startNodeId: a.id,
        endNodeId: b.id,
        type: 'KNOWS',
        properties: <String, Object?>{'since': 2020},
      );

      final updatedNode = graph.setNodeProperty(
        nodeId: a.id,
        key: 'age',
        value: 30,
      );
      expect(updatedNode.properties['age'], 30);
      final removedNode = graph.setNodeProperty(
        nodeId: a.id,
        key: 'age',
        value: null,
      );
      expect(removedNode.properties.containsKey('age'), isFalse);

      final updatedRel = graph.setRelationshipProperty(
        relationshipId: rel.id,
        key: 'weight',
        value: 1.5,
      );
      expect(updatedRel.properties['weight'], 1.5);
      final removedRel = graph.setRelationshipProperty(
        relationshipId: rel.id,
        key: 'weight',
        value: null,
      );
      expect(removedRel.properties.containsKey('weight'), isFalse);

      expect(
        () => graph.setNodeProperty(nodeId: 999, key: 'x', value: 1),
        throwsArgumentError,
      );
      expect(
        () => graph.setRelationshipProperty(
          relationshipId: 999,
          key: 'x',
          value: 1,
        ),
        throwsArgumentError,
      );
    });

    test('adds and removes labels and validates unknown node ids', () {
      final graph = InMemoryGraphStore();
      final node = graph.createNode(labels: <String>{'Person'});

      final added = graph.addNodeLabel(nodeId: node.id, label: 'Employee');
      expect(added.labels, containsAll(<String>['Person', 'Employee']));

      final removed = graph.removeNodeLabel(
        nodeId: node.id,
        label: 'Person',
      );
      expect(removed.labels, isNot(contains('Person')));

      expect(
        () => graph.addNodeLabel(nodeId: 999, label: 'Ghost'),
        throwsArgumentError,
      );
      expect(
        () => graph.removeNodeLabel(nodeId: 999, label: 'Ghost'),
        throwsArgumentError,
      );
    });

    test('deletes relationships and nodes with detach semantics', () {
      final graph = InMemoryGraphStore();
      final a = graph.createNode();
      final b = graph.createNode();
      final rel = graph.createRelationship(
        startNodeId: a.id,
        endNodeId: b.id,
        type: 'KNOWS',
      );

      expect(graph.deleteRelationship(rel.id), isTrue);
      expect(graph.deleteRelationship(rel.id), isFalse);

      final rel2 = graph.createRelationship(
        startNodeId: a.id,
        endNodeId: b.id,
        type: 'KNOWS',
      );
      expect(() => graph.deleteNode(a.id), throwsStateError);
      expect(graph.deleteNode(999), isFalse);
      expect(graph.deleteNode(a.id, detach: true), isTrue);
      expect(graph.relationshipById(rel2.id), isNull);
      expect(graph.nodeById(a.id), isNull);
      expect(graph.deleteNode(a.id), isFalse);
    });
  });
}
