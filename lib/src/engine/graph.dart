import 'package:meta/meta.dart';

/// An immutable graph node value used by [InMemoryGraphStore].
@immutable
final class CypherGraphNode {
  /// Creates a graph node value.
  CypherGraphNode({
    required this.id,
    Set<String> labels = const <String>{},
    Map<String, Object?> properties = const <String, Object?>{},
  })  : labels = Set<String>.unmodifiable(labels),
        properties = Map<String, Object?>.unmodifiable(properties);

  /// The unique node identifier.
  final int id;

  /// The node labels.
  final Set<String> labels;

  /// The node property map.
  final Map<String, Object?> properties;
}

/// An immutable graph relationship value used by [InMemoryGraphStore].
@immutable
final class CypherGraphRelationship {
  /// Creates a graph relationship value.
  CypherGraphRelationship({
    required this.id,
    required this.startNodeId,
    required this.endNodeId,
    required this.type,
    Map<String, Object?> properties = const <String, Object?>{},
  }) : properties = Map<String, Object?>.unmodifiable(properties);

  /// The unique relationship identifier.
  final int id;

  /// The start node identifier.
  final int startNodeId;

  /// The end node identifier.
  final int endNodeId;

  /// The relationship type.
  final String type;

  /// The relationship property map.
  final Map<String, Object?> properties;
}

/// A path value containing ordered nodes and relationships.
@immutable
final class CypherGraphPath {
  /// Creates a path value.
  CypherGraphPath({
    required List<CypherGraphNode> nodes,
    required List<CypherGraphRelationship> relationships,
  })  : nodes = List<CypherGraphNode>.unmodifiable(nodes),
        relationships =
            List<CypherGraphRelationship>.unmodifiable(relationships);

  /// The ordered path nodes.
  final List<CypherGraphNode> nodes;

  /// The ordered path relationships.
  final List<CypherGraphRelationship> relationships;
}

/// An in-memory graph store used by [CypherEngine.execute].
final class InMemoryGraphStore {
  final Map<int, CypherGraphNode> _nodes = <int, CypherGraphNode>{};
  final Map<int, CypherGraphRelationship> _relationships =
      <int, CypherGraphRelationship>{};
  int _nextNodeId = 1;
  int _nextRelationshipId = 1;

  /// The current node collection.
  Iterable<CypherGraphNode> get nodes => _nodes.values;

  /// The current relationship collection.
  Iterable<CypherGraphRelationship> get relationships => _relationships.values;

  /// The node with [id], if present.
  CypherGraphNode? nodeById(int id) => _nodes[id];

  /// The relationship with [id], if present.
  CypherGraphRelationship? relationshipById(int id) => _relationships[id];

  /// The relationships connected to [nodeId].
  Iterable<CypherGraphRelationship> relationshipsForNode(int nodeId) {
    return _relationships.values.where(
      (relationship) =>
          relationship.startNodeId == nodeId ||
          relationship.endNodeId == nodeId,
    );
  }

  /// Creates and stores a new node.
  CypherGraphNode createNode({
    Set<String> labels = const <String>{},
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    final node = CypherGraphNode(
      id: _nextNodeId++,
      labels: labels,
      properties: properties,
    );
    _nodes[node.id] = node;
    return node;
  }

  /// Creates and stores a new relationship.
  ///
  /// Throws an [ArgumentError] if [startNodeId] or [endNodeId] is unknown.
  CypherGraphRelationship createRelationship({
    required int startNodeId,
    required int endNodeId,
    required String type,
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    if (!_nodes.containsKey(startNodeId)) {
      throw ArgumentError('Unknown start node id: $startNodeId');
    }
    if (!_nodes.containsKey(endNodeId)) {
      throw ArgumentError('Unknown end node id: $endNodeId');
    }

    final relationship = CypherGraphRelationship(
      id: _nextRelationshipId++,
      startNodeId: startNodeId,
      endNodeId: endNodeId,
      type: type,
      properties: properties,
    );
    _relationships[relationship.id] = relationship;
    return relationship;
  }

  /// Sets the node property [key] to [value] on [nodeId].
  ///
  /// Removes [key] when [value] is `null`.
  ///
  /// Throws an [ArgumentError] if [nodeId] is unknown.
  CypherGraphNode setNodeProperty({
    required int nodeId,
    required String key,
    required Object? value,
  }) {
    final node = _nodes[nodeId];
    if (node == null) {
      throw ArgumentError('Unknown node id: $nodeId');
    }

    final properties = Map<String, Object?>.from(node.properties);
    if (value == null) {
      properties.remove(key);
    } else {
      properties[key] = value;
    }

    final updated = CypherGraphNode(
      id: node.id,
      labels: node.labels,
      properties: properties,
    );
    _nodes[nodeId] = updated;
    return updated;
  }

  /// Sets the relationship property [key] to [value] on [relationshipId].
  ///
  /// Removes [key] when [value] is `null`.
  ///
  /// Throws an [ArgumentError] if [relationshipId] is unknown.
  CypherGraphRelationship setRelationshipProperty({
    required int relationshipId,
    required String key,
    required Object? value,
  }) {
    final relationship = _relationships[relationshipId];
    if (relationship == null) {
      throw ArgumentError('Unknown relationship id: $relationshipId');
    }

    final properties = Map<String, Object?>.from(relationship.properties);
    if (value == null) {
      properties.remove(key);
    } else {
      properties[key] = value;
    }

    final updated = CypherGraphRelationship(
      id: relationship.id,
      startNodeId: relationship.startNodeId,
      endNodeId: relationship.endNodeId,
      type: relationship.type,
      properties: properties,
    );
    _relationships[relationshipId] = updated;
    return updated;
  }

  /// Adds [label] to the node at [nodeId].
  ///
  /// Throws an [ArgumentError] if [nodeId] is unknown.
  CypherGraphNode addNodeLabel({
    required int nodeId,
    required String label,
  }) {
    final node = _nodes[nodeId];
    if (node == null) {
      throw ArgumentError('Unknown node id: $nodeId');
    }

    final labels = Set<String>.from(node.labels)..add(label);
    final updated = CypherGraphNode(
      id: node.id,
      labels: labels,
      properties: node.properties,
    );
    _nodes[nodeId] = updated;
    return updated;
  }

  /// Removes [label] from the node at [nodeId].
  ///
  /// Throws an [ArgumentError] if [nodeId] is unknown.
  CypherGraphNode removeNodeLabel({
    required int nodeId,
    required String label,
  }) {
    final node = _nodes[nodeId];
    if (node == null) {
      throw ArgumentError('Unknown node id: $nodeId');
    }

    final labels = Set<String>.from(node.labels)..remove(label);
    final updated = CypherGraphNode(
      id: node.id,
      labels: labels,
      properties: node.properties,
    );
    _nodes[nodeId] = updated;
    return updated;
  }

  /// Deletes the relationship with [relationshipId].
  ///
  /// Returns `true` when a relationship was removed.
  bool deleteRelationship(int relationshipId) {
    return _relationships.remove(relationshipId) != null;
  }

  /// Deletes the node with [nodeId].
  ///
  /// When [detach] is `true`, all connected relationships are removed first.
  ///
  /// Returns `true` when a node was removed.
  ///
  /// Throws a [StateError] when [detach] is `false` and the node still has
  /// connected relationships.
  bool deleteNode(int nodeId, {bool detach = false}) {
    if (!_nodes.containsKey(nodeId)) {
      return false;
    }

    final related = relationshipsForNode(nodeId).toList(growable: false);
    if (related.isNotEmpty && !detach) {
      throw StateError(
        'Cannot delete node $nodeId while it still has relationships.',
      );
    }

    if (detach) {
      for (final relationship in related) {
        _relationships.remove(relationship.id);
      }
    }

    _nodes.remove(nodeId);
    return true;
  }
}
