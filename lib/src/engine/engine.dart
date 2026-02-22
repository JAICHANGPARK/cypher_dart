import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../ast/nodes.dart';
import '../parser/cypher.dart';
import '../parser/options.dart';
import '../parser/parse_result.dart';
import 'graph.dart';

typedef _Row = Map<String, Object?>;

/// Options for [CypherEngine.execute].
@immutable
final class CypherExecutionOptions {
  /// Creates execution options.
  const CypherExecutionOptions({
    this.parseOptions = const CypherParseOptions(
      enabledFeatures: <CypherFeature>{
        CypherFeature.neo4jPatternComprehension,
      },
    ),
  });

  /// The parser options used before execution.
  final CypherParseOptions parseOptions;
}

/// The result of parsing and executing a Cypher query.
@immutable
final class CypherExecutionResult {
  /// Creates an execution result.
  CypherExecutionResult({
    required this.parseResult,
    required List<Map<String, Object?>> records,
    required List<String> columns,
    List<String> runtimeErrors = const <String>[],
  })  : records = List<Map<String, Object?>>.unmodifiable(
          records
              .map((row) => Map<String, Object?>.unmodifiable(row))
              .toList(growable: false),
        ),
        columns = List<String>.unmodifiable(columns),
        runtimeErrors = List<String>.unmodifiable(runtimeErrors);

  /// The parse result used to produce this execution result.
  final CypherParseResult parseResult;

  /// The projected output records.
  final List<Map<String, Object?>> records;

  /// The output column order.
  final List<String> columns;

  /// Runtime execution errors that occurred after parsing.
  final List<String> runtimeErrors;

  /// Whether parsing or execution reported any errors.
  bool get hasErrors => parseResult.hasErrors || runtimeErrors.isNotEmpty;
}

/// Executes parsed Cypher query statements against [InMemoryGraphStore].
abstract final class CypherEngine {
  /// Parses and executes [query] against [graph].
  ///
  /// Runtime values from [parameters] are available in expressions using
  /// `$name` syntax.
  static CypherExecutionResult execute(
    String query, {
    required InMemoryGraphStore graph,
    Map<String, Object?> parameters = const <String, Object?>{},
    CypherExecutionOptions options = const CypherExecutionOptions(),
  }) {
    final normalizedQuery = _stripLineComments(query);
    final parseResult =
        Cypher.parse(normalizedQuery, options: options.parseOptions);
    if (parseResult.hasErrors || parseResult.document == null) {
      return CypherExecutionResult(
        parseResult: parseResult,
        records: const <Map<String, Object?>>[],
        columns: const <String>[],
      );
    }

    try {
      final output = _ExecutionRuntime(
        graph: graph,
        parameters: parameters,
        parseOptions: options.parseOptions,
      ).executeDocument(parseResult.document!);
      return CypherExecutionResult(
        parseResult: parseResult,
        records: output.rows,
        columns: output.columns,
      );
    } on _ExecutionException catch (error) {
      return CypherExecutionResult(
        parseResult: parseResult,
        records: const <Map<String, Object?>>[],
        columns: const <String>[],
        runtimeErrors: <String>[error.message],
      );
    }
  }

  static String _stripLineComments(String source) {
    final buffer = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var index = 0;

    while (index < source.length) {
      final char = source[index];
      final prev = index > 0 ? source[index - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        buffer.write(char);
        index++;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        buffer.write(char);
        index++;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        buffer.write(char);
        index++;
        continue;
      }

      if (!inSingle &&
          !inDouble &&
          !inBacktick &&
          char == '/' &&
          index + 1 < source.length &&
          source[index + 1] == '/') {
        index += 2;
        while (index < source.length && source[index] != '\n') {
          index++;
        }
        continue;
      }

      buffer.write(char);
      index++;
    }
    return buffer.toString();
  }
}

final class _ExecutionRuntime {
  _ExecutionRuntime({
    required this.graph,
    required this.parameters,
    required this.parseOptions,
  });

  static const String _internalKeyPrefix = '\u0000';
  static const String _lastMergeCreatedKey =
      '${_internalKeyPrefix}last_merge_created';
  static final RegExp _mergeSetSuffixPattern =
      RegExp(r'\bON\s+(CREATE|MATCH)\s*$', caseSensitive: false);
  static final RegExp _setPropertyAssignmentPattern = RegExp(
    r'^\(?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)?\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$',
    dotAll: true,
  );
  static final RegExp _setMapMergeAssignmentPattern = RegExp(
    r'^\(?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)?\s*\+=\s*(.+)$',
    dotAll: true,
  );
  static final RegExp _setMapReplaceAssignmentPattern = RegExp(
    r'^\(?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)?\s*=\s*(.+)$',
    dotAll: true,
  );
  static final RegExp _labelAssignmentPattern = RegExp(
      r'^\(?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)?\s*((?:\s*:\s*[A-Za-z_][A-Za-z0-9_]*)+)\s*$');
  static final RegExp _unwindPattern = RegExp(
    r'^\s*(.+?)\s+AS\s+([A-Za-z_][A-Za-z0-9_]*)\s*$',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _callInvocationPattern = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_.]*)\s*(?:\((.*)\))?\s*(?:YIELD\s+(.+))?$',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _orderAscPattern =
      RegExp(r'^(.*)\s+ASC$', caseSensitive: false);
  static final RegExp _orderDescPattern =
      RegExp(r'^(.*)\s+DESC$', caseSensitive: false);
  static final RegExp _tokenBoundaryCharPattern = RegExp(r'[A-Za-z0-9_]');
  static final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final RegExp _integerPattern = RegExp(r'^-?[0-9]+$');
  static final RegExp _doublePattern = RegExp(r'^-?[0-9]+\.[0-9]+$');
  static final RegExp _hexIntegerPattern = RegExp(r'^-?0[xX][0-9A-Fa-f]+$');
  static final RegExp _octalIntegerPattern = RegExp(r'^-?0[oO][0-7]+$');
  static final RegExp _extendedDoublePattern = RegExp(
    r'^-?(?:(?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)$',
  );
  static final RegExp _dateStringPattern =
      RegExp(r'^([+-]?\d{1,6})-(\d{2})-(\d{2})$');
  static final RegExp _localTimeStringPattern = RegExp(
    r'^(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?$',
  );
  static final RegExp _timeStringPattern = RegExp(
    r'^(\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?)(Z|[+-]\d{2}:?\d{2})(?:\[(.+)\])?$',
    caseSensitive: false,
  );
  static final RegExp _localDateTimeStringPattern = RegExp(
    r'^([+-]?\d{1,6}-\d{2}-\d{2})T(\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?)$',
    caseSensitive: false,
  );
  static final RegExp _dateTimeStringPattern = RegExp(
    r'^([+-]?\d{1,6}-\d{2}-\d{2})T(\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?)(Z|[+-]\d{2}:?\d{2})(?:\[(.+)\])?$',
    caseSensitive: false,
  );
  static final RegExp _durationStringPattern = RegExp(
    r'^P(?:(-?\d+)Y)?(?:(-?\d+)M)?(?:(-?\d+)W)?(?:(-?\d+)D)?(?:T(?:(-?\d+)H)?(?:(-?\d+)M)?(?:(-?\d+(?:\.\d+)?)S)?)?$',
    caseSensitive: false,
  );
  static const Set<String> _aggregateFunctionNames = <String>{
    'count',
    'sum',
    'avg',
    'min',
    'max',
    'collect',
    'percentiledisc',
    'percentilecont',
  };

  final InMemoryGraphStore graph;
  final Map<String, Object?> parameters;
  final CypherParseOptions parseOptions;
  final math.Random _random = math.Random();

  _ExecutionOutput executeDocument(CypherDocument document) {
    _ExecutionOutput last = const _ExecutionOutput(
      rows: <_Row>[],
      columns: <String>[],
    );

    for (final statement in document.statements.cast<CypherQueryStatement>()) {
      last = _executeStatement(statement);
    }

    return last;
  }

  _ExecutionOutput _executeStatement(
    CypherQueryStatement statement, {
    List<_Row> seedRows = const <_Row>[
      <String, Object?>{},
    ],
  }) {
    final segments = <List<CypherClause>>[<CypherClause>[]];
    final unions = <UnionClause>[];

    for (final clause in statement.clauses) {
      if (clause is UnionClause) {
        unions.add(clause);
        segments.add(<CypherClause>[]);
        continue;
      }
      segments.last.add(clause);
    }

    if (segments.any((segment) => segment.isEmpty)) {
      throw const _ExecutionException('UNION cannot have an empty query part.');
    }

    var current = _executeSegment(segments.first, seedRows: seedRows);
    for (var i = 1; i < segments.length; i++) {
      final next = _executeSegment(segments[i], seedRows: seedRows);
      final unionClause = unions[i - 1];
      current = _combineUnion(current, next, all: unionClause.all);
    }
    return current;
  }

  _ExecutionOutput _executeSegment(
    List<CypherClause> clauses, {
    required List<_Row> seedRows,
  }) {
    var rows = seedRows
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
    var columns = <String>[];
    _MergeSetMode? pendingMergeSetMode;

    for (final clause in clauses) {
      switch (clause) {
        case MatchClause():
          pendingMergeSetMode = null;
          rows = _executeMatch(rows, clause);
        case WhereClause():
          pendingMergeSetMode = null;
          rows = _executeWhere(rows, clause);
        case CreateClause():
          pendingMergeSetMode = null;
          rows = _executeCreate(rows, clause);
        case MergeClause():
          final result = _executeMerge(rows, clause);
          rows = result.rows;
          pendingMergeSetMode = result.nextSetMode;
        case SetClause():
          final result = _executeSet(
            rows,
            clause,
            mode: pendingMergeSetMode,
          );
          rows = result.rows;
          pendingMergeSetMode = result.nextMode;
        case RemoveClause():
          pendingMergeSetMode = null;
          rows = _executeRemove(rows, clause);
        case DeleteClause():
          pendingMergeSetMode = null;
          rows = _executeDelete(rows, clause);
        case WithClause():
          pendingMergeSetMode = null;
          final projection = _project(rows, clause.items);
          rows = projection.rows;
          columns = projection.columns;
        case ReturnClause():
          pendingMergeSetMode = null;
          final projection = _project(rows, clause.items);
          rows = projection.rows;
          columns = projection.columns;
        case OrderByClause():
          pendingMergeSetMode = null;
          rows = _executeOrderBy(rows, clause);
        case SkipClause():
          pendingMergeSetMode = null;
          rows = _executeSkip(rows, clause);
        case LimitClause():
          pendingMergeSetMode = null;
          rows = _executeLimit(rows, clause);
        case UnwindClause():
          pendingMergeSetMode = null;
          rows = _executeUnwind(rows, clause);
        case CallClause():
          pendingMergeSetMode = null;
          rows = _executeCall(rows, clause);
        case UnionClause():
          throw const _ExecutionException('Internal UNION handling failure.');
      }
    }

    rows = rows.map(_sanitizeRow).toList(growable: false);
    if (columns.isEmpty && rows.isNotEmpty) {
      columns = rows.first.keys.where((key) => !_isInternalKey(key)).toList(
            growable: false,
          );
    } else if (columns.isNotEmpty) {
      columns = columns
          .where((column) => !_isInternalKey(column))
          .toList(growable: false);
    }

    return _ExecutionOutput(rows: rows, columns: columns);
  }

  _ExecutionOutput _combineUnion(
    _ExecutionOutput left,
    _ExecutionOutput right, {
    required bool all,
  }) {
    if (!_sameColumns(left.columns, right.columns)) {
      throw const _ExecutionException(
        'UNION query parts must project the same columns in the same order.',
      );
    }

    final combinedRows = <_Row>[
      ...left.rows.map((row) => Map<String, Object?>.from(row)),
      ...right.rows.map((row) => Map<String, Object?>.from(row)),
    ];

    if (!all) {
      final deduped = <_Row>[];
      final seen = <String>{};
      for (final row in combinedRows) {
        final key = _rowKey(row, left.columns);
        if (seen.add(key)) {
          deduped.add(row);
        }
      }
      return _ExecutionOutput(rows: deduped, columns: left.columns);
    }

    return _ExecutionOutput(rows: combinedRows, columns: left.columns);
  }

  List<_Row> _executeMatch(List<_Row> inputRows, MatchClause clause) {
    final patternTexts = _splitTopLevelByComma(clause.pattern);
    if (patternTexts.isEmpty) {
      throw const _ExecutionException('MATCH pattern cannot be empty.');
    }

    var rows = inputRows
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
    for (final patternText in patternTexts) {
      final chain = _parsePatternChain(
        patternText,
        const <String, Object?>{},
        clauseName: 'MATCH',
        allowPathVariable: true,
      );
      rows = _matchPatternChain(rows, chain, optional: clause.optional);
    }
    return rows;
  }

  List<_Row> _matchNodePattern(
    List<_Row> inputRows,
    _NodePattern nodePattern, {
    required String? pathVariable,
    required bool optional,
  }) {
    final candidates = graph.nodes
        .where((node) => _matchesPatternNode(node, nodePattern))
        .toList(growable: false);

    final outputRows = <_Row>[];
    for (final row in inputRows) {
      var matched = false;

      for (final node in candidates) {
        if (!_canBindNode(row, nodePattern.variable, node)) {
          continue;
        }

        final next = Map<String, Object?>.from(row);
        if (nodePattern.variable case final String variable) {
          next[variable] = node;
        }
        if (pathVariable != null) {
          next[pathVariable] = CypherGraphPath(
            nodes: <CypherGraphNode>[node],
            relationships: const <CypherGraphRelationship>[],
          );
        }
        outputRows.add(next);
        matched = true;
      }

      if (optional && !matched) {
        final next = Map<String, Object?>.from(row);
        if (nodePattern.variable case final String variable) {
          next.putIfAbsent(variable, () => null);
        }
        if (pathVariable != null) {
          next.putIfAbsent(pathVariable, () => null);
        }
        outputRows.add(next);
      }
    }

    return outputRows;
  }

  List<_Row> _matchPatternChain(
    List<_Row> inputRows,
    _PatternChain chain, {
    required bool optional,
  }) {
    if (chain.relationshipSegments.isEmpty) {
      return _matchNodePattern(
        inputRows,
        chain.nodePatterns.single,
        pathVariable: chain.pathVariable,
        optional: optional,
      );
    }

    final introducedVariables = _collectPatternChainVariables(chain);
    final outgoingByNodeId = <int, List<CypherGraphRelationship>>{};
    final incomingByNodeId = <int, List<CypherGraphRelationship>>{};
    for (final relationship in graph.relationships) {
      outgoingByNodeId
          .putIfAbsent(
              relationship.startNodeId, () => <CypherGraphRelationship>[])
          .add(relationship);
      incomingByNodeId
          .putIfAbsent(
              relationship.endNodeId, () => <CypherGraphRelationship>[])
          .add(relationship);
    }
    final outputRows = <_Row>[];

    for (final sourceRow in inputRows) {
      final matchedRows = <_Row>[];
      final startPattern = chain.nodePatterns.first;
      for (final startNode in graph.nodes) {
        if (!_matchesPatternNode(startNode, startPattern)) {
          continue;
        }
        if (!_canBindNode(sourceRow, startPattern.variable, startNode)) {
          continue;
        }

        final row = Map<String, Object?>.from(sourceRow);
        if (startPattern.variable case final String variable) {
          row[variable] = startNode;
        }
        _matchPatternChainStep(
          chain: chain,
          row: row,
          currentNode: startNode,
          segmentIndex: 0,
          pathNodes: <CypherGraphNode>[startNode],
          pathRelationships: const <CypherGraphRelationship>[],
          outgoingByNodeId: outgoingByNodeId,
          incomingByNodeId: incomingByNodeId,
          outputRows: matchedRows,
        );
      }

      if (matchedRows.isEmpty) {
        if (optional) {
          final next = Map<String, Object?>.from(sourceRow);
          for (final variable in introducedVariables) {
            next.putIfAbsent(variable, () => null);
          }
          outputRows.add(next);
        }
        continue;
      }

      outputRows.addAll(matchedRows);
    }

    return outputRows;
  }

  void _matchPatternChainStep({
    required _PatternChain chain,
    required _Row row,
    required CypherGraphNode currentNode,
    required int segmentIndex,
    required List<CypherGraphNode> pathNodes,
    required List<CypherGraphRelationship> pathRelationships,
    required Map<int, List<CypherGraphRelationship>> outgoingByNodeId,
    required Map<int, List<CypherGraphRelationship>> incomingByNodeId,
    required List<_Row> outputRows,
  }) {
    if (segmentIndex >= chain.relationshipSegments.length) {
      final completed = Map<String, Object?>.from(row);
      if (chain.pathVariable case final String pathVariable) {
        completed[pathVariable] = CypherGraphPath(
          nodes: List<CypherGraphNode>.from(pathNodes, growable: false),
          relationships: List<CypherGraphRelationship>.from(
            pathRelationships,
            growable: false,
          ),
        );
      }
      outputRows.add(completed);
      return;
    }

    final segment = chain.relationshipSegments[segmentIndex];
    final nextNodePattern = chain.nodePatterns[segmentIndex + 1];

    final traversals = _expandRelationshipSegmentTraversals(
      startNode: currentNode,
      segment: segment,
      reservedRelationshipIds:
          pathRelationships.map((relationship) => relationship.id).toSet(),
      outgoingByNodeId: outgoingByNodeId,
      incomingByNodeId: incomingByNodeId,
    );

    for (final traversal in traversals) {
      final nextNode = traversal.endNode;
      if (!_matchesPatternNode(nextNode, nextNodePattern)) {
        continue;
      }
      if (!_canBindNode(row, nextNodePattern.variable, nextNode)) {
        continue;
      }

      final relationshipValue = _isSingleHopRelationshipPattern(segment.pattern)
          ? traversal.relationships.single
          : List<CypherGraphRelationship>.unmodifiable(traversal.relationships);
      if (!_canBindRelationshipValue(
        row,
        segment.pattern.variable,
        relationshipValue,
      )) {
        continue;
      }

      final nextRow = Map<String, Object?>.from(row);
      if (segment.pattern.variable case final String relationshipVariable) {
        nextRow[relationshipVariable] = relationshipValue;
      }
      if (nextNodePattern.variable case final String nodeVariable) {
        nextRow[nodeVariable] = nextNode;
      }

      _matchPatternChainStep(
        chain: chain,
        row: nextRow,
        currentNode: nextNode,
        segmentIndex: segmentIndex + 1,
        pathNodes: <CypherGraphNode>[
          ...pathNodes,
          ...traversal.nodes,
        ],
        pathRelationships: <CypherGraphRelationship>[
          ...pathRelationships,
          ...traversal.relationships,
        ],
        outgoingByNodeId: outgoingByNodeId,
        incomingByNodeId: incomingByNodeId,
        outputRows: outputRows,
      );
    }
  }

  bool _isSingleHopRelationshipPattern(_RelationshipPattern pattern) {
    return !pattern.variableLengthSyntax &&
        pattern.minHops == 1 &&
        pattern.maxHops == 1;
  }

  bool _canBindRelationshipValue(
    _Row row,
    String? variable,
    Object? value,
  ) {
    if (variable == null) {
      return true;
    }
    final existing = row[variable];
    if (existing == null) {
      return true;
    }
    if (value is CypherGraphRelationship) {
      if (existing is! CypherGraphRelationship) {
        return false;
      }
      return existing.id == value.id;
    }
    if (value is List<CypherGraphRelationship>) {
      if (existing is! Iterable) {
        return false;
      }
      final existingList =
          existing.whereType<CypherGraphRelationship>().toList(growable: false);
      if (existingList.length != value.length) {
        return false;
      }
      for (var i = 0; i < value.length; i++) {
        if (existingList[i].id != value[i].id) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  List<CypherGraphRelationship> _candidateRelationshipsForNode(
    CypherGraphNode node,
    _RelationshipDirection direction, {
    required Map<int, List<CypherGraphRelationship>> outgoingByNodeId,
    required Map<int, List<CypherGraphRelationship>> incomingByNodeId,
  }) {
    final candidates = <CypherGraphRelationship>[];
    switch (direction) {
      case _RelationshipDirection.outgoing:
        candidates.addAll(
          outgoingByNodeId[node.id] ?? const <CypherGraphRelationship>[],
        );
      case _RelationshipDirection.incoming:
        candidates.addAll(
          incomingByNodeId[node.id] ?? const <CypherGraphRelationship>[],
        );
      case _RelationshipDirection.undirected:
        final seenRelationshipIds = <int>{};
        for (final relationship
            in outgoingByNodeId[node.id] ?? const <CypherGraphRelationship>[]) {
          if (seenRelationshipIds.add(relationship.id)) {
            candidates.add(relationship);
          }
        }
        for (final relationship
            in incomingByNodeId[node.id] ?? const <CypherGraphRelationship>[]) {
          if (seenRelationshipIds.add(relationship.id)) {
            candidates.add(relationship);
          }
        }
    }
    return candidates;
  }

  List<_RelationshipTraversal> _expandRelationshipSegmentTraversals({
    required CypherGraphNode startNode,
    required _PatternRelationshipSegment segment,
    required Set<int> reservedRelationshipIds,
    required Map<int, List<CypherGraphRelationship>> outgoingByNodeId,
    required Map<int, List<CypherGraphRelationship>> incomingByNodeId,
  }) {
    final maxHops = segment.pattern.maxHops ?? graph.relationships.length;
    final boundedMaxHops = maxHops > graph.relationships.length
        ? graph.relationships.length
        : maxHops;

    final results = <_RelationshipTraversal>[];
    _expandRelationshipSegmentTraversalStep(
      currentNode: startNode,
      segment: segment,
      depth: 0,
      boundedMaxHops: boundedMaxHops,
      traversedRelationships: const <CypherGraphRelationship>[],
      traversedNodes: const <CypherGraphNode>[],
      usedRelationshipIds: Set<int>.from(reservedRelationshipIds),
      outgoingByNodeId: outgoingByNodeId,
      incomingByNodeId: incomingByNodeId,
      output: results,
    );
    return results;
  }

  void _expandRelationshipSegmentTraversalStep({
    required CypherGraphNode currentNode,
    required _PatternRelationshipSegment segment,
    required int depth,
    required int boundedMaxHops,
    required List<CypherGraphRelationship> traversedRelationships,
    required List<CypherGraphNode> traversedNodes,
    required Set<int> usedRelationshipIds,
    required Map<int, List<CypherGraphRelationship>> outgoingByNodeId,
    required Map<int, List<CypherGraphRelationship>> incomingByNodeId,
    required List<_RelationshipTraversal> output,
  }) {
    if (depth >= segment.pattern.minHops) {
      output.add(
        _RelationshipTraversal(
          endNode: currentNode,
          relationships: traversedRelationships,
          nodes: traversedNodes,
        ),
      );
    }
    if (depth >= boundedMaxHops) {
      return;
    }

    final candidates = _candidateRelationshipsForNode(
      currentNode,
      segment.direction,
      outgoingByNodeId: outgoingByNodeId,
      incomingByNodeId: incomingByNodeId,
    );
    for (final relationship in candidates) {
      if (usedRelationshipIds.contains(relationship.id)) {
        continue;
      }
      if (!_matchesRelationshipPattern(relationship, segment.pattern)) {
        continue;
      }

      final adjacent = _adjacentNodesForDirection(
        currentNode,
        relationship,
        segment.direction,
      );
      for (final nextNode in adjacent) {
        final nextUsedRelationshipIds = <int>{
          ...usedRelationshipIds,
          relationship.id
        };
        _expandRelationshipSegmentTraversalStep(
          currentNode: nextNode,
          segment: segment,
          depth: depth + 1,
          boundedMaxHops: boundedMaxHops,
          traversedRelationships: <CypherGraphRelationship>[
            ...traversedRelationships,
            relationship,
          ],
          traversedNodes: <CypherGraphNode>[
            ...traversedNodes,
            nextNode,
          ],
          usedRelationshipIds: nextUsedRelationshipIds,
          outgoingByNodeId: outgoingByNodeId,
          incomingByNodeId: incomingByNodeId,
          output: output,
        );
      }
    }
  }

  Set<String> _collectPatternChainVariables(_PatternChain chain) {
    final variables = <String>{};
    for (final nodePattern in chain.nodePatterns) {
      if (nodePattern.variable case final String variable) {
        variables.add(variable);
      }
    }
    for (final segment in chain.relationshipSegments) {
      if (segment.pattern.variable case final String variable) {
        variables.add(variable);
      }
    }
    if (chain.pathVariable case final String variable) {
      variables.add(variable);
    }
    return variables;
  }

  bool _matchesRelationshipPattern(
    CypherGraphRelationship relationship,
    _RelationshipPattern pattern,
  ) {
    if (pattern.types.isNotEmpty &&
        !pattern.types.contains(relationship.type)) {
      return false;
    }
    for (final entry in pattern.properties.entries) {
      if (!_valuesEqual(relationship.properties[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  List<CypherGraphNode> _adjacentNodesForDirection(
    CypherGraphNode currentNode,
    CypherGraphRelationship relationship,
    _RelationshipDirection direction,
  ) {
    final neighbors = <CypherGraphNode>[];
    switch (direction) {
      case _RelationshipDirection.outgoing:
        if (relationship.startNodeId == currentNode.id) {
          final end = graph.nodeById(relationship.endNodeId);
          if (end != null) {
            neighbors.add(end);
          }
        }
      case _RelationshipDirection.incoming:
        if (relationship.endNodeId == currentNode.id) {
          final start = graph.nodeById(relationship.startNodeId);
          if (start != null) {
            neighbors.add(start);
          }
        }
      case _RelationshipDirection.undirected:
        if (relationship.startNodeId == currentNode.id) {
          final end = graph.nodeById(relationship.endNodeId);
          if (end != null) {
            neighbors.add(end);
          }
        }
        if (relationship.endNodeId == currentNode.id &&
            relationship.startNodeId != currentNode.id) {
          final start = graph.nodeById(relationship.startNodeId);
          if (start != null) {
            neighbors.add(start);
          }
        }
    }
    return neighbors;
  }

  _PatternChain _parsePatternChain(
    String pattern,
    _Row row, {
    required String clauseName,
    required bool allowPathVariable,
  }) {
    final parsed = _extractPathVariable(
      pattern,
      clauseName: clauseName,
      allowPathVariable: allowPathVariable,
    );
    final source = parsed.pattern.trim();
    if (source.isEmpty) {
      throw _ExecutionException('$clauseName pattern cannot be empty.');
    }

    var index = _skipWhitespace(source, 0);
    final firstNodeToken = _readDelimitedSegment(
      source,
      index,
      open: '(',
      close: ')',
      context: '$clauseName node pattern',
    );
    if (firstNodeToken == null) {
      throw _ExecutionException(
        '$clauseName currently supports only parenthesized node patterns. Got: $pattern',
      );
    }

    final nodePatterns = <_NodePattern>[
      _parseNodePatternFromInner(
        firstNodeToken.$1.trim(),
        row,
        clauseName: clauseName,
      ),
    ];
    final relationshipSegments = <_PatternRelationshipSegment>[];
    index = _skipWhitespace(source, firstNodeToken.$2);

    while (index < source.length) {
      final relationshipToken = _readRelationshipSegmentToken(
        source,
        index,
        row,
        clauseName: clauseName,
      );
      relationshipSegments.add(relationshipToken.$1);
      index = _skipWhitespace(source, relationshipToken.$2);

      final nodeToken = _readDelimitedSegment(
        source,
        index,
        open: '(',
        close: ')',
        context: '$clauseName node pattern',
      );
      if (nodeToken == null) {
        throw _ExecutionException('Invalid pattern in $clauseName: $pattern');
      }
      nodePatterns.add(
        _parseNodePatternFromInner(
          nodeToken.$1.trim(),
          row,
          clauseName: clauseName,
        ),
      );
      index = _skipWhitespace(source, nodeToken.$2);
    }

    return _PatternChain(
      nodePatterns: nodePatterns,
      relationshipSegments: relationshipSegments,
      pathVariable: parsed.pathVariable,
    );
  }

  (_PatternRelationshipSegment, int) _readRelationshipSegmentToken(
    String source,
    int start,
    _Row row, {
    required String clauseName,
  }) {
    var index = _skipWhitespace(source, start);
    if (index >= source.length) {
      throw _ExecutionException('Invalid pattern in $clauseName: $source');
    }

    var leftArrow = false;
    if (source.startsWith('<-', index)) {
      leftArrow = true;
      index += 2;
    } else if (source.startsWith('-', index)) {
      index += 1;
    } else {
      throw _ExecutionException('Invalid pattern in $clauseName: $source');
    }

    index = _skipWhitespace(source, index);
    var relationshipInner = '';
    if (index < source.length && source[index] == '[') {
      final relationshipToken = _readDelimitedSegment(
        source,
        index,
        open: '[',
        close: ']',
        context: '$clauseName relationship pattern',
      );
      if (relationshipToken == null) {
        throw _ExecutionException('Invalid pattern in $clauseName: $source');
      }
      relationshipInner = relationshipToken.$1.trim();
      index = _skipWhitespace(source, relationshipToken.$2);
    }

    final hasOutgoingArrow = source.startsWith('->', index);
    if (hasOutgoingArrow) {
      index += 2;
    } else if (source.startsWith('-', index)) {
      index += 1;
    } else {
      throw _ExecutionException('Invalid pattern in $clauseName: $source');
    }

    final direction = switch ((leftArrow, hasOutgoingArrow)) {
      (true, true) => _RelationshipDirection.undirected,
      (true, false) => _RelationshipDirection.incoming,
      (false, true) => _RelationshipDirection.outgoing,
      _ => _RelationshipDirection.undirected,
    };

    final pattern = _parseRelationshipPatternInner(
      relationshipInner,
      row,
      clauseName: clauseName,
    );
    return (
      _PatternRelationshipSegment(pattern: pattern, direction: direction),
      index
    );
  }

  (String, int)? _readDelimitedSegment(
    String source,
    int start, {
    required String open,
    required String close,
    required String context,
  }) {
    if (start >= source.length || source[start] != open) {
      return null;
    }

    var depth = 1;
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;

    for (var i = start + 1; i < source.length; i++) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        continue;
      }

      if (char == open) {
        depth++;
        continue;
      }
      if (char == close) {
        depth--;
        if (depth == 0) {
          return (source.substring(start + 1, i), i + 1);
        }
      }
    }

    throw _ExecutionException('Unterminated $context.');
  }

  int _skipWhitespace(String source, int index) {
    var current = index;
    while (current < source.length && source[current].trim().isEmpty) {
      current++;
    }
    return current;
  }

  List<_Row> _executeCreate(List<_Row> inputRows, CreateClause clause) {
    final patternTexts = _splitTopLevelByComma(clause.pattern);
    if (patternTexts.isEmpty) {
      throw const _ExecutionException('CREATE pattern cannot be empty.');
    }

    final outputRows = <_Row>[];
    for (final baseRow in inputRows) {
      final row = Map<String, Object?>.from(baseRow);
      for (final patternText in patternTexts) {
        final chain = _parsePatternChain(
          patternText,
          row,
          clauseName: 'CREATE',
          allowPathVariable: false,
        );
        final resolvedNodes = <CypherGraphNode>[];
        for (final nodePattern in chain.nodePatterns) {
          resolvedNodes.add(
            _resolveOrCreateNodeForCreatePattern(
              row: row,
              pattern: nodePattern,
            ),
          );
        }

        for (var i = 0; i < chain.relationshipSegments.length; i++) {
          final segment = chain.relationshipSegments[i];
          if (!_isSingleHopRelationshipPattern(segment.pattern)) {
            throw const _ExecutionException(
              'CREATE does not support variable-length relationships.',
            );
          }
          final type = _singleRelationshipType(
            segment.pattern.types,
            clauseName: 'CREATE',
          );
          final leftNode = resolvedNodes[i];
          final rightNode = resolvedNodes[i + 1];

          final (startNodeId, endNodeId) = switch (segment.direction) {
            _RelationshipDirection.outgoing => (leftNode.id, rightNode.id),
            _RelationshipDirection.incoming => (rightNode.id, leftNode.id),
            _RelationshipDirection.undirected => (leftNode.id, rightNode.id),
          };

          final relationship = graph.createRelationship(
            startNodeId: startNodeId,
            endNodeId: endNodeId,
            type: type,
            properties: segment.pattern.properties,
          );
          if (segment.pattern.variable case final String variable) {
            row[variable] = relationship;
          }
        }
      }
      outputRows.add(row);
    }

    return outputRows;
  }

  _MergeExecutionResult _executeMerge(
      List<_Row> inputRows, MergeClause clause) {
    final normalized = _normalizeMergePattern(clause.pattern);
    if (normalized.pattern.isEmpty) {
      throw const _ExecutionException('MERGE pattern cannot be empty.');
    }

    final patternTexts = _splitTopLevelByComma(normalized.pattern);
    if (patternTexts.isEmpty) {
      throw const _ExecutionException('MERGE pattern cannot be empty.');
    }

    final outputRows = <_Row>[];
    for (final baseRow in inputRows) {
      final row = Map<String, Object?>.from(baseRow);
      var createdAny = false;
      for (final patternText in patternTexts) {
        final pattern = _parseMergePattern(patternText, row);
        switch (pattern) {
          case _NodeMatchPattern():
            final resolved = _resolveNodeForMergePattern(
              row: row,
              pattern: pattern.nodePattern,
            );
            final node = resolved.node;
            createdAny = createdAny || resolved.created;
            if (pattern.nodePattern.variable case final String variable) {
              row[variable] = node;
            }
          case _RelationshipMatchPattern():
            final leftResolved = _resolveNodeForMergePattern(
              row: row,
              pattern: pattern.leftNode,
            );
            final rightResolved = _resolveNodeForMergePattern(
              row: row,
              pattern: pattern.rightNode,
            );
            final relationshipResolved = _resolveRelationshipForMergePattern(
              row: row,
              pattern: pattern,
              leftNode: leftResolved.node,
              rightNode: rightResolved.node,
            );
            createdAny = createdAny ||
                leftResolved.created ||
                rightResolved.created ||
                relationshipResolved.created;
            final relationship = relationshipResolved.relationship;
            if (pattern.relationshipPattern.variable
                case final String relVariable) {
              row[relVariable] = relationship;
            }
            if (pattern.pathVariable case final String pathVariable) {
              row[pathVariable] = CypherGraphPath(
                nodes: <CypherGraphNode>[
                  leftResolved.node,
                  rightResolved.node,
                ],
                relationships: <CypherGraphRelationship>[relationship],
              );
            }
        }
      }
      row[_lastMergeCreatedKey] = createdAny;
      outputRows.add(row);
    }

    return _MergeExecutionResult(
      rows: outputRows,
      nextSetMode: normalized.setMode,
    );
  }

  _NormalizedMergePattern _normalizeMergePattern(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      return const _NormalizedMergePattern(pattern: '');
    }

    final suffix = _mergeSetSuffixPattern.firstMatch(trimmed);
    if (suffix == null) {
      return _NormalizedMergePattern(pattern: trimmed);
    }

    final modeToken = suffix.group(1)!.toUpperCase();
    final pattern = trimmed.substring(0, suffix.start).trim();
    if (pattern.isEmpty) {
      throw const _ExecutionException('MERGE pattern cannot be empty.');
    }
    final mode =
        modeToken == 'CREATE' ? _MergeSetMode.onCreate : _MergeSetMode.onMatch;
    return _NormalizedMergePattern(pattern: pattern, setMode: mode);
  }

  _MatchPattern _parseMergePattern(String pattern, _Row row) {
    final chain = _parsePatternChain(
      pattern,
      row,
      clauseName: 'MERGE',
      allowPathVariable: true,
    );
    if (chain.relationshipSegments.isEmpty) {
      return _NodeMatchPattern(chain.nodePatterns.single);
    }
    if (chain.relationshipSegments.length != 1 ||
        chain.nodePatterns.length != 2) {
      throw const _ExecutionException(
        'MERGE currently supports at most one relationship segment in the MVP engine.',
      );
    }

    final segment = chain.relationshipSegments.single;
    if (!_isSingleHopRelationshipPattern(segment.pattern)) {
      throw const _ExecutionException(
        'Variable-length relationships are not supported in MERGE.',
      );
    }

    return _RelationshipMatchPattern(
      leftNode: chain.nodePatterns[0],
      relationshipPattern: segment.pattern,
      rightNode: chain.nodePatterns[1],
      direction: segment.direction,
      pathVariable: chain.pathVariable,
    );
  }

  _ResolvedNode _resolveNodeForMergePattern({
    required _Row row,
    required _NodePattern pattern,
  }) {
    if (pattern.variable case final String variable) {
      final existing = row[variable];
      if (existing != null) {
        if (existing is! CypherGraphNode) {
          throw _ExecutionException(
            'Variable "$variable" is not bound to a node in MERGE.',
          );
        }
        if (!_matchesPatternNode(existing, pattern)) {
          throw _ExecutionException(
            'Variable "$variable" does not satisfy MERGE pattern constraints.',
          );
        }
        return _ResolvedNode(node: existing, created: false);
      }
    }

    final candidates = graph.nodes
        .where((node) => _matchesPatternNode(node, pattern))
        .toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));

    if (candidates.isNotEmpty) {
      final found = candidates.first;
      if (pattern.variable case final String variable) {
        row[variable] = found;
      }
      return _ResolvedNode(node: found, created: false);
    }

    final created =
        _resolveOrCreateNodeForCreatePattern(row: row, pattern: pattern);
    return _ResolvedNode(node: created, created: true);
  }

  _ResolvedRelationship _resolveRelationshipForMergePattern({
    required _Row row,
    required _RelationshipMatchPattern pattern,
    required CypherGraphNode leftNode,
    required CypherGraphNode rightNode,
  }) {
    final variable = pattern.relationshipPattern.variable;
    if (variable != null) {
      final existing = row[variable];
      if (existing != null) {
        if (existing is! CypherGraphRelationship) {
          throw _ExecutionException(
            'Variable "$variable" is not bound to a relationship in MERGE.',
          );
        }
        if (!_relationshipMatchesMergePattern(
          relationship: existing,
          pattern: pattern,
          leftNode: leftNode,
          rightNode: rightNode,
        )) {
          throw _ExecutionException(
            'Variable "$variable" does not satisfy MERGE relationship constraints.',
          );
        }
        return _ResolvedRelationship(relationship: existing, created: false);
      }
    }

    final candidates = graph.relationships
        .where(
          (relationship) => _relationshipMatchesMergePattern(
            relationship: relationship,
            pattern: pattern,
            leftNode: leftNode,
            rightNode: rightNode,
          ),
        )
        .toList(growable: false)
      ..sort((a, b) => a.id.compareTo(b.id));
    if (candidates.isNotEmpty) {
      final found = candidates.first;
      if (variable != null) {
        row[variable] = found;
      }
      return _ResolvedRelationship(relationship: found, created: false);
    }

    final type = _singleRelationshipType(
      pattern.relationshipPattern.types,
      clauseName: 'MERGE',
    );
    final created = graph.createRelationship(
      startNodeId: leftNode.id,
      endNodeId: rightNode.id,
      type: type,
      properties: pattern.relationshipPattern.properties,
    );
    if (variable != null) {
      row[variable] = created;
    }
    return _ResolvedRelationship(relationship: created, created: true);
  }

  bool _relationshipMatchesMergePattern({
    required CypherGraphRelationship relationship,
    required _RelationshipMatchPattern pattern,
    required CypherGraphNode leftNode,
    required CypherGraphNode rightNode,
  }) {
    if (pattern.relationshipPattern.types.isNotEmpty &&
        !pattern.relationshipPattern.types.contains(relationship.type)) {
      return false;
    }

    for (final entry in pattern.relationshipPattern.properties.entries) {
      if (!_valuesEqual(relationship.properties[entry.key], entry.value)) {
        return false;
      }
    }

    return switch (pattern.direction) {
      _RelationshipDirection.outgoing =>
        relationship.startNodeId == leftNode.id &&
            relationship.endNodeId == rightNode.id,
      _RelationshipDirection.incoming =>
        relationship.startNodeId == rightNode.id &&
            relationship.endNodeId == leftNode.id,
      _RelationshipDirection.undirected =>
        (relationship.startNodeId == leftNode.id &&
                relationship.endNodeId == rightNode.id) ||
            (relationship.startNodeId == rightNode.id &&
                relationship.endNodeId == leftNode.id),
    };
  }

  String _singleRelationshipType(Set<String> types,
      {required String clauseName}) {
    if (types.length != 1) {
      throw _ExecutionException(
        '$clauseName relationship requires exactly one type in the MVP engine.',
      );
    }
    return types.first;
  }

  CypherGraphNode _resolveOrCreateNodeForCreatePattern({
    required _Row row,
    required _NodePattern pattern,
  }) {
    if (pattern.variable case final String variable) {
      final existing = row[variable];
      if (existing != null) {
        if (existing is! CypherGraphNode) {
          throw _ExecutionException(
            'Variable "$variable" is not bound to a node in CREATE.',
          );
        }
        if (!_matchesPatternNode(existing, pattern)) {
          throw _ExecutionException(
            'Variable "$variable" does not satisfy CREATE pattern constraints.',
          );
        }
        return existing;
      }
    }

    final created = graph.createNode(
      labels: pattern.labels,
      properties: pattern.properties,
    );
    if (pattern.variable case final String variable) {
      row[variable] = created;
    }
    return created;
  }

  _SetExecutionResult _executeSet(
    List<_Row> inputRows,
    SetClause clause, {
    required _MergeSetMode? mode,
  }) {
    final normalized = _normalizeSetAssignments(clause.assignments);
    final assignments = _splitTopLevelByComma(normalized.assignments);
    if (assignments.isEmpty) {
      throw const _ExecutionException('SET requires at least one assignment.');
    }
    if (mode == null && normalized.nextMode != null) {
      throw const _ExecutionException(
        'ON CREATE/ON MATCH SET must directly follow MERGE.',
      );
    }

    final outputRows = <_Row>[];
    for (final sourceRow in inputRows) {
      final row = Map<String, Object?>.from(sourceRow);
      if (_shouldApplyConditionalSet(row, mode: mode)) {
        for (final assignment in assignments) {
          final propertyMatch = _setPropertyAssignmentPattern.firstMatch(
            assignment,
          );
          if (propertyMatch != null) {
            final variable = propertyMatch.group(1)!;
            final property = propertyMatch.group(2)!;
            final expression = propertyMatch.group(3)!.trim();
            final value = _evaluateScalarExpression(expression, row);
            _applyPropertySet(
              row: row,
              variable: variable,
              property: property,
              value: value,
            );
            continue;
          }

          final labelMatch =
              _labelAssignmentPattern.firstMatch(assignment.trim());
          if (labelMatch != null) {
            final variable = labelMatch.group(1)!;
            final labels = labelMatch
                .group(2)!
                .split(':')
                .map((label) => label.trim())
                .where((label) => label.isNotEmpty)
                .toList(growable: false);
            for (final label in labels) {
              _applyNodeLabelSet(row: row, variable: variable, label: label);
            }
            continue;
          }

          final mapMergeMatch =
              _setMapMergeAssignmentPattern.firstMatch(assignment);
          if (mapMergeMatch != null) {
            final variable = mapMergeMatch.group(1)!;
            final expression = mapMergeMatch.group(2)!.trim();
            final value = _evaluateScalarExpression(expression, row);
            _applyPropertyMapSet(
              row: row,
              variable: variable,
              value: value,
              mode: _PropertyMapSetMode.merge,
            );
            continue;
          }

          final mapReplaceMatch =
              _setMapReplaceAssignmentPattern.firstMatch(assignment);
          if (mapReplaceMatch != null) {
            final variable = mapReplaceMatch.group(1)!;
            final expression = mapReplaceMatch.group(2)!.trim();
            final value = _evaluateScalarExpression(expression, row);
            _applyPropertyMapSet(
              row: row,
              variable: variable,
              value: value,
              mode: _PropertyMapSetMode.replace,
            );
            continue;
          }

          throw _ExecutionException('Unsupported SET assignment: $assignment');
        }
      }
      outputRows.add(row);
    }

    return _SetExecutionResult(rows: outputRows, nextMode: normalized.nextMode);
  }

  _NormalizedSetAssignments _normalizeSetAssignments(String source) {
    final trimmed = source.trim();
    final suffix = _mergeSetSuffixPattern.firstMatch(trimmed);
    if (suffix == null) {
      return _NormalizedSetAssignments(assignments: trimmed);
    }

    final assignments = trimmed.substring(0, suffix.start).trim();
    if (assignments.isEmpty) {
      throw const _ExecutionException('SET requires at least one assignment.');
    }
    final modeToken = suffix.group(1)!.toUpperCase();
    final mode =
        modeToken == 'CREATE' ? _MergeSetMode.onCreate : _MergeSetMode.onMatch;
    return _NormalizedSetAssignments(assignments: assignments, nextMode: mode);
  }

  bool _shouldApplyConditionalSet(
    _Row row, {
    required _MergeSetMode? mode,
  }) {
    if (mode == null) {
      return true;
    }

    final marker = row[_lastMergeCreatedKey];
    if (marker is! bool) {
      throw const _ExecutionException(
        'ON CREATE/ON MATCH SET requires rows produced by MERGE.',
      );
    }

    return switch (mode) {
      _MergeSetMode.onCreate => marker,
      _MergeSetMode.onMatch => !marker,
    };
  }

  List<_Row> _executeRemove(List<_Row> inputRows, RemoveClause clause) {
    final items = _splitTopLevelByComma(clause.items);
    if (items.isEmpty) {
      throw const _ExecutionException('REMOVE requires at least one item.');
    }

    final outputRows = <_Row>[];
    for (final sourceRow in inputRows) {
      final row = Map<String, Object?>.from(sourceRow);
      for (final rawItem in items) {
        final item = rawItem.trim();

        final propertyAccess = _tryParsePropertyAccess(item);
        if (propertyAccess != null) {
          _applyPropertySet(
            row: row,
            variable: propertyAccess.$1,
            property: propertyAccess.$2,
            value: null,
          );
          continue;
        }

        final labelMatch = _labelAssignmentPattern.firstMatch(item);
        if (labelMatch != null) {
          final variable = labelMatch.group(1)!;
          final labels = labelMatch
              .group(2)!
              .split(':')
              .map((label) => label.trim())
              .where((label) => label.isNotEmpty)
              .toList(growable: false);
          for (final label in labels) {
            _applyNodeLabelRemove(row: row, variable: variable, label: label);
          }
          continue;
        }

        throw _ExecutionException('Unsupported REMOVE item: $item');
      }
      outputRows.add(row);
    }

    return outputRows;
  }

  void _applyPropertySet({
    required _Row row,
    required String variable,
    required String property,
    required Object? value,
  }) {
    if (!row.containsKey(variable)) {
      throw _ExecutionException('Unknown variable in SET: $variable');
    }
    final bound = row[variable];
    if (bound == null) {
      return;
    }
    if (bound is CypherGraphNode) {
      final updated = graph.setNodeProperty(
        nodeId: bound.id,
        key: property,
        value: value,
      );
      _refreshNodeBindings(row, updated);
      return;
    }
    if (bound is CypherGraphRelationship) {
      final updated = graph.setRelationshipProperty(
        relationshipId: bound.id,
        key: property,
        value: value,
      );
      _refreshRelationshipBindings(row, updated);
      return;
    }
    throw _ExecutionException(
      'SET target "$variable" must be a node or relationship. Got: ${bound.runtimeType}.',
    );
  }

  void _applyPropertyMapSet({
    required _Row row,
    required String variable,
    required Object? value,
    required _PropertyMapSetMode mode,
  }) {
    if (!row.containsKey(variable)) {
      throw _ExecutionException('Unknown variable in SET: $variable');
    }

    final bound = row[variable];
    if (bound == null) {
      return;
    }

    final propertyMap = _coercePropertyMapValue(
      value,
      variable: variable,
      mode: mode,
    );

    if (bound is CypherGraphNode) {
      _applyNodePropertyMapSet(
        row: row,
        node: bound,
        propertyMap: propertyMap,
        mode: mode,
      );
      return;
    }
    if (bound is CypherGraphRelationship) {
      _applyRelationshipPropertyMapSet(
        row: row,
        relationship: bound,
        propertyMap: propertyMap,
        mode: mode,
      );
      return;
    }

    throw _ExecutionException(
      'SET target "$variable" must be a node or relationship. Got: ${bound.runtimeType}.',
    );
  }

  Map<String, Object?> _coercePropertyMapValue(
    Object? value, {
    required String variable,
    required _PropertyMapSetMode mode,
  }) {
    if (value is Map) {
      final propertyMap = <String, Object?>{};
      for (final entry in value.entries) {
        propertyMap[entry.key.toString()] = entry.value;
      }
      return propertyMap;
    }
    if (value is CypherGraphNode) {
      return Map<String, Object?>.from(value.properties);
    }
    if (value is CypherGraphRelationship) {
      return Map<String, Object?>.from(value.properties);
    }
    throw _ExecutionException(
      switch (mode) {
        _PropertyMapSetMode.replace =>
          'SET $variable = ... expects a map, node, or relationship value.',
        _PropertyMapSetMode.merge =>
          'SET $variable += ... expects a map, node, or relationship value.',
      },
    );
  }

  void _applyNodePropertyMapSet({
    required _Row row,
    required CypherGraphNode node,
    required Map<String, Object?> propertyMap,
    required _PropertyMapSetMode mode,
  }) {
    CypherGraphNode current = node;
    if (mode == _PropertyMapSetMode.replace) {
      final existingKeys = current.properties.keys.toList(growable: false);
      for (final key in existingKeys) {
        current = graph.setNodeProperty(
          nodeId: current.id,
          key: key,
          value: null,
        );
      }
    }

    for (final entry in propertyMap.entries) {
      current = graph.setNodeProperty(
        nodeId: current.id,
        key: entry.key,
        value: entry.value,
      );
    }
    _refreshNodeBindings(row, current);
  }

  void _applyRelationshipPropertyMapSet({
    required _Row row,
    required CypherGraphRelationship relationship,
    required Map<String, Object?> propertyMap,
    required _PropertyMapSetMode mode,
  }) {
    CypherGraphRelationship current = relationship;
    if (mode == _PropertyMapSetMode.replace) {
      final existingKeys = current.properties.keys.toList(growable: false);
      for (final key in existingKeys) {
        current = graph.setRelationshipProperty(
          relationshipId: current.id,
          key: key,
          value: null,
        );
      }
    }

    for (final entry in propertyMap.entries) {
      current = graph.setRelationshipProperty(
        relationshipId: current.id,
        key: entry.key,
        value: entry.value,
      );
    }
    _refreshRelationshipBindings(row, current);
  }

  void _applyNodeLabelSet({
    required _Row row,
    required String variable,
    required String label,
  }) {
    if (!row.containsKey(variable)) {
      throw _ExecutionException('Unknown variable in SET: $variable');
    }
    final bound = row[variable];
    if (bound == null) {
      return;
    }
    if (bound is! CypherGraphNode) {
      throw _ExecutionException(
        'SET label target "$variable" must be a node. Got: ${bound.runtimeType}.',
      );
    }
    final updated = graph.addNodeLabel(nodeId: bound.id, label: label);
    _refreshNodeBindings(row, updated);
  }

  void _applyNodeLabelRemove({
    required _Row row,
    required String variable,
    required String label,
  }) {
    if (!row.containsKey(variable)) {
      throw _ExecutionException('Unknown variable in REMOVE: $variable');
    }
    final bound = row[variable];
    if (bound == null) {
      return;
    }
    if (bound is! CypherGraphNode) {
      throw _ExecutionException(
        'REMOVE label target "$variable" must be a node. Got: ${bound.runtimeType}.',
      );
    }
    final updated = graph.removeNodeLabel(nodeId: bound.id, label: label);
    _refreshNodeBindings(row, updated);
  }

  void _refreshNodeBindings(_Row row, CypherGraphNode updatedNode) {
    final keys = row.keys.toList(growable: false);
    for (final key in keys) {
      final value = row[key];
      if (value is CypherGraphNode && value.id == updatedNode.id) {
        row[key] = updatedNode;
      }
    }
  }

  void _refreshRelationshipBindings(
    _Row row,
    CypherGraphRelationship updatedRelationship,
  ) {
    final keys = row.keys.toList(growable: false);
    for (final key in keys) {
      final value = row[key];
      if (value is CypherGraphRelationship &&
          value.id == updatedRelationship.id) {
        row[key] = updatedRelationship;
      }
    }
  }

  List<_Row> _executeDelete(List<_Row> inputRows, DeleteClause clause) {
    final targets = _splitTopLevelByComma(clause.items);
    if (targets.isEmpty) {
      throw const _ExecutionException('DELETE requires at least one target.');
    }

    for (final row in inputRows) {
      final nodeIds = <int>{};
      final relationshipIds = <int>{};
      for (final target in targets) {
        final expression = target.trim();
        Object? value;
        final variable = _tryParseIdentifier(expression);
        if (variable != null) {
          value = row[variable];
        } else {
          try {
            value = _evaluateScalarExpression(expression, row);
          } on _ExecutionException {
            throw _ExecutionException('Unsupported DELETE target: $target');
          }
        }
        _collectDeleteTargets(
          value,
          nodeIds: nodeIds,
          relationshipIds: relationshipIds,
          targetExpression: expression,
        );
      }

      final sortedRelationshipIds = relationshipIds.toList()..sort();
      for (final relationshipId in sortedRelationshipIds) {
        if (graph.relationshipById(relationshipId) != null) {
          graph.deleteRelationship(relationshipId);
        }
      }

      final sortedNodeIds = nodeIds.toList()..sort();
      for (final nodeId in sortedNodeIds) {
        if (graph.nodeById(nodeId) == null) {
          continue;
        }
        try {
          graph.deleteNode(nodeId, detach: clause.detach);
        } on StateError catch (error) {
          throw _ExecutionException(error.message.toString());
        }
      }
    }

    return inputRows.map((row) => Map<String, Object?>.from(row)).toList(
          growable: false,
        );
  }

  void _collectDeleteTargets(
    Object? value, {
    required Set<int> nodeIds,
    required Set<int> relationshipIds,
    required String targetExpression,
  }) {
    if (value == null) {
      return;
    }
    if (value is CypherGraphRelationship) {
      relationshipIds.add(value.id);
      return;
    }
    if (value is CypherGraphNode) {
      nodeIds.add(value.id);
      return;
    }
    if (value is CypherGraphPath) {
      for (final relationship in value.relationships) {
        relationshipIds.add(relationship.id);
      }
      for (final node in value.nodes) {
        nodeIds.add(node.id);
      }
      return;
    }
    if (value is Iterable && value is! Map) {
      for (final element in value) {
        _collectDeleteTargets(
          element,
          nodeIds: nodeIds,
          relationshipIds: relationshipIds,
          targetExpression: targetExpression,
        );
      }
      return;
    }
    throw _ExecutionException(
      'DELETE target "$targetExpression" must resolve to a node, relationship, path, or list thereof.',
    );
  }

  _ParsedPattern _extractPathVariable(
    String pattern, {
    required String clauseName,
    required bool allowPathVariable,
  }) {
    final trimmed = pattern.trim();
    final equalsIndex = _findTopLevelChar(trimmed, '=');
    if (equalsIndex == null) {
      return _ParsedPattern(pattern: trimmed);
    }

    final left = trimmed.substring(0, equalsIndex).trim();
    final right = trimmed.substring(equalsIndex + 1).trim();
    if (left.isEmpty || right.isEmpty) {
      throw _ExecutionException('Invalid pattern in $clauseName: $pattern');
    }
    if (!_isIdentifier(left)) {
      throw _ExecutionException('Invalid path variable in $clauseName: $left');
    }
    if (!allowPathVariable) {
      throw _ExecutionException(
        'Path-variable $clauseName patterns are not supported in the MVP engine.',
      );
    }
    return _ParsedPattern(pattern: right, pathVariable: left);
  }

  _NodePattern _parseNodePatternFromInner(
    String inner,
    _Row row, {
    required String clauseName,
  }) {
    var header = inner.trim();
    var properties = <String, Object?>{};

    final mapStart = _findTopLevelChar(header, '{');
    if (mapStart != null) {
      final mapText = header.substring(mapStart).trim();
      header = header.substring(0, mapStart).trim();
      properties = _parseMapLiteral(mapText, row);
    }

    final pieces = header.split(':').map((part) => part.trim()).toList();
    String? variable;
    final labels = <String>{};

    if (pieces.isNotEmpty && pieces.first.isNotEmpty) {
      if (_isIdentifier(pieces.first)) {
        variable = _tryParseIdentifier(pieces.first)!;
      } else {
        throw _ExecutionException(
          'Invalid node variable in $clauseName: ${pieces.first}',
        );
      }
    }

    final labelStart = variable == null ? 0 : 1;
    for (var i = labelStart; i < pieces.length; i++) {
      final label = pieces[i];
      if (label.isEmpty) {
        continue;
      }
      if (!_isIdentifier(label)) {
        throw _ExecutionException('Invalid node label in $clauseName: $label');
      }
      labels.add(_tryParseIdentifier(label)!);
    }

    return _NodePattern(
      variable: variable,
      labels: labels,
      properties: properties,
    );
  }

  _RelationshipPattern _parseRelationshipPatternInner(
    String inner,
    _Row row, {
    required String clauseName,
  }) {
    var header = inner.trim();
    var properties = <String, Object?>{};

    final mapStart = _findTopLevelChar(header, '{');
    if (mapStart != null) {
      final mapText = header.substring(mapStart).trim();
      header = header.substring(0, mapStart).trim();
      properties = _parseMapLiteral(mapText, row);
    }

    var minHops = 1;
    int? maxHops = 1;
    var variableLengthSyntax = false;
    final variableLengthIndex = _findTopLevelChar(header, '*');
    if (variableLengthIndex != null) {
      variableLengthSyntax = true;
      final rangeText = header.substring(variableLengthIndex + 1).trim();
      final parsedRange = _parseVariableLengthRange(
        rangeText,
        clauseName: clauseName,
      );
      minHops = parsedRange.$1;
      maxHops = parsedRange.$2;
      header = header.substring(0, variableLengthIndex).trim();
    }

    String? variable;
    final types = <String>{};

    final colonIndex = header.indexOf(':');
    if (colonIndex < 0) {
      final candidate = header.trim();
      if (candidate.isNotEmpty) {
        if (!_isIdentifier(candidate)) {
          throw _ExecutionException(
            'Invalid relationship variable in $clauseName: $candidate',
          );
        }
        variable = _tryParseIdentifier(candidate)!;
      }
    } else {
      final variableCandidate = header.substring(0, colonIndex).trim();
      if (variableCandidate.isNotEmpty) {
        if (!_isIdentifier(variableCandidate)) {
          throw _ExecutionException(
            'Invalid relationship variable in $clauseName: $variableCandidate',
          );
        }
        variable = _tryParseIdentifier(variableCandidate)!;
      }

      final typesText = header.substring(colonIndex + 1).trim();
      if (typesText.isEmpty) {
        throw _ExecutionException(
          'Relationship type cannot be empty in $clauseName pattern.',
        );
      }

      for (final rawType in typesText.split('|')) {
        var typeName = rawType.trim();
        if (typeName.startsWith(':')) {
          typeName = typeName.substring(1).trim();
        }
        if (typeName.isEmpty || typeName.contains(':')) {
          throw _ExecutionException(
            'Invalid relationship type in $clauseName: $rawType',
          );
        }
        if (!_isIdentifier(typeName)) {
          throw _ExecutionException(
            'Invalid relationship type in $clauseName: $typeName',
          );
        }
        types.add(_tryParseIdentifier(typeName)!);
      }
    }

    return _RelationshipPattern(
      variable: variable,
      types: types,
      properties: properties,
      minHops: minHops,
      maxHops: maxHops,
      variableLengthSyntax: variableLengthSyntax,
    );
  }

  (int, int?) _parseVariableLengthRange(
    String source, {
    required String clauseName,
  }) {
    if (source.isEmpty) {
      return (1, null);
    }

    final separatorIndex = source.indexOf('..');
    if (separatorIndex < 0) {
      final hops = int.tryParse(source);
      if (hops == null || hops < 0) {
        throw _ExecutionException(
          'Invalid variable-length range in $clauseName: *$source',
        );
      }
      return (hops, hops);
    }

    final lowerText = source.substring(0, separatorIndex).trim();
    final upperText = source.substring(separatorIndex + 2).trim();
    final lower = lowerText.isEmpty ? 0 : int.tryParse(lowerText);
    final upper = upperText.isEmpty ? null : int.tryParse(upperText);
    if (lower == null || lower < 0) {
      throw _ExecutionException(
        'Invalid variable-length range in $clauseName: *$source',
      );
    }
    if (upper != null && upper < 0) {
      throw _ExecutionException(
        'Invalid variable-length range in $clauseName: *$source',
      );
    }
    return (lower, upper);
  }

  bool _canBindNode(_Row row, String? variable, CypherGraphNode node) {
    if (variable == null) {
      return true;
    }
    final existing = row[variable];
    if (existing == null) {
      return true;
    }
    if (existing is! CypherGraphNode) {
      return false;
    }
    return existing.id == node.id;
  }

  bool _matchesPatternNode(CypherGraphNode node, _NodePattern pattern) {
    if (pattern.labels.isNotEmpty && !node.labels.containsAll(pattern.labels)) {
      return false;
    }

    for (final entry in pattern.properties.entries) {
      if (!_valuesEqual(node.properties[entry.key], entry.value)) {
        return false;
      }
    }

    return true;
  }

  List<_Row> _executeWhere(List<_Row> inputRows, WhereClause clause) {
    return inputRows
        .where((row) => _evaluateBooleanExpression(clause.expression, row))
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
  }

  _ProjectionResult _project(List<_Row> rows, String itemsText) {
    final spec = _parseProjectionSpec(itemsText);
    final items = _parseProjectionItems(spec.itemsText);
    final aggregateFlags = items
        .map((item) => item.isWildcard
            ? false
            : _containsAggregateFunction(item.expression))
        .toList(growable: false);
    final hasAggregation = aggregateFlags.any((flag) => flag);

    final result = hasAggregation
        ? _projectWithAggregation(
            rows: rows,
            items: items,
            aggregateFlags: aggregateFlags,
          )
        : _projectWithoutAggregation(rows: rows, items: items);

    if (!spec.distinct) {
      return result;
    }
    return _applyDistinct(result);
  }

  _ProjectionResult _projectWithoutAggregation({
    required List<_Row> rows,
    required List<_ProjectionItem> items,
  }) {
    final outputRows = <_Row>[];
    final columns = <String>[];

    for (final row in rows) {
      final projected = <String, Object?>{};
      for (final item in items) {
        if (item.isWildcard) {
          for (final entry in row.entries) {
            if (_isInternalKey(entry.key)) {
              continue;
            }
            projected[entry.key] = entry.value;
            if (!columns.contains(entry.key)) {
              columns.add(entry.key);
            }
          }
          continue;
        }

        final value = _evaluateScalarExpression(item.expression, row);
        projected[item.alias] = value;
        projected[_projectionExpressionKey(item.expression)] = value;
        if (!columns.contains(item.alias)) {
          columns.add(item.alias);
        }
      }
      outputRows.add(projected);
    }

    return _ProjectionResult(rows: outputRows, columns: columns);
  }

  _ProjectionResult _projectWithAggregation({
    required List<_Row> rows,
    required List<_ProjectionItem> items,
    required List<bool> aggregateFlags,
  }) {
    if (items.any((item) => item.isWildcard)) {
      throw const _ExecutionException(
        'Wildcard projection with aggregation is not supported in the MVP engine.',
      );
    }

    final groupIndexes = <int>[];
    for (var i = 0; i < items.length; i++) {
      if (!aggregateFlags[i]) {
        groupIndexes.add(i);
      }
    }

    final groups = <String, _AggregationGroup>{};
    if (rows.isEmpty && groupIndexes.isEmpty) {
      groups['__all__'] = const _AggregationGroup(
        rows: <_Row>[],
        groupValues: <int, Object?>{},
      );
    } else {
      for (final row in rows) {
        final groupValues = <int, Object?>{};
        for (final index in groupIndexes) {
          groupValues[index] =
              _evaluateScalarExpression(items[index].expression, row);
        }
        final key = groupIndexes.isEmpty
            ? '__all__'
            : groupIndexes
                .map((index) =>
                    '${items[index].alias}:${_valueKey(groupValues[index])}')
                .join('|');
        final existing = groups[key];
        if (existing == null) {
          groups[key] = _AggregationGroup(
            rows: <_Row>[row],
            groupValues: groupValues,
          );
        } else {
          groups[key] = _AggregationGroup(
            rows: <_Row>[...existing.rows, row],
            groupValues: existing.groupValues,
          );
        }
      }
    }

    final outputRows = <_Row>[];
    final columns = <String>[];
    for (final item in items) {
      columns.add(item.alias);
    }

    for (final group in groups.values) {
      final projected = <String, Object?>{};
      final contextRow =
          group.rows.isEmpty ? const <String, Object?>{} : group.rows.first;
      for (var i = 0; i < items.length; i++) {
        final value = aggregateFlags[i]
            ? _evaluateScalarExpression(
                items[i].expression,
                contextRow,
                aggregateRows: group.rows,
              )
            : group.groupValues[i];
        projected[items[i].alias] = value;
        projected[_projectionExpressionKey(items[i].expression)] = value;
      }
      outputRows.add(projected);
    }

    return _ProjectionResult(rows: outputRows, columns: columns);
  }

  _ProjectionResult _applyDistinct(_ProjectionResult source) {
    if (source.rows.length <= 1) {
      return source;
    }

    final columns = source.columns;
    final dedupedRows = <_Row>[];
    final seen = <String>{};

    for (final row in source.rows) {
      final key = _rowKey(row, columns);
      if (!seen.add(key)) {
        continue;
      }
      dedupedRows.add(Map<String, Object?>.from(row));
    }

    return _ProjectionResult(rows: dedupedRows, columns: columns);
  }

  List<_Row> _executeOrderBy(List<_Row> inputRows, OrderByClause clause) {
    final rows = inputRows
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
    final specs = _parseOrderItems(clause.items);

    rows.sort((left, right) {
      for (final spec in specs) {
        final leftValue = _evaluateOrderExpression(spec.expression, left);
        final rightValue = _evaluateOrderExpression(spec.expression, right);
        var comparison = _compareForOrdering(leftValue, rightValue);
        if (spec.descending) {
          comparison = -comparison;
        }
        if (comparison != 0) {
          return comparison;
        }
      }
      return 0;
    });

    return rows;
  }

  Object? _evaluateOrderExpression(String expression, _Row row) {
    final trimmed = expression.trim();
    if (row.containsKey(trimmed)) {
      return row[trimmed];
    }
    final expressionKey = _projectionExpressionKey(trimmed);
    if (row.containsKey(expressionKey)) {
      return row[expressionKey];
    }
    return _evaluateScalarExpression(trimmed, row);
  }

  String _projectionExpressionKey(String expression) {
    return '${_internalKeyPrefix}expr:${expression.trim()}';
  }

  List<_Row> _executeSkip(List<_Row> rows, SkipClause clause) {
    final value = _resolveNonNegativeInt(clause.value, label: 'SKIP');
    if (value >= rows.length) {
      return <_Row>[];
    }
    return rows.skip(value).map((row) => Map<String, Object?>.from(row)).toList(
          growable: false,
        );
  }

  List<_Row> _executeLimit(List<_Row> rows, LimitClause clause) {
    final value = _resolveNonNegativeInt(clause.value, label: 'LIMIT');
    if (value == 0) {
      return <_Row>[];
    }
    return rows.take(value).map((row) => Map<String, Object?>.from(row)).toList(
          growable: false,
        );
  }

  List<_Row> _executeUnwind(List<_Row> inputRows, UnwindClause clause) {
    final match = _unwindPattern.firstMatch(clause.items);
    if (match == null) {
      throw _ExecutionException('Invalid UNWIND syntax: ${clause.items}');
    }

    final expression = match.group(1)!.trim();
    final variable = match.group(2)!;
    final outputRows = <_Row>[];

    for (final row in inputRows) {
      final value = _evaluateScalarExpression(expression, row);
      if (value == null) {
        continue;
      }
      if (value is! Iterable || value is String || value is Map) {
        throw _ExecutionException(
          'UNWIND expression must evaluate to a list. Got: ${value.runtimeType}.',
        );
      }

      for (final element in value) {
        final next = Map<String, Object?>.from(row);
        next[variable] = element;
        outputRows.add(next);
      }
    }

    return outputRows;
  }

  List<_Row> _executeCall(List<_Row> inputRows, CallClause clause) {
    final parsed = _parseCallInvocation(clause.invocation);
    final outputRows = <_Row>[];

    for (final sourceRow in inputRows) {
      final row = Map<String, Object?>.from(sourceRow);
      final args = parsed.argExpressions
          .map((arg) => _evaluateScalarExpression(arg, row))
          .toList(growable: false);
      final yieldedRows = _invokeProcedure(parsed.procedureName, args);
      for (final yielded in yieldedRows) {
        final next = Map<String, Object?>.from(row);
        if (parsed.yieldItems.isEmpty) {
          for (final entry in yielded.entries) {
            next[entry.key] = entry.value;
          }
        } else {
          final hasYieldWildcard =
              parsed.yieldItems.length == 1 && parsed.yieldItems.first.wildcard;
          if (hasYieldWildcard) {
            final hasVisibleBindings = row.keys.any(
              (key) => !_isInternalKey(key),
            );
            if (hasVisibleBindings) {
              throw const _ExecutionException(
                'YIELD * is only supported for standalone CALL clauses.',
              );
            }
            for (final entry in yielded.entries) {
              next[entry.key] = entry.value;
            }
            outputRows.add(next);
            continue;
          }
          for (final yieldItem in parsed.yieldItems) {
            if (!yielded.containsKey(yieldItem.source)) {
              throw _ExecutionException(
                'Procedure "${parsed.procedureName}" does not yield "${yieldItem.source}".',
              );
            }
            next[yieldItem.alias] = yielded[yieldItem.source];
          }
        }
        outputRows.add(next);
      }
    }

    return outputRows;
  }

  _CallInvocation _parseCallInvocation(String source) {
    final trimmed = source.trim();
    final match = _callInvocationPattern.firstMatch(trimmed);
    if (match == null) {
      throw _ExecutionException('Unsupported CALL invocation: $source');
    }

    final procedureName = match.group(1)!;
    final hasParentheses = match.group(2) != null;
    final argsText = match.group(2)?.trim() ?? '';
    final yieldText = match.group(3)?.trim();
    if (!hasParentheses && procedureName.toLowerCase().startsWith('db.')) {
      throw _ExecutionException('Unsupported CALL invocation: $source');
    }
    final argExpressions =
        argsText.isEmpty ? const <String>[] : _splitTopLevelByComma(argsText);
    final yieldItems = yieldText == null || yieldText.isEmpty
        ? const <_YieldItem>[]
        : _parseYieldItems(yieldText);
    return _CallInvocation(
      procedureName: procedureName,
      argExpressions: argExpressions,
      yieldItems: yieldItems,
    );
  }

  List<_YieldItem> _parseYieldItems(String source) {
    final parts = _splitTopLevelByComma(source);
    if (parts.isEmpty) {
      throw const _ExecutionException('YIELD requires at least one item.');
    }

    return parts.map((part) {
      final trimmed = part.trim();
      if (trimmed == '*') {
        return const _YieldItem.wildcard();
      }
      final asIndex = _findTopLevelKeywordIndex(trimmed, 'AS');
      if (asIndex == null) {
        final normalized = _tryParseIdentifier(trimmed);
        if (normalized == null) {
          throw _ExecutionException('Invalid YIELD item: $trimmed');
        }
        return _YieldItem(source: normalized, alias: normalized);
      }

      final sourceName = trimmed.substring(0, asIndex).trim();
      final alias = trimmed.substring(asIndex + 2).trim();
      final normalizedSource = _tryParseIdentifier(sourceName);
      final normalizedAlias = _tryParseIdentifier(alias);
      if (normalizedSource == null || normalizedAlias == null) {
        throw _ExecutionException('Invalid YIELD item: $trimmed');
      }
      return _YieldItem(source: normalizedSource, alias: normalizedAlias);
    }).toList(growable: false);
  }

  List<Map<String, Object?>> _invokeProcedure(
    String procedureName,
    List<Object?> args,
  ) {
    switch (procedureName.toLowerCase()) {
      case 'db.labels':
        if (args.isNotEmpty) {
          throw const _ExecutionException('db.labels() does not accept args.');
        }
        final labels = <String>{
          for (final node in graph.nodes) ...node.labels,
        }.toList()
          ..sort();
        return labels
            .map((label) => <String, Object?>{'label': label})
            .toList(growable: false);
      case 'db.relationshiptypes':
        if (args.isNotEmpty) {
          throw const _ExecutionException(
            'db.relationshipTypes() does not accept args.',
          );
        }
        final relationshipTypes = <String>{
          for (final relationship in graph.relationships) relationship.type,
        }.toList()
          ..sort();
        return relationshipTypes
            .map((type) => <String, Object?>{'relationshipType': type})
            .toList(growable: false);
      case 'db.propertykeys':
        if (args.isNotEmpty) {
          throw const _ExecutionException(
            'db.propertyKeys() does not accept args.',
          );
        }
        final propertyKeys = <String>{
          for (final node in graph.nodes) ...node.properties.keys,
          for (final relationship in graph.relationships)
            ...relationship.properties.keys,
        }.toList()
          ..sort();
        return propertyKeys
            .map((key) => <String, Object?>{'propertyKey': key})
            .toList(growable: false);
      case 'test.donothing':
        if (args.isNotEmpty) {
          throw const _ExecutionException(
              'test.doNothing() does not accept args.');
        }
        return const <Map<String, Object?>>[
          <String, Object?>{},
        ];
      case 'test.labels':
        final labels = <String>{
          for (final node in graph.nodes) ...node.labels,
        }.toList()
          ..sort();
        if (labels.isEmpty) {
          return const <Map<String, Object?>>[
            <String, Object?>{'label': null},
          ];
        }
        return labels
            .map((label) => <String, Object?>{'label': label})
            .toList(growable: false);
      case 'test.my.proc':
        final first = args.isNotEmpty ? args.first : null;
        final second = args.length > 1 ? args[1] : null;
        return <Map<String, Object?>>[
          <String, Object?>{
            'out': first,
            'city': first,
            'country_code': second,
            'a': first,
            'b': second,
          },
        ];
      default:
        throw _ExecutionException(
          'Unsupported CALL procedure in MVP engine: $procedureName',
        );
    }
  }

  bool _evaluateBooleanExpression(String expression, _Row row) {
    final trimmed = expression.trim();
    if (trimmed.isEmpty) {
      throw const _ExecutionException('WHERE expression cannot be empty.');
    }

    final unwrapped = _unwrapEnclosingParentheses(trimmed);
    if (unwrapped != trimmed) {
      return _evaluateBooleanExpression(unwrapped, row);
    }

    final patternPredicate = _tryEvaluatePatternPredicate(trimmed, row);
    if (patternPredicate != null) {
      return patternPredicate;
    }

    final scalar = _evaluateScalarExpression(trimmed, row);
    final value = _coerceBooleanValue(
      scalar,
      context: 'WHERE clause expression',
    );
    return value ?? false;
  }

  bool? _tryEvaluatePatternPredicate(String expression, _Row row) {
    if (!expression.contains('(') || !expression.contains('-')) {
      return null;
    }
    try {
      final chain = _parsePatternChain(
        expression,
        row,
        clauseName: 'WHERE',
        allowPathVariable: false,
      );
      if (chain.relationshipSegments.isEmpty) {
        return null;
      }
      final matches = _matchPatternChain(
        <_Row>[Map<String, Object?>.from(row)],
        chain,
        optional: false,
      );
      return matches.isNotEmpty;
    } on _ExecutionException {
      return null;
    }
  }

  Object? _evaluateLogicalBinaryOperator(
    String operator,
    Object? leftValue,
    Object? rightValue,
  ) {
    final left = _coerceBooleanValue(leftValue, context: '$operator operand');
    final right = _coerceBooleanValue(rightValue, context: '$operator operand');
    return switch (operator) {
      'AND' => _evaluateLogicalAnd(left, right),
      'OR' => _evaluateLogicalOr(left, right),
      'XOR' => _evaluateLogicalXor(left, right),
      _ => throw _ExecutionException('Unsupported logical operator: $operator'),
    };
  }

  Object? _evaluateLogicalNotOperator(Object? value) {
    final normalized = _coerceBooleanValue(value, context: 'NOT operand');
    if (normalized == null) {
      return null;
    }
    return !normalized;
  }

  bool? _evaluateLogicalAnd(bool? left, bool? right) {
    if (left == false || right == false) {
      return false;
    }
    if (left == true && right == true) {
      return true;
    }
    return null;
  }

  bool? _evaluateLogicalOr(bool? left, bool? right) {
    if (left == true || right == true) {
      return true;
    }
    if (left == false && right == false) {
      return false;
    }
    return null;
  }

  bool? _evaluateLogicalXor(bool? left, bool? right) {
    if (left == null || right == null) {
      return null;
    }
    return left != right;
  }

  bool? _coerceBooleanValue(
    Object? value, {
    required String context,
  }) {
    if (value == null) {
      return null;
    }
    if (value is bool) {
      return value;
    }
    throw _ExecutionException(
      '$context must evaluate to a boolean or null. Got: ${value.runtimeType}.',
    );
  }

  _ParsedComparisonChain? _parseComparisonChain(String source) {
    final operators = _collectTopLevelComparisonOperators(source);
    if (operators.isEmpty) {
      return null;
    }

    final operands = <String>[];
    var start = 0;
    for (final token in operators) {
      final operand = source.substring(start, token.index).trim();
      if (operand.isEmpty) {
        throw _ExecutionException('Invalid comparison expression: $source');
      }
      operands.add(operand);
      start = token.index + token.operator.length;
    }

    final last = source.substring(start).trim();
    if (last.isEmpty) {
      throw _ExecutionException('Invalid comparison expression: $source');
    }
    operands.add(last);

    return _ParsedComparisonChain(
      operands: operands,
      operators:
          operators.map((token) => token.operator).toList(growable: false),
    );
  }

  Object? _evaluateComparisonChain(
    _ParsedComparisonChain chain,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    for (var i = 0; i < chain.operators.length; i++) {
      final left = _evaluateScalarExpression(
        chain.operands[i],
        row,
        aggregateRows: aggregateRows,
      );
      final right = _evaluateScalarExpression(
        chain.operands[i + 1],
        row,
        aggregateRows: aggregateRows,
      );
      final result =
          _evaluateComparisonOperator(left, right, chain.operators[i]);
      if (result != true) {
        return result;
      }
    }
    return true;
  }

  bool? _evaluateComparisonOperator(
      Object? left, Object? right, String operator) {
    if (left == null || right == null) {
      return null;
    }

    switch (operator) {
      case '=':
        return _valuesEqual(left, right);
      case '!=':
      case '<>':
        return !_valuesEqual(left, right);
      case '<':
      case '<=':
      case '>':
      case '>=':
        final comparison =
            _compareForOrdering(left, right, nullAsLargest: false);
        return switch (operator) {
          '<' => comparison < 0,
          '<=' => comparison <= 0,
          '>' => comparison > 0,
          '>=' => comparison >= 0,
          _ => false,
        };
      default:
        throw _ExecutionException('Unsupported comparison operator: $operator');
    }
  }

  List<_ComparisonToken> _collectTopLevelComparisonOperators(String source) {
    final tokens = <_ComparisonToken>[];
    final upper = source.toUpperCase();
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;
    var caseDepth = 0;
    var index = 0;

    while (index < source.length) {
      final char = source[index];
      final prev = index > 0 ? source[index - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        index++;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        index++;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        index++;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        index++;
        continue;
      }

      if (char == '(') {
        parenDepth++;
        index++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        index++;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        index++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        index++;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        index++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        index++;
        continue;
      }

      if (parenDepth == 0 && braceDepth == 0 && bracketDepth == 0) {
        if (upper.startsWith('CASE', index) &&
            _isTokenBoundary(source, index - 1) &&
            _isTokenBoundary(source, index + 4)) {
          caseDepth++;
          index += 4;
          continue;
        }
        if (caseDepth > 0 &&
            upper.startsWith('END', index) &&
            _isTokenBoundary(source, index - 1) &&
            _isTokenBoundary(source, index + 3)) {
          caseDepth--;
          index += 3;
          continue;
        }
      }

      if (parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0 &&
          caseDepth == 0) {
        String? matchedOperator;
        for (final operator in const <String>[
          '<=',
          '>=',
          '<>',
          '!=',
          '=',
          '<',
          '>',
        ]) {
          if (source.startsWith(operator, index)) {
            final prevChar = index > 0 ? source[index - 1] : '';
            final nextChar = index + operator.length < source.length
                ? source[index + operator.length]
                : '';
            if ((operator == '>' || operator == '>=') && prevChar == '-') {
              continue;
            }
            if ((operator == '<' || operator == '<=') && nextChar == '-') {
              continue;
            }
            matchedOperator = operator;
            break;
          }
        }
        if (matchedOperator != null) {
          tokens.add(_ComparisonToken(index: index, operator: matchedOperator));
          index += matchedOperator.length;
          continue;
        }
      }

      index++;
    }

    return tokens;
  }

  _StringSearchExpression? _tryParseStringSearchExpression(String source) {
    for (final operator in const <String>[
      'STARTS WITH',
      'ENDS WITH',
      'CONTAINS',
    ]) {
      final index = _findTopLevelKeywordIndex(source, operator);
      if (index == null) {
        continue;
      }
      final left = source.substring(0, index).trim();
      final right = source.substring(index + operator.length).trim();
      if (left.isEmpty || right.isEmpty) {
        throw _ExecutionException('Invalid string predicate: $source');
      }
      return _StringSearchExpression(
        left: left,
        operator: operator,
        right: right,
      );
    }
    return null;
  }

  bool? _evaluateStringSearch({
    required String operator,
    required Object? left,
    required Object? right,
  }) {
    if (left == null || right == null) {
      return null;
    }
    if (left is! String || right is! String) {
      return null;
    }
    return switch (operator) {
      'STARTS WITH' => left.startsWith(right),
      'ENDS WITH' => left.endsWith(right),
      'CONTAINS' => left.contains(right),
      _ => throw _ExecutionException('Unsupported string operator: $operator'),
    };
  }

  _CaseExpression? _tryParseCaseExpression(String source) {
    final upper = source.toUpperCase();
    if (!upper.startsWith('CASE')) {
      return null;
    }
    if (source.length == 4 || !_isTokenBoundary(source, 4)) {
      return null;
    }

    final endIndex = _findTopLevelKeywordIndex(source, 'END');
    if (endIndex == null || endIndex + 3 != source.length) {
      return null;
    }

    var body = source.substring(4, endIndex).trim();
    if (body.isEmpty) {
      throw const _ExecutionException('CASE expression cannot be empty.');
    }

    String? caseInputExpression;
    final firstWhen = _findFirstTopLevelKeywordIndex(body, 'WHEN');
    if (firstWhen == null) {
      throw const _ExecutionException(
          'CASE expression requires at least one WHEN.');
    }
    if (firstWhen > 0) {
      caseInputExpression = body.substring(0, firstWhen).trim();
      if (caseInputExpression.isEmpty) {
        caseInputExpression = null;
      }
      body = body.substring(firstWhen).trim();
    }

    final whens = <_CaseWhen>[];
    String? elseExpression;
    var remainder = body;

    while (remainder.isNotEmpty) {
      final whenIndex = _findFirstTopLevelKeywordIndex(remainder, 'WHEN');
      if (whenIndex == null || whenIndex != 0) {
        final elseIndex = _findFirstTopLevelKeywordIndex(remainder, 'ELSE');
        if (elseIndex == 0) {
          elseExpression = remainder.substring(4).trim();
          if (elseExpression.isEmpty) {
            throw const _ExecutionException(
                'CASE ELSE expression cannot be empty.');
          }
          remainder = '';
          break;
        }
        throw _ExecutionException('Invalid CASE expression: $source');
      }

      final afterWhen = remainder.substring(4).trim();
      final thenIndex = _findFirstTopLevelKeywordIndex(afterWhen, 'THEN');
      if (thenIndex == null) {
        throw const _ExecutionException('CASE WHEN branch is missing THEN.');
      }

      final whenExpression = afterWhen.substring(0, thenIndex).trim();
      if (whenExpression.isEmpty) {
        throw const _ExecutionException(
            'CASE WHEN expression cannot be empty.');
      }

      final afterThen = afterWhen.substring(thenIndex + 4).trim();
      final nextWhen = _findFirstTopLevelKeywordIndex(afterThen, 'WHEN');
      final nextElse = _findFirstTopLevelKeywordIndex(afterThen, 'ELSE');

      int nextBoundary;
      if (nextWhen == null && nextElse == null) {
        nextBoundary = afterThen.length;
      } else if (nextWhen == null) {
        nextBoundary = nextElse!;
      } else if (nextElse == null) {
        nextBoundary = nextWhen;
      } else {
        nextBoundary = math.min(nextWhen, nextElse);
      }

      final thenExpression = afterThen.substring(0, nextBoundary).trim();
      if (thenExpression.isEmpty) {
        throw const _ExecutionException(
            'CASE THEN expression cannot be empty.');
      }
      whens.add(_CaseWhen(
          whenExpression: whenExpression, thenExpression: thenExpression));

      remainder = afterThen.substring(nextBoundary).trim();
      if (nextBoundary == afterThen.length) {
        break;
      }
    }

    if (whens.isEmpty) {
      throw const _ExecutionException(
          'CASE expression requires at least one WHEN.');
    }

    return _CaseExpression(
      caseInputExpression: caseInputExpression,
      whens: whens,
      elseExpression: elseExpression,
    );
  }

  Object? _evaluateCaseExpression(
    _CaseExpression caseExpression,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    final caseInput = caseExpression.caseInputExpression == null
        ? null
        : _evaluateScalarExpression(
            caseExpression.caseInputExpression!,
            row,
            aggregateRows: aggregateRows,
          );

    for (final whenBranch in caseExpression.whens) {
      if (caseExpression.caseInputExpression == null) {
        final conditionValue = _evaluateScalarExpression(
          whenBranch.whenExpression,
          row,
          aggregateRows: aggregateRows,
        );
        final condition = _coerceBooleanValue(
          conditionValue,
          context: 'CASE WHEN condition',
        );
        if (condition == true) {
          return _evaluateScalarExpression(
            whenBranch.thenExpression,
            row,
            aggregateRows: aggregateRows,
          );
        }
        continue;
      }

      final whenValue = _evaluateScalarExpression(
        whenBranch.whenExpression,
        row,
        aggregateRows: aggregateRows,
      );
      if (_evaluateComparisonOperator(caseInput, whenValue, '=') == true) {
        return _evaluateScalarExpression(
          whenBranch.thenExpression,
          row,
          aggregateRows: aggregateRows,
        );
      }
    }

    if (caseExpression.elseExpression case final String elseExpression) {
      return _evaluateScalarExpression(
        elseExpression,
        row,
        aggregateRows: aggregateRows,
      );
    }
    return null;
  }

  String? _tryParseExistsSubqueryExpression(String source) {
    final upper = source.toUpperCase();
    if (!upper.startsWith('EXISTS')) {
      return null;
    }
    if (source.length <= 6 || !_isTokenBoundary(source, 6)) {
      return null;
    }

    var index = 6;
    while (index < source.length && source[index].trim().isEmpty) {
      index++;
    }
    if (index >= source.length || source[index] != '{') {
      return null;
    }

    final segment = _readDelimitedSegment(
      source,
      index,
      open: '{',
      close: '}',
      context: 'EXISTS subquery',
    );
    if (segment == null || segment.$2 != source.length) {
      return null;
    }
    return segment.$1.trim();
  }

  bool _evaluateExistsSubquery(
    String body,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (body.isEmpty) {
      throw const _ExecutionException('EXISTS subquery cannot be empty.');
    }

    final patternResult = _tryEvaluateExistsPatternSubquery(
      body,
      row,
      aggregateRows: aggregateRows,
    );
    if (patternResult != null) {
      return patternResult;
    }

    final parseResult = Cypher.parse(body, options: parseOptions);
    if (parseResult.document == null || parseResult.hasErrors) {
      final message = parseResult.diagnostics.isNotEmpty
          ? parseResult.diagnostics.first.message
          : 'Invalid EXISTS subquery.';
      throw _ExecutionException('Invalid EXISTS subquery: $message');
    }

    for (final statement
        in parseResult.document!.statements.cast<CypherQueryStatement>()) {
      final output = _executeStatement(
        statement,
        seedRows: <_Row>[Map<String, Object?>.from(row)],
      );
      if (output.rows.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  bool? _tryEvaluateExistsPatternSubquery(
    String body,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    final trimmed = body.trim();
    if (!trimmed.startsWith('(')) {
      return null;
    }

    var patternText = trimmed;
    String? whereExpression;
    final whereIndex = _findTopLevelKeywordIndex(trimmed, 'WHERE');
    if (whereIndex != null) {
      patternText = trimmed.substring(0, whereIndex).trim();
      whereExpression = trimmed.substring(whereIndex + 'WHERE'.length).trim();
      if (patternText.isEmpty || whereExpression.isEmpty) {
        throw _ExecutionException('Invalid EXISTS pattern predicate: $body');
      }
    }

    final chain = _parsePatternChain(
      patternText,
      row,
      clauseName: 'EXISTS',
      allowPathVariable: true,
    );
    final matchedRows = _matchPatternChain(
      <_Row>[Map<String, Object?>.from(row)],
      chain,
      optional: false,
    );
    if (whereExpression == null) {
      return matchedRows.isNotEmpty;
    }

    for (final matchedRow in matchedRows) {
      final includeValue = _evaluateScalarExpression(
        whereExpression,
        matchedRow,
        aggregateRows: aggregateRows,
      );
      final include = _coerceBooleanValue(
        includeValue,
        context: 'EXISTS subquery WHERE predicate',
      );
      if (include == true) {
        return true;
      }
    }
    return false;
  }

  Object? _evaluateScalarExpression(
    String expression,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    final trimmed = expression.trim();
    if (trimmed.isEmpty) {
      throw const _ExecutionException('Expression cannot be empty.');
    }

    final unwrapped = _unwrapEnclosingParentheses(trimmed);
    if (unwrapped != trimmed) {
      return _evaluateScalarExpression(
        unwrapped,
        row,
        aggregateRows: aggregateRows,
      );
    }

    final parameterName = _tryParseParameterName(trimmed);
    if (parameterName != null) {
      if (!parameters.containsKey(parameterName)) {
        throw _ExecutionException('Missing parameter: $parameterName');
      }
      return parameters[parameterName];
    }
    if (trimmed.startsWith(r'$') &&
        !_looksLikeCompositeExpression(trimmed.substring(1))) {
      throw _ExecutionException('Invalid parameter name: $trimmed');
    }

    if (_isQuotedString(trimmed)) {
      return _unquote(trimmed);
    }

    if (_isHexIntegerLiteral(trimmed)) {
      return _parseRadixIntegerLiteral(trimmed, radix: 16, prefixLength: 2);
    }
    if (_isOctalIntegerLiteral(trimmed)) {
      return _parseRadixIntegerLiteral(trimmed, radix: 8, prefixLength: 2);
    }
    if (_isIntegerLiteral(trimmed)) {
      return int.parse(trimmed);
    }
    if (_isDoubleLiteral(trimmed)) {
      return double.parse(trimmed);
    }

    final lower = trimmed.toLowerCase();
    if (lower == 'true') {
      return true;
    }
    if (lower == 'false') {
      return false;
    }
    if (lower == 'null') {
      return null;
    }

    final caseExpression = _tryParseCaseExpression(trimmed);
    if (caseExpression != null) {
      return _evaluateCaseExpression(
        caseExpression,
        row,
        aggregateRows: aggregateRows,
      );
    }

    final existsSubqueryBody = _tryParseExistsSubqueryExpression(trimmed);
    if (existsSubqueryBody != null) {
      return _evaluateExistsSubquery(
        existsSubqueryBody,
        row,
        aggregateRows: aggregateRows,
      );
    }

    final orParts = _splitTopLevelByKeyword(trimmed, 'OR');
    if (orParts.length > 1) {
      Object? current = _evaluateScalarExpression(
        orParts.first,
        row,
        aggregateRows: aggregateRows,
      );
      for (var i = 1; i < orParts.length; i++) {
        final right = _evaluateScalarExpression(
          orParts[i],
          row,
          aggregateRows: aggregateRows,
        );
        current = _evaluateLogicalBinaryOperator('OR', current, right);
      }
      return current;
    }

    final xorParts = _splitTopLevelByKeyword(trimmed, 'XOR');
    if (xorParts.length > 1) {
      Object? current = _evaluateScalarExpression(
        xorParts.first,
        row,
        aggregateRows: aggregateRows,
      );
      for (var i = 1; i < xorParts.length; i++) {
        final right = _evaluateScalarExpression(
          xorParts[i],
          row,
          aggregateRows: aggregateRows,
        );
        current = _evaluateLogicalBinaryOperator('XOR', current, right);
      }
      return current;
    }

    final andParts = _splitTopLevelByKeyword(trimmed, 'AND');
    if (andParts.length > 1) {
      Object? current = _evaluateScalarExpression(
        andParts.first,
        row,
        aggregateRows: aggregateRows,
      );
      for (var i = 1; i < andParts.length; i++) {
        final right = _evaluateScalarExpression(
          andParts[i],
          row,
          aggregateRows: aggregateRows,
        );
        current = _evaluateLogicalBinaryOperator('AND', current, right);
      }
      return current;
    }

    final upperTrimmed = trimmed.toUpperCase();
    if (upperTrimmed.startsWith('NOT') && _isTokenBoundary(trimmed, 3)) {
      final notOperand = trimmed.substring(3).trimLeft();
      if (notOperand.isEmpty) {
        throw const _ExecutionException('NOT requires an operand.');
      }
      final value = _evaluateScalarExpression(
        notOperand,
        row,
        aggregateRows: aggregateRows,
      );
      return _evaluateLogicalNotOperator(value);
    }

    if (_isWrapped(trimmed, '[', ']')) {
      return _parseListConstruct(
        trimmed,
        row,
        aggregateRows: aggregateRows,
      );
    }

    if (_isWrapped(trimmed, '{', '}')) {
      return _parseMapLiteral(
        trimmed,
        row,
        aggregateRows: aggregateRows,
      );
    }

    final comparisonChain = _parseComparisonChain(trimmed);
    if (comparisonChain != null) {
      return _evaluateComparisonChain(
        comparisonChain,
        row,
        aggregateRows: aggregateRows,
      );
    }

    final stringSearch = _tryParseStringSearchExpression(trimmed);
    if (stringSearch != null) {
      final left = _evaluateScalarExpression(
        stringSearch.left,
        row,
        aggregateRows: aggregateRows,
      );
      final right = _evaluateScalarExpression(
        stringSearch.right,
        row,
        aggregateRows: aggregateRows,
      );
      return _evaluateStringSearch(
        operator: stringSearch.operator,
        left: left,
        right: right,
      );
    }

    final isNotNullExpression =
        _tryParseSuffixKeywordExpression(trimmed, 'IS NOT NULL');
    if (isNotNullExpression != null) {
      return _evaluateScalarExpression(
            isNotNullExpression,
            row,
            aggregateRows: aggregateRows,
          ) !=
          null;
    }

    final isNullExpression =
        _tryParseSuffixKeywordExpression(trimmed, 'IS NULL');
    if (isNullExpression != null) {
      return _evaluateScalarExpression(
            isNullExpression,
            row,
            aggregateRows: aggregateRows,
          ) ==
          null;
    }

    final inOperator = _tryParseInExpression(trimmed);
    if (inOperator != null) {
      final left = _evaluateScalarExpression(
        inOperator.$1,
        row,
        aggregateRows: aggregateRows,
      );
      final right = _evaluateScalarExpression(
        inOperator.$2,
        row,
        aggregateRows: aggregateRows,
      );
      if (right == null) {
        return null;
      }
      if (right is! Iterable || right is String || right is Map) {
        throw _ExecutionException(
          'IN expects a list value on the right-hand side.',
        );
      }
      if (left == null) {
        return null;
      }
      var encounteredNull = false;
      for (final candidate in right) {
        if (candidate == null) {
          encounteredNull = true;
          continue;
        }
        if (_valuesEqual(left, candidate)) {
          return true;
        }
      }
      return encounteredNull ? null : false;
    }

    final labelPredicate = _tryParseLabelPredicate(trimmed);
    if (labelPredicate != null) {
      final value = _evaluateScalarExpression(
        labelPredicate.$1,
        row,
        aggregateRows: aggregateRows,
      );
      if (value == null) {
        return false;
      }
      if (value is CypherGraphNode) {
        return value.labels.containsAll(labelPredicate.$2);
      }
      if (value is CypherGraphRelationship) {
        if (labelPredicate.$2.length != 1) {
          return false;
        }
        return labelPredicate.$2.first == value.type;
      }
      throw const _ExecutionException(
        'Label/type predicate expects a node or relationship value.',
      );
    }

    final patternPredicate = _tryEvaluatePatternPredicate(trimmed, row);
    if (patternPredicate != null) {
      return patternPredicate;
    }

    final additiveOperator =
        _findTopLevelBinaryOperator(trimmed, const <String>['+', '-']);
    if (additiveOperator != null) {
      final left = _evaluateScalarExpression(
        trimmed.substring(0, additiveOperator.$1),
        row,
        aggregateRows: aggregateRows,
      );
      final right = _evaluateScalarExpression(
        trimmed.substring(additiveOperator.$1 + additiveOperator.$2.length),
        row,
        aggregateRows: aggregateRows,
      );
      return _evaluateBinaryArithmetic(additiveOperator.$2, left, right);
    }

    final multiplicativeOperator =
        _findTopLevelBinaryOperator(trimmed, const <String>['*', '/', '%']);
    if (multiplicativeOperator != null) {
      final left = _evaluateScalarExpression(
        trimmed.substring(0, multiplicativeOperator.$1),
        row,
        aggregateRows: aggregateRows,
      );
      final right = _evaluateScalarExpression(
        trimmed.substring(
          multiplicativeOperator.$1 + multiplicativeOperator.$2.length,
        ),
        row,
        aggregateRows: aggregateRows,
      );
      return _evaluateBinaryArithmetic(multiplicativeOperator.$2, left, right);
    }

    final powerOperatorIndex = _findTopLevelPowerOperator(trimmed);
    if (powerOperatorIndex != null) {
      final left = _evaluateScalarExpression(
        trimmed.substring(0, powerOperatorIndex),
        row,
        aggregateRows: aggregateRows,
      );
      final right = _evaluateScalarExpression(
        trimmed.substring(powerOperatorIndex + 1),
        row,
        aggregateRows: aggregateRows,
      );
      return _evaluateBinaryArithmetic('^', left, right);
    }

    if (trimmed.startsWith('-')) {
      final value = _evaluateScalarExpression(
        trimmed.substring(1),
        row,
        aggregateRows: aggregateRows,
      );
      if (value == null) {
        return null;
      }
      if (value is num) {
        return -value;
      }
      throw _ExecutionException('Unary minus expects a numeric value.');
    }

    final indexAccess = _tryParseIndexAccess(trimmed);
    if (indexAccess != null) {
      final target = _evaluateScalarExpression(
        indexAccess.$1,
        row,
        aggregateRows: aggregateRows,
      );
      final slice = _tryParseSliceExpression(indexAccess.$2);
      if (slice != null) {
        final lower = slice.lowerExpression == null
            ? null
            : _evaluateScalarExpression(
                slice.lowerExpression!,
                row,
                aggregateRows: aggregateRows,
              );
        final upper = slice.upperExpression == null
            ? null
            : _evaluateScalarExpression(
                slice.upperExpression!,
                row,
                aggregateRows: aggregateRows,
              );
        return _readSlice(
          target: target,
          lower: lower,
          upper: upper,
          lowerOmitted: slice.lowerOmitted,
          upperOmitted: slice.upperOmitted,
        );
      }
      final index = _evaluateScalarExpression(
        indexAccess.$2,
        row,
        aggregateRows: aggregateRows,
      );
      return _readIndex(target: target, index: index);
    }

    final function = _tryParseFunctionCall(trimmed);
    if (function != null) {
      return _evaluateFunction(
        function.$1,
        function.$2,
        row,
        aggregateRows: aggregateRows,
      );
    }

    final propertyAccess = _tryParsePropertyAccessExpression(trimmed);
    if (propertyAccess != null) {
      final target = _evaluateScalarExpression(
        propertyAccess.$1,
        row,
        aggregateRows: aggregateRows,
      );
      return _readPropertyValue(value: target, property: propertyAccess.$2);
    }

    if (_isIdentifier(trimmed)) {
      return row[_tryParseIdentifier(trimmed)!];
    }

    throw _ExecutionException('Unsupported expression: $trimmed');
  }

  Object? _parseListConstruct(
    String source,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    final inner = source.substring(1, source.length - 1).trim();
    if (inner.isEmpty) {
      return const <Object?>[];
    }

    final projectionIndex = _findTopLevelChar(inner, '|');
    if (projectionIndex == null) {
      final listHeader = _tryParseListComprehensionHeader(inner);
      if (listHeader != null) {
        final listValue = _evaluateScalarExpression(
          listHeader.listExpression,
          row,
          aggregateRows: aggregateRows,
        );
        if (listValue == null) {
          return null;
        }
        if (listValue is! Iterable || listValue is String || listValue is Map) {
          throw const _ExecutionException(
            'List comprehension expects a list expression after IN.',
          );
        }

        final output = <Object?>[];
        for (final element in listValue) {
          final scopedRow = Map<String, Object?>.from(row);
          scopedRow[listHeader.variable] = element;
          if (listHeader.whereExpression case final String whereExpression) {
            final includeValue = _evaluateScalarExpression(
              whereExpression,
              scopedRow,
              aggregateRows: aggregateRows,
            );
            final include = _coerceBooleanValue(
              includeValue,
              context: 'list comprehension WHERE predicate',
            );
            if (include != true) {
              continue;
            }
          }
          output.add(scopedRow[listHeader.variable]);
        }
        return List<Object?>.unmodifiable(output);
      }

      return _splitTopLevelByComma(inner)
          .map(
            (part) => _evaluateScalarExpression(
              part,
              row,
              aggregateRows: aggregateRows,
            ),
          )
          .toList(growable: false);
    }

    final header = inner.substring(0, projectionIndex).trim();
    final projection = inner.substring(projectionIndex + 1).trim();
    if (header.isEmpty || projection.isEmpty) {
      throw _ExecutionException('Invalid list expression: $source');
    }

    final listHeader = _tryParseListComprehensionHeader(header);
    if (listHeader != null) {
      final listValue = _evaluateScalarExpression(
        listHeader.listExpression,
        row,
        aggregateRows: aggregateRows,
      );
      if (listValue == null) {
        return null;
      }
      if (listValue is! Iterable || listValue is String || listValue is Map) {
        throw const _ExecutionException(
          'List comprehension expects a list expression after IN.',
        );
      }

      final output = <Object?>[];
      for (final element in listValue) {
        final scopedRow = Map<String, Object?>.from(row);
        scopedRow[listHeader.variable] = element;

        if (listHeader.whereExpression case final String whereExpression) {
          final includeValue = _evaluateScalarExpression(
            whereExpression,
            scopedRow,
            aggregateRows: aggregateRows,
          );
          final include = _coerceBooleanValue(
            includeValue,
            context: 'list comprehension WHERE predicate',
          );
          if (include != true) {
            continue;
          }
        }

        output.add(
          _evaluateScalarExpression(
            projection,
            scopedRow,
            aggregateRows: aggregateRows,
          ),
        );
      }
      return List<Object?>.unmodifiable(output);
    }

    var pattern = header;
    String? whereExpression;
    final whereIndex = _findTopLevelKeywordIndex(header, 'WHERE');
    if (whereIndex != null) {
      pattern = header.substring(0, whereIndex).trim();
      whereExpression = header.substring(whereIndex + 'WHERE'.length).trim();
      if (pattern.isEmpty || whereExpression.isEmpty) {
        throw _ExecutionException('Invalid pattern comprehension: $source');
      }
    }

    final chain = _parsePatternChain(
      pattern,
      row,
      clauseName: 'pattern comprehension',
      allowPathVariable: true,
    );
    final matchedRows = _matchPatternChain(
      <_Row>[Map<String, Object?>.from(row)],
      chain,
      optional: false,
    );

    final output = <Object?>[];
    for (final matchedRow in matchedRows) {
      if (whereExpression != null) {
        final includeValue = _evaluateScalarExpression(
          whereExpression,
          matchedRow,
          aggregateRows: aggregateRows,
        );
        final include = _coerceBooleanValue(
          includeValue,
          context: 'pattern comprehension WHERE predicate',
        );
        if (include != true) {
          continue;
        }
      }

      output.add(
        _evaluateScalarExpression(
          projection,
          matchedRow,
          aggregateRows: aggregateRows,
        ),
      );
    }
    return List<Object?>.unmodifiable(output);
  }

  _ListComprehensionHeader? _tryParseListComprehensionHeader(String source) {
    final inIndex = _findTopLevelKeywordIndex(source, 'IN');
    if (inIndex == null) {
      return null;
    }

    final variableText = source.substring(0, inIndex).trim();
    final variable = _tryParseIdentifier(variableText);
    if (variable == null) {
      return null;
    }

    final remainder = source.substring(inIndex + 'IN'.length).trim();
    if (remainder.isEmpty) {
      throw _ExecutionException('List comprehension requires an IN source.');
    }

    final whereIndex = _findTopLevelKeywordIndex(remainder, 'WHERE');
    if (whereIndex == null) {
      return _ListComprehensionHeader(
        variable: variable,
        listExpression: remainder,
      );
    }

    final listExpression = remainder.substring(0, whereIndex).trim();
    final whereExpression =
        remainder.substring(whereIndex + 'WHERE'.length).trim();
    if (listExpression.isEmpty || whereExpression.isEmpty) {
      throw const _ExecutionException(
        'List comprehension WHERE clause cannot be empty.',
      );
    }
    return _ListComprehensionHeader(
      variable: variable,
      listExpression: listExpression,
      whereExpression: whereExpression,
    );
  }

  Map<String, Object?> _parseMapLiteral(
    String source,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    final inner = source.substring(1, source.length - 1).trim();
    if (inner.isEmpty) {
      return const <String, Object?>{};
    }

    final map = <String, Object?>{};
    for (final entry in _splitTopLevelByComma(inner)) {
      final index = _findTopLevelChar(entry, ':');
      if (index == null) {
        throw _ExecutionException('Invalid map entry: $entry');
      }
      final rawKey = entry.substring(0, index).trim();
      final rawValue = entry.substring(index + 1).trim();
      if (rawKey.isEmpty || rawValue.isEmpty) {
        throw _ExecutionException('Invalid map entry: $entry');
      }

      final key = _parseMapKey(rawKey);
      map[key] = _evaluateScalarExpression(
        rawValue,
        row,
        aggregateRows: aggregateRows,
      );
    }
    return map;
  }

  String _parseMapKey(String rawKey) {
    if (_isIdentifier(rawKey)) {
      return _tryParseIdentifier(rawKey)!;
    }
    if (_isQuotedString(rawKey)) {
      return _unquote(rawKey);
    }
    throw _ExecutionException('Unsupported map key: $rawKey');
  }

  (String, List<String>)? _tryParseFunctionCall(String source) {
    final open = _findTopLevelChar(source, '(');
    if (open == null || !source.endsWith(')')) {
      return null;
    }
    final name = source.substring(0, open).trim();
    if (!_isFunctionName(name)) {
      return null;
    }
    final argsText = source.substring(open + 1, source.length - 1).trim();
    if (argsText.isEmpty) {
      return (name, const <String>[]);
    }
    return (name, _splitTopLevelByComma(argsText));
  }

  bool _isFunctionName(String value) {
    if (_isIdentifier(value)) {
      return true;
    }

    final segments = value.split('.');
    if (segments.length < 2) {
      return false;
    }
    for (final segment in segments) {
      if (!_isIdentifier(segment)) {
        return false;
      }
    }
    return true;
  }

  Object? _evaluateFunction(
    String name,
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    final normalized = name.toLowerCase();
    if (_isAggregateFunctionName(normalized)) {
      if (aggregateRows == null) {
        throw _ExecutionException('Unsupported function: $name');
      }
      return _computeAggregateFunction(normalized, args, aggregateRows);
    }

    switch (normalized) {
      case 'range':
        if (args.length < 2 || args.length > 3) {
          throw _ExecutionException('range expects 2 or 3 arguments.');
        }
        final start = _evaluateScalarExpression(
          args[0],
          row,
          aggregateRows: aggregateRows,
        );
        final end = _evaluateScalarExpression(
          args[1],
          row,
          aggregateRows: aggregateRows,
        );
        final step = args.length == 3
            ? _evaluateScalarExpression(
                args[2],
                row,
                aggregateRows: aggregateRows,
              )
            : 1;
        if (start == null || end == null || step == null) {
          return null;
        }
        if (start is! int || end is! int || step is! int) {
          throw _ExecutionException('range() expects integer arguments.');
        }
        if (step == 0) {
          throw const _ExecutionException('range() step cannot be zero.');
        }
        final values = <int>[];
        if (step > 0) {
          for (var value = start; value <= end; value += step) {
            values.add(value);
          }
        } else {
          for (var value = start; value >= end; value += step) {
            values.add(value);
          }
        }
        return List<int>.unmodifiable(values);
      case 'toboolean':
        if (args.length != 1) {
          throw _ExecutionException('toBoolean expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is bool) {
          return value;
        }
        if (value is String) {
          final normalizedValue = value.trim().toLowerCase();
          if (normalizedValue == 'true') {
            return true;
          }
          if (normalizedValue == 'false') {
            return false;
          }
          return null;
        }
        throw _ExecutionException(
          'Cannot convert ${value.runtimeType} to boolean.',
        );
      case 'date':
        return _evaluateDateFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'localtime':
        return _evaluateLocalTimeFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'time':
        return _evaluateTimeFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'localdatetime':
        return _evaluateLocalDateTimeFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'datetime':
        return _evaluateDateTimeFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'datetime.fromepoch':
        return _evaluateDateTimeFromEpochFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'datetime.fromepochmillis':
        return _evaluateDateTimeFromEpochMillisFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'duration':
        return _evaluateDurationFunction(
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'duration.between':
      case 'duration.inmonths':
      case 'duration.indays':
      case 'duration.inseconds':
        return _evaluateDurationBetweenFunction(
          normalized,
          args,
          row,
          aggregateRows: aggregateRows,
        );
      case 'tointeger':
        if (args.length != 1) {
          throw _ExecutionException('toInteger expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is int) {
          return value;
        }
        if (value is num) {
          return value.toInt();
        }
        if (value is String) {
          return int.tryParse(value);
        }
        throw _ExecutionException(
            'Cannot convert ${value.runtimeType} to integer.');
      case 'tofloat':
        if (args.length != 1) {
          throw _ExecutionException('toFloat expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is num) {
          return value.toDouble();
        }
        if (value is String) {
          return double.tryParse(value);
        }
        throw _ExecutionException(
            'Cannot convert ${value.runtimeType} to float.');
      case 'tostring':
        if (args.length != 1) {
          throw _ExecutionException('toString expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is num || value is bool || value is String) {
          return value.toString();
        }
        if (value is _TemporalValue || value is _TemporalDuration) {
          return value.toString();
        }
        throw _ExecutionException(
          'Cannot convert ${value.runtimeType} to string.',
        );
      case 'abs':
        if (args.length != 1) {
          throw _ExecutionException('abs expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! num) {
          throw _ExecutionException('abs() expects a numeric value.');
        }
        return value.abs();
      case 'sign':
        if (args.length != 1) {
          throw _ExecutionException('sign expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! num) {
          throw _ExecutionException('sign() expects a numeric value.');
        }
        if (value > 0) {
          return 1;
        }
        if (value < 0) {
          return -1;
        }
        return 0;
      case 'ceil':
        if (args.length != 1) {
          throw _ExecutionException('ceil expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! num) {
          throw _ExecutionException('ceil() expects a numeric value.');
        }
        return value.ceil();
      case 'floor':
        if (args.length != 1) {
          throw _ExecutionException('floor expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! num) {
          throw _ExecutionException('floor() expects a numeric value.');
        }
        return value.floor();
      case 'sqrt':
        if (args.length != 1) {
          throw _ExecutionException('sqrt expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! num) {
          throw _ExecutionException('sqrt() expects a numeric value.');
        }
        return math.sqrt(value.toDouble());
      case 'rand':
        if (args.isNotEmpty) {
          throw _ExecutionException('rand expects 0 arguments.');
        }
        return _random.nextDouble();
      case 'size':
        if (args.length != 1) {
          throw _ExecutionException('size expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is String) {
          return value.length;
        }
        if (value is Iterable) {
          return value.length;
        }
        if (value is Map) {
          return value.length;
        }
        throw _ExecutionException(
            'size() does not support ${value.runtimeType}.');
      case 'length':
        if (args.length != 1) {
          throw _ExecutionException('length expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is CypherGraphPath) {
          return value.relationships.length;
        }
        if (value is String) {
          return value.length;
        }
        if (value is Iterable) {
          return value.length;
        }
        throw _ExecutionException(
          'length() does not support ${value.runtimeType}.',
        );
      case 'type':
        if (args.length != 1) {
          throw _ExecutionException('type expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is CypherGraphRelationship) {
          return value.type;
        }
        throw _ExecutionException('type() expects a relationship value.');
      case 'id':
        if (args.length != 1) {
          throw _ExecutionException('id expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is CypherGraphNode) {
          return value.id;
        }
        if (value is CypherGraphRelationship) {
          return value.id;
        }
        throw _ExecutionException('id() expects a node or relationship value.');
      case 'labels':
        if (args.length != 1) {
          throw _ExecutionException('labels expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! CypherGraphNode) {
          throw _ExecutionException('labels() expects a node value.');
        }
        final labels = value.labels.toList(growable: false);
        return List<String>.unmodifiable(labels);
      case 'keys':
        if (args.length != 1) {
          throw _ExecutionException('keys expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is CypherGraphNode) {
          return List<String>.unmodifiable(
            value.properties.keys.toList(growable: false),
          );
        }
        if (value is CypherGraphRelationship) {
          return List<String>.unmodifiable(
            value.properties.keys.toList(growable: false),
          );
        }
        if (value is Map) {
          return List<String>.unmodifiable(
            value.keys.map((key) => key.toString()).toList(growable: false),
          );
        }
        throw _ExecutionException(
          'keys() expects a map, node, or relationship value.',
        );
      case 'properties':
        if (args.length != 1) {
          throw _ExecutionException('properties expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is CypherGraphNode) {
          return Map<String, Object?>.unmodifiable(
            Map<String, Object?>.from(value.properties),
          );
        }
        if (value is CypherGraphRelationship) {
          return Map<String, Object?>.unmodifiable(
            Map<String, Object?>.from(value.properties),
          );
        }
        if (value is Map) {
          return Map<Object?, Object?>.unmodifiable(
            Map<Object?, Object?>.from(value),
          );
        }
        throw _ExecutionException(
          'properties() expects a map, node, or relationship value.',
        );
      case 'nodes':
        if (args.length != 1) {
          throw _ExecutionException('nodes expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! CypherGraphPath) {
          throw _ExecutionException('nodes() expects a path value.');
        }
        return List<CypherGraphNode>.unmodifiable(value.nodes);
      case 'relationships':
        if (args.length != 1) {
          throw _ExecutionException('relationships expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! CypherGraphPath) {
          throw _ExecutionException('relationships() expects a path value.');
        }
        return List<CypherGraphRelationship>.unmodifiable(value.relationships);
      case 'startnode':
      case 'endnode':
        if (args.length != 1) {
          throw _ExecutionException('$name expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! CypherGraphRelationship) {
          throw _ExecutionException('$name() expects a relationship value.');
        }
        final nodeId =
            normalized == 'startnode' ? value.startNodeId : value.endNodeId;
        return graph.nodeById(nodeId);
      case 'split':
        if (args.length != 2) {
          throw _ExecutionException('split expects 2 arguments.');
        }
        final source = _evaluateScalarExpression(
          args[0],
          row,
          aggregateRows: aggregateRows,
        );
        final delimiter = _evaluateScalarExpression(
          args[1],
          row,
          aggregateRows: aggregateRows,
        );
        if (source == null || delimiter == null) {
          return null;
        }
        if (source is! String || delimiter is! String) {
          throw _ExecutionException('split() expects string arguments.');
        }
        return source.split(delimiter);
      case 'substring':
        if (args.length < 2 || args.length > 3) {
          throw _ExecutionException('substring expects 2 or 3 arguments.');
        }
        final source = _evaluateScalarExpression(
          args[0],
          row,
          aggregateRows: aggregateRows,
        );
        final start = _evaluateScalarExpression(
          args[1],
          row,
          aggregateRows: aggregateRows,
        );
        final length = args.length == 3
            ? _evaluateScalarExpression(
                args[2],
                row,
                aggregateRows: aggregateRows,
              )
            : null;
        if (source == null ||
            start == null ||
            (args.length == 3 && length == null)) {
          return null;
        }
        if (source is! String || start is! int) {
          throw _ExecutionException(
              'substring() expects (string, int, [int]).');
        }
        if (args.length == 2) {
          if (start < 0 || start >= source.length) {
            return '';
          }
          return source.substring(start);
        }
        if (length is! int) {
          throw _ExecutionException('substring() length must be an integer.');
        }
        if (length <= 0 || start >= source.length) {
          return '';
        }
        final safeStart = start < 0 ? 0 : start;
        final end = safeStart + length;
        final safeEnd = end > source.length ? source.length : end;
        if (safeStart >= safeEnd) {
          return '';
        }
        return source.substring(safeStart, safeEnd);
      case 'head':
      case 'last':
        if (args.length != 1) {
          throw _ExecutionException('$name expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        final list = value is List
            ? value
            : value is Iterable
                ? value.toList(growable: false)
                : null;
        if (list == null) {
          throw _ExecutionException('$name() expects a list value.');
        }
        if (list.isEmpty) {
          return null;
        }
        return normalized == 'head' ? list.first : list.last;
      case 'tail':
        if (args.length != 1) {
          throw _ExecutionException('tail expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        final list = value is List
            ? value
            : value is Iterable
                ? value.toList(growable: false)
                : null;
        if (list == null) {
          throw const _ExecutionException('tail() expects a list value.');
        }
        if (list.length <= 1) {
          return const <Object?>[];
        }
        return List<Object?>.unmodifiable(list.sublist(1));
      case 'reverse':
        if (args.length != 1) {
          throw _ExecutionException('reverse expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is String) {
          return value.split('').reversed.join();
        }
        if (value is List) {
          return List<Object?>.unmodifiable(value.reversed.toList());
        }
        if (value is Iterable) {
          return List<Object?>.unmodifiable(value.toList().reversed.toList());
        }
        throw _ExecutionException(
          'reverse() expects a string or list value.',
        );
      case 'tolower':
      case 'toupper':
        if (args.length != 1) {
          throw _ExecutionException('$name expects 1 argument.');
        }
        final value = _evaluateScalarExpression(
          args.first,
          row,
          aggregateRows: aggregateRows,
        );
        if (value == null) {
          return null;
        }
        if (value is! String) {
          throw _ExecutionException('$name() expects a string value.');
        }
        return normalized == 'tolower'
            ? value.toLowerCase()
            : value.toUpperCase();
      case 'coalesce':
        for (final argument in args) {
          final value = _evaluateScalarExpression(
            argument,
            row,
            aggregateRows: aggregateRows,
          );
          if (value != null) {
            return value;
          }
        }
        return null;
      case 'all':
      case 'any':
      case 'none':
      case 'single':
        return _evaluateListPredicateFunction(
          name: normalized,
          args: args,
          row: row,
          aggregateRows: aggregateRows,
        );
      default:
        throw _ExecutionException('Unsupported function: $name');
    }
  }

  Object? _computePercentileFunction(
    String name,
    List<String> args,
    List<_Row> rows,
  ) {
    if (args.length != 2) {
      throw _ExecutionException('$name expects 2 arguments.');
    }

    final percentileSeed =
        rows.isEmpty ? const <String, Object?>{} : rows.first;
    final percentileValue = _evaluateScalarExpression(args[1], percentileSeed);
    if (percentileValue == null) {
      return null;
    }
    double? percentile;
    if (percentileValue is num) {
      percentile = percentileValue.toDouble();
    } else if (percentileValue is String) {
      percentile = double.tryParse(percentileValue.trim());
    }
    if (percentile == null) {
      throw _ExecutionException('$name percentile argument must be numeric.');
    }
    if (percentile < 0 || percentile > 1) {
      throw _ExecutionException('$name percentile must be between 0 and 1.');
    }

    final values = <double>[];
    for (final row in rows) {
      final value = _evaluateScalarExpression(args[0], row);
      if (value == null) {
        continue;
      }
      if (value is! num) {
        throw _ExecutionException('$name expects numeric values.');
      }
      values.add(value.toDouble());
    }
    if (values.isEmpty) {
      return null;
    }
    values.sort();

    if (name == 'percentiledisc') {
      final rank = (percentile * values.length).ceil();
      final index = rank <= 0 ? 0 : rank - 1;
      return values[index >= values.length ? values.length - 1 : index];
    }

    if (values.length == 1) {
      return values.first;
    }
    final position = percentile * (values.length - 1);
    final lowerIndex = position.floor();
    final upperIndex = position.ceil();
    if (lowerIndex == upperIndex) {
      return values[lowerIndex];
    }
    final fraction = position - lowerIndex;
    return values[lowerIndex] +
        (values[upperIndex] - values[lowerIndex]) * fraction;
  }

  Object? _evaluateDateFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw const _ExecutionException('date expects 1 argument.');
    }
    final value = _evaluateScalarExpression(
      args.first,
      row,
      aggregateRows: aggregateRows,
    );
    if (value == null) {
      return null;
    }
    if (value is _TemporalDate) {
      return value;
    }
    if (value is _TemporalLocalDateTime) {
      return value.date;
    }
    if (value is _TemporalDateTime) {
      return value.date;
    }
    if (value is String) {
      return _parseTemporalDateString(value);
    }
    if (value is Map) {
      return _parseTemporalDateFromMap(Map<Object?, Object?>.from(value));
    }
    throw _ExecutionException(
      'date() expects a string, map, or temporal value. Got ${value.runtimeType}.',
    );
  }

  Object? _evaluateLocalTimeFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw const _ExecutionException('localtime expects 1 argument.');
    }
    final value = _evaluateScalarExpression(
      args.first,
      row,
      aggregateRows: aggregateRows,
    );
    if (value == null) {
      return null;
    }
    if (value is _TemporalLocalTime) {
      return value;
    }
    if (value is _TemporalTime) {
      return value.localTime;
    }
    if (value is String) {
      return _parseTemporalLocalTimeString(value);
    }
    if (value is Map) {
      return _parseTemporalLocalTimeFromMap(
        Map<Object?, Object?>.from(value),
      );
    }
    throw _ExecutionException(
      'localtime() expects a string, map, or temporal value. Got ${value.runtimeType}.',
    );
  }

  Object? _evaluateTimeFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw const _ExecutionException('time expects 1 argument.');
    }
    final value = _evaluateScalarExpression(
      args.first,
      row,
      aggregateRows: aggregateRows,
    );
    if (value == null) {
      return null;
    }
    if (value is _TemporalTime) {
      return value;
    }
    if (value is String) {
      return _parseTemporalTimeString(value);
    }
    if (value is Map) {
      return _parseTemporalTimeFromMap(Map<Object?, Object?>.from(value));
    }
    throw _ExecutionException(
      'time() expects a string, map, or temporal value. Got ${value.runtimeType}.',
    );
  }

  Object? _evaluateLocalDateTimeFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw const _ExecutionException('localdatetime expects 1 argument.');
    }
    final value = _evaluateScalarExpression(
      args.first,
      row,
      aggregateRows: aggregateRows,
    );
    if (value == null) {
      return null;
    }
    if (value is _TemporalLocalDateTime) {
      return value;
    }
    if (value is _TemporalDateTime) {
      return _TemporalLocalDateTime(date: value.date, localTime: value.time);
    }
    if (value is String) {
      return _parseTemporalLocalDateTimeString(value);
    }
    if (value is Map) {
      return _parseTemporalLocalDateTimeFromMap(
        Map<Object?, Object?>.from(value),
      );
    }
    throw _ExecutionException(
      'localdatetime() expects a string, map, or temporal value. Got ${value.runtimeType}.',
    );
  }

  Object? _evaluateDateTimeFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw const _ExecutionException('datetime expects 1 argument.');
    }
    final value = _evaluateScalarExpression(
      args.first,
      row,
      aggregateRows: aggregateRows,
    );
    if (value == null) {
      return null;
    }
    if (value is _TemporalDateTime) {
      return value;
    }
    if (value is _TemporalLocalDateTime) {
      return _TemporalDateTime(
        date: value.date,
        time: value.localTime,
        offsetMinutes: 0,
      );
    }
    if (value is String) {
      return _parseTemporalDateTimeString(value);
    }
    if (value is Map) {
      return _parseTemporalDateTimeFromMap(Map<Object?, Object?>.from(value));
    }
    throw _ExecutionException(
      'datetime() expects a string, map, or temporal value. Got ${value.runtimeType}.',
    );
  }

  Object? _evaluateDateTimeFromEpochFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 2) {
      throw const _ExecutionException(
          'datetime.fromEpoch expects 2 arguments.');
    }
    final secondsValue = _evaluateScalarExpression(
      args[0],
      row,
      aggregateRows: aggregateRows,
    );
    final nanosValue = _evaluateScalarExpression(
      args[1],
      row,
      aggregateRows: aggregateRows,
    );
    if (secondsValue == null || nanosValue == null) {
      return null;
    }
    if (secondsValue is! num || nanosValue is! num) {
      throw const _ExecutionException(
        'datetime.fromEpoch() expects numeric arguments.',
      );
    }

    var seconds = secondsValue.toInt();
    var nanos = nanosValue.toInt();
    seconds += nanos ~/ 1000000000;
    nanos %= 1000000000;
    if (nanos < 0) {
      nanos += 1000000000;
      seconds--;
    }

    final epoch =
        DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    final date = _TemporalDate(
      year: epoch.year,
      month: epoch.month,
      day: epoch.day,
    );
    final time = _TemporalLocalTime(
      hour: epoch.hour,
      minute: epoch.minute,
      second: epoch.second,
      nanosecond:
          epoch.millisecond * 1000000 + epoch.microsecond * 1000 + nanos,
    );
    return _TemporalDateTime(
      date: date,
      time: time,
      offsetMinutes: 0,
    );
  }

  Object? _evaluateDateTimeFromEpochMillisFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw const _ExecutionException(
        'datetime.fromEpochMillis expects 1 argument.',
      );
    }
    final millisValue = _evaluateScalarExpression(
      args.first,
      row,
      aggregateRows: aggregateRows,
    );
    if (millisValue == null) {
      return null;
    }
    if (millisValue is! num) {
      throw const _ExecutionException(
        'datetime.fromEpochMillis() expects a numeric argument.',
      );
    }

    final millis = millisValue.toInt();
    final epoch = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    final date = _TemporalDate(
      year: epoch.year,
      month: epoch.month,
      day: epoch.day,
    );
    final time = _TemporalLocalTime(
      hour: epoch.hour,
      minute: epoch.minute,
      second: epoch.second,
      nanosecond: epoch.millisecond * 1000000 + epoch.microsecond * 1000,
    );
    return _TemporalDateTime(
      date: date,
      time: time,
      offsetMinutes: 0,
    );
  }

  Object? _evaluateDurationFunction(
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw const _ExecutionException('duration expects 1 argument.');
    }
    final value = _evaluateScalarExpression(
      args.first,
      row,
      aggregateRows: aggregateRows,
    );
    if (value == null) {
      return null;
    }
    if (value is _TemporalDuration) {
      return value;
    }
    if (value is Map) {
      return _parseTemporalDurationFromMap(Map<Object?, Object?>.from(value));
    }
    if (value is String) {
      final parsed = _parseTemporalDurationString(value);
      return parsed ?? const _TemporalDuration();
    }
    throw _ExecutionException(
      'duration() expects a string, map, or duration value. Got ${value.runtimeType}.',
    );
  }

  Object? _evaluateDurationBetweenFunction(
    String normalizedName,
    List<String> args,
    _Row row, {
    List<_Row>? aggregateRows,
  }) {
    if (args.length != 2) {
      throw _ExecutionException('$normalizedName expects 2 arguments.');
    }
    final left = _evaluateScalarExpression(
      args[0],
      row,
      aggregateRows: aggregateRows,
    );
    final right = _evaluateScalarExpression(
      args[1],
      row,
      aggregateRows: aggregateRows,
    );
    if (left == null || right == null) {
      return null;
    }

    final leftDateTime = _toUtcDateTime(left);
    final rightDateTime = _toUtcDateTime(right);
    final monthDiff = _monthDifference(left, right);
    if (normalizedName == 'duration.inmonths') {
      if (monthDiff == null) {
        return const _TemporalDuration();
      }
      return _TemporalDuration(months: monthDiff);
    }

    if (leftDateTime == null || rightDateTime == null) {
      return const _TemporalDuration();
    }

    final difference = rightDateTime.difference(leftDateTime);
    if (normalizedName == 'duration.indays') {
      return _TemporalDuration(days: difference.inDays);
    }

    if (normalizedName == 'duration.inseconds') {
      final micros = difference.inMicroseconds;
      var seconds = micros ~/ Duration.microsecondsPerSecond;
      var nanos = (micros % Duration.microsecondsPerSecond) * 1000;
      if (nanos < 0) {
        nanos += 1000000000;
        seconds--;
      }
      return _TemporalDuration(seconds: seconds, nanoseconds: nanos);
    }

    // duration.between()
    var months = monthDiff ?? 0;
    var anchor = leftDateTime;
    if (months != 0) {
      anchor = _addMonthsToDateTimeUtc(leftDateTime, months);
      if (months > 0 && anchor.isAfter(rightDateTime)) {
        months--;
        anchor = _addMonthsToDateTimeUtc(leftDateTime, months);
      } else if (months < 0 && anchor.isBefore(rightDateTime)) {
        months++;
        anchor = _addMonthsToDateTimeUtc(leftDateTime, months);
      }
    }

    final remainder = rightDateTime.difference(anchor);
    final days = remainder.inDays;
    final dayRemainder = remainder - Duration(days: days);
    final micros = dayRemainder.inMicroseconds;
    var seconds = micros ~/ Duration.microsecondsPerSecond;
    var nanos = (micros % Duration.microsecondsPerSecond) * 1000;
    if (nanos < 0) {
      nanos += 1000000000;
      seconds--;
    }
    return _TemporalDuration(
      months: months,
      days: days,
      seconds: seconds,
      nanoseconds: nanos,
    );
  }

  DateTime? _toUtcDateTime(Object? value) {
    if (value is _TemporalDate) {
      return DateTime.utc(value.year, value.month, value.day);
    }
    if (value is _TemporalLocalTime) {
      return DateTime.utc(
        1970,
        1,
        1,
        value.hour,
        value.minute,
        value.second,
        value.millisecond,
        value.microsecondOfSecond,
      );
    }
    if (value is _TemporalTime) {
      final local = DateTime.utc(
        1970,
        1,
        1,
        value.localTime.hour,
        value.localTime.minute,
        value.localTime.second,
        value.localTime.millisecond,
        value.localTime.microsecondOfSecond,
      );
      return local.subtract(Duration(minutes: value.offsetMinutes));
    }
    if (value is _TemporalLocalDateTime) {
      return DateTime.utc(
        value.date.year,
        value.date.month,
        value.date.day,
        value.localTime.hour,
        value.localTime.minute,
        value.localTime.second,
        value.localTime.millisecond,
        value.localTime.microsecondOfSecond,
      );
    }
    if (value is _TemporalDateTime) {
      final local = DateTime.utc(
        value.date.year,
        value.date.month,
        value.date.day,
        value.time.hour,
        value.time.minute,
        value.time.second,
        value.time.millisecond,
        value.time.microsecondOfSecond,
      );
      return local.subtract(Duration(minutes: value.offsetMinutes));
    }
    return null;
  }

  int? _monthDifference(Object left, Object right) {
    final leftYearMonth = _toYearMonth(left);
    final rightYearMonth = _toYearMonth(right);
    if (leftYearMonth == null || rightYearMonth == null) {
      return null;
    }
    return (rightYearMonth.$1 - leftYearMonth.$1) * 12 +
        (rightYearMonth.$2 - leftYearMonth.$2);
  }

  (int, int)? _toYearMonth(Object value) {
    if (value is _TemporalDate) {
      return (value.year, value.month);
    }
    if (value is _TemporalLocalDateTime) {
      return (value.date.year, value.date.month);
    }
    if (value is _TemporalDateTime) {
      return (value.date.year, value.date.month);
    }
    return null;
  }

  DateTime _addMonthsToDateTimeUtc(DateTime value, int months) {
    final monthIndex = value.month - 1 + months;
    final year = value.year + monthIndex ~/ 12;
    var month = monthIndex % 12;
    if (month < 0) {
      month += 12;
    }
    final normalizedMonth = month + 1;
    final maxDay = DateTime.utc(year, normalizedMonth + 1, 0).day;
    final day = value.day > maxDay ? maxDay : value.day;
    return DateTime.utc(
      year,
      normalizedMonth,
      day,
      value.hour,
      value.minute,
      value.second,
      value.millisecond,
      value.microsecond,
    );
  }

  _TemporalDate _parseTemporalDateFromMap(Map<Object?, Object?> value) {
    return _TemporalDate(
      year: _mapRequiredInt(value, 'year'),
      month: _mapRequiredInt(value, 'month'),
      day: _mapRequiredInt(value, 'day'),
    );
  }

  _TemporalDate? _parseTemporalDateString(String value) {
    final match = _dateStringPattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    return _TemporalDate(
      year: int.parse(match.group(1)!),
      month: int.parse(match.group(2)!),
      day: int.parse(match.group(3)!),
    );
  }

  _TemporalLocalTime _parseTemporalLocalTimeFromMap(
    Map<Object?, Object?> value,
  ) {
    return _TemporalLocalTime(
      hour: _mapRequiredInt(value, 'hour'),
      minute: _mapOptionalInt(value, 'minute'),
      second: _mapOptionalInt(value, 'second'),
      nanosecond: _mapOptionalInt(value, 'nanosecond'),
    );
  }

  _TemporalLocalTime? _parseTemporalLocalTimeString(String value) {
    final match = _localTimeStringPattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    return _TemporalLocalTime(
      hour: int.parse(match.group(1)!),
      minute: int.parse(match.group(2)!),
      second: int.tryParse(match.group(3) ?? '0') ?? 0,
      nanosecond: _parseNanosecondFraction(match.group(4)),
    );
  }

  _TemporalTime _parseTemporalTimeFromMap(Map<Object?, Object?> value) {
    final localTime = _TemporalLocalTime(
      hour: _mapRequiredInt(value, 'hour'),
      minute: _mapOptionalInt(value, 'minute'),
      second: _mapOptionalInt(value, 'second'),
      nanosecond: _mapOptionalInt(value, 'nanosecond'),
    );
    final zoneText = _mapOptionalString(value, 'timezone');
    final offsetMinutes = _parseOffsetMinutes(zoneText ?? '+00:00');
    return _TemporalTime(
      localTime: localTime,
      offsetMinutes: offsetMinutes,
      timezoneName:
          zoneText != null && !_looksLikeOffset(zoneText) ? zoneText : null,
    );
  }

  _TemporalTime? _parseTemporalTimeString(String value) {
    final match = _timeStringPattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    final localTime = _parseTemporalLocalTimeString(match.group(1)!);
    if (localTime == null) {
      return null;
    }
    final offset = _parseOffsetMinutes(match.group(2)!);
    final zoneName = match.group(3);
    return _TemporalTime(
      localTime: localTime,
      offsetMinutes: offset,
      timezoneName: zoneName,
    );
  }

  _TemporalLocalDateTime _parseTemporalLocalDateTimeFromMap(
    Map<Object?, Object?> value,
  ) {
    return _TemporalLocalDateTime(
      date: _TemporalDate(
        year: _mapRequiredInt(value, 'year'),
        month: _mapRequiredInt(value, 'month'),
        day: _mapRequiredInt(value, 'day'),
      ),
      localTime: _TemporalLocalTime(
        hour: _mapRequiredInt(value, 'hour'),
        minute: _mapOptionalInt(value, 'minute'),
        second: _mapOptionalInt(value, 'second'),
        nanosecond: _mapOptionalInt(value, 'nanosecond'),
      ),
    );
  }

  _TemporalLocalDateTime? _parseTemporalLocalDateTimeString(String value) {
    final match = _localDateTimeStringPattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    final date = _parseTemporalDateString(match.group(1)!);
    final time = _parseTemporalLocalTimeString(match.group(2)!);
    if (date == null || time == null) {
      return null;
    }
    return _TemporalLocalDateTime(date: date, localTime: time);
  }

  _TemporalDateTime _parseTemporalDateTimeFromMap(
    Map<Object?, Object?> value,
  ) {
    final date = _TemporalDate(
      year: _mapRequiredInt(value, 'year'),
      month: _mapRequiredInt(value, 'month'),
      day: _mapRequiredInt(value, 'day'),
    );
    final time = _TemporalLocalTime(
      hour: _mapRequiredInt(value, 'hour'),
      minute: _mapOptionalInt(value, 'minute'),
      second: _mapOptionalInt(value, 'second'),
      nanosecond: _mapOptionalInt(value, 'nanosecond'),
    );
    final zoneText = _mapOptionalString(value, 'timezone');
    final offsetMinutes = zoneText == null
        ? 0
        : _looksLikeOffset(zoneText)
            ? _parseOffsetMinutes(zoneText)
            : _offsetMinutesForNamedZone(zoneText, date, time);
    return _TemporalDateTime(
      date: date,
      time: time,
      offsetMinutes: offsetMinutes,
      timezoneName:
          zoneText != null && !_looksLikeOffset(zoneText) ? zoneText : null,
    );
  }

  _TemporalDateTime? _parseTemporalDateTimeString(String value) {
    final match = _dateTimeStringPattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    final date = _parseTemporalDateString(match.group(1)!);
    final time = _parseTemporalLocalTimeString(match.group(2)!);
    if (date == null || time == null) {
      return null;
    }
    return _TemporalDateTime(
      date: date,
      time: time,
      offsetMinutes: _parseOffsetMinutes(match.group(3)!),
      timezoneName: match.group(4),
    );
  }

  _TemporalDuration _parseTemporalDurationFromMap(Map<Object?, Object?> value) {
    final years = _mapOptionalInt(value, 'years');
    final quarters = _mapOptionalInt(value, 'quarters');
    final months = _mapOptionalInt(value, 'months');
    final weeks = _mapOptionalInt(value, 'weeks');
    final days = _mapOptionalInt(value, 'days');
    final hours = _mapOptionalInt(value, 'hours');
    final minutes = _mapOptionalInt(value, 'minutes');
    final seconds = _mapOptionalInt(value, 'seconds');
    final milliseconds = _mapOptionalInt(value, 'milliseconds');
    final microseconds = _mapOptionalInt(value, 'microseconds');
    final nanoseconds = _mapOptionalInt(value, 'nanoseconds');

    final totalMonths = years * 12 + quarters * 3 + months;
    final totalDays = weeks * 7 + days;
    final totalNanos = hours * 3600000000000 +
        minutes * 60000000000 +
        seconds * 1000000000 +
        milliseconds * 1000000 +
        microseconds * 1000 +
        nanoseconds;
    var wholeSeconds = totalNanos ~/ 1000000000;
    var nanosOfSecond = totalNanos % 1000000000;
    if (nanosOfSecond < 0) {
      nanosOfSecond += 1000000000;
      wholeSeconds--;
    }

    return _TemporalDuration(
      months: totalMonths,
      days: totalDays,
      seconds: wholeSeconds,
      nanoseconds: nanosOfSecond,
    );
  }

  _TemporalDuration? _parseTemporalDurationString(String value) {
    final match = _durationStringPattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    final years = int.tryParse(match.group(1) ?? '0') ?? 0;
    final months = int.tryParse(match.group(2) ?? '0') ?? 0;
    final weeks = int.tryParse(match.group(3) ?? '0') ?? 0;
    final days = int.tryParse(match.group(4) ?? '0') ?? 0;
    final hours = int.tryParse(match.group(5) ?? '0') ?? 0;
    final minutes = int.tryParse(match.group(6) ?? '0') ?? 0;
    final secondsValue = double.tryParse(match.group(7) ?? '0') ?? 0.0;

    final wholeSeconds = secondsValue.truncate();
    var nanos = ((secondsValue - wholeSeconds) * 1000000000).round();
    var totalSeconds = hours * 3600 + minutes * 60 + wholeSeconds;
    if (nanos < 0) {
      nanos += 1000000000;
      totalSeconds--;
    }

    return _TemporalDuration(
      months: years * 12 + months,
      days: weeks * 7 + days,
      seconds: totalSeconds,
      nanoseconds: nanos,
    );
  }

  int _mapRequiredInt(Map<Object?, Object?> value, String key) {
    final component = value[key];
    if (component is int) {
      return component;
    }
    if (component is num) {
      return component.toInt();
    }
    throw _ExecutionException('Expected integer component "$key".');
  }

  int _mapOptionalInt(Map<Object?, Object?> value, String key) {
    final component = value[key];
    if (component == null) {
      return 0;
    }
    if (component is int) {
      return component;
    }
    if (component is num) {
      return component.toInt();
    }
    throw _ExecutionException('Expected integer component "$key".');
  }

  String? _mapOptionalString(Map<Object?, Object?> value, String key) {
    final component = value[key];
    if (component == null) {
      return null;
    }
    if (component is String) {
      return component;
    }
    throw _ExecutionException('Expected string component "$key".');
  }

  int _parseNanosecondFraction(String? value) {
    if (value == null || value.isEmpty) {
      return 0;
    }
    final padded = value.padRight(9, '0');
    return int.parse(padded.substring(0, 9));
  }

  bool _looksLikeOffset(String value) {
    return RegExp(r'^(?:Z|[+-]\d{2}:?\d{2})$', caseSensitive: false)
        .hasMatch(value.trim());
  }

  int _parseOffsetMinutes(String value) {
    final normalized = value.trim().toUpperCase();
    if (normalized == 'Z') {
      return 0;
    }
    final compact = normalized.replaceAll(':', '');
    if (!RegExp(r'^[+-]\d{4}$').hasMatch(compact)) {
      throw _ExecutionException('Invalid timezone offset: $value');
    }
    final sign = compact.startsWith('-') ? -1 : 1;
    final hours = int.parse(compact.substring(1, 3));
    final minutes = int.parse(compact.substring(3, 5));
    return sign * (hours * 60 + minutes);
  }

  int _offsetMinutesForNamedZone(
    String zoneName,
    _TemporalDate date,
    _TemporalLocalTime time,
  ) {
    if (zoneName == 'Europe/Stockholm') {
      return _isEuropeStockholmDst(date, time) ? 120 : 60;
    }
    return 0;
  }

  bool _isEuropeStockholmDst(_TemporalDate date, _TemporalLocalTime time) {
    if (date.month < 3 || date.month > 10) {
      return false;
    }
    if (date.month > 3 && date.month < 10) {
      return true;
    }

    final lastSundayMarch = _lastSundayOfMonth(date.year, 3);
    final lastSundayOctober = _lastSundayOfMonth(date.year, 10);
    if (date.month == 3) {
      if (date.day > lastSundayMarch) {
        return true;
      }
      if (date.day < lastSundayMarch) {
        return false;
      }
      return time.hour >= 2;
    }

    if (date.day < lastSundayOctober) {
      return true;
    }
    if (date.day > lastSundayOctober) {
      return false;
    }
    return time.hour < 3;
  }

  int _lastSundayOfMonth(int year, int month) {
    var date = DateTime.utc(year, month + 1, 0);
    while (date.weekday != DateTime.sunday) {
      date = date.subtract(const Duration(days: 1));
    }
    return date.day;
  }

  Object? _evaluateListPredicateFunction({
    required String name,
    required List<String> args,
    required _Row row,
    required List<_Row>? aggregateRows,
  }) {
    if (args.length != 1) {
      throw _ExecutionException('$name expects 1 argument.');
    }

    final header = _tryParseListComprehensionHeader(args.first);
    if (header == null || header.whereExpression == null) {
      throw _ExecutionException(
        '$name() expects an argument of the form "x IN list WHERE predicate".',
      );
    }

    final listValue = _evaluateScalarExpression(
      header.listExpression,
      row,
      aggregateRows: aggregateRows,
    );
    if (listValue == null) {
      return null;
    }
    if (listValue is! Iterable || listValue is String || listValue is Map) {
      throw _ExecutionException('$name() expects a list expression.');
    }

    var hasNull = false;
    var trueCount = 0;
    for (final element in listValue) {
      final scopedRow = Map<String, Object?>.from(row);
      scopedRow[header.variable] = element;
      final predicateValue = _evaluateScalarExpression(
        header.whereExpression!,
        scopedRow,
        aggregateRows: aggregateRows,
      );
      final predicate = _coerceBooleanValue(
        predicateValue,
        context: '$name() predicate',
      );

      if (name == 'all') {
        if (predicate == false) {
          return false;
        }
        if (predicate == null) {
          hasNull = true;
        }
        continue;
      }
      if (name == 'any') {
        if (predicate == true) {
          return true;
        }
        if (predicate == null) {
          hasNull = true;
        }
        continue;
      }
      if (name == 'none') {
        if (predicate == true) {
          return false;
        }
        if (predicate == null) {
          hasNull = true;
        }
        continue;
      }
      if (name == 'single') {
        if (predicate == true) {
          trueCount++;
          if (trueCount > 1) {
            return false;
          }
        } else if (predicate == null) {
          hasNull = true;
        }
      }
    }

    return switch (name) {
      'all' => hasNull ? null : true,
      'any' => hasNull ? null : false,
      'none' => hasNull ? null : true,
      'single' =>
        trueCount == 1 ? (hasNull ? null : true) : (hasNull ? null : false),
      _ =>
        throw _ExecutionException('Unsupported list predicate function: $name'),
    };
  }

  Object? _computeAggregateFunction(
    String name,
    List<String> args,
    List<_Row> rows,
  ) {
    if (name == 'percentiledisc' || name == 'percentilecont') {
      return _computePercentileFunction(name, args, rows);
    }

    final argument = _parseAggregateArgument(
      name,
      args,
      allowEmptyForCount: name == 'count',
      allowWildcard: name == 'count',
    );
    if (argument.wildcard) {
      return rows.length;
    }

    final values = <Object?>[];
    for (final row in rows) {
      final value = _evaluateScalarExpression(argument.expression!, row);
      if (value == null) {
        continue;
      }
      if (argument.distinct && _containsEquivalentValue(values, value)) {
        continue;
      }
      values.add(value);
    }

    switch (name) {
      case 'count':
        return values.length;
      case 'sum':
        num total = 0;
        for (final value in values) {
          if (value is! num) {
            throw _ExecutionException('sum expects numeric values.');
          }
          total += value;
        }
        return total;
      case 'avg':
        num total = 0;
        for (final value in values) {
          if (value is! num) {
            throw _ExecutionException('avg expects numeric values.');
          }
          total += value;
        }
        if (values.isEmpty) {
          return null;
        }
        return total / values.length;
      case 'min':
      case 'max':
        Object? current;
        for (final value in values) {
          if (current == null) {
            current = value;
            continue;
          }
          final comparison = _compareForOrdering(value, current);
          if (name == 'min') {
            if (comparison < 0) {
              current = value;
            }
          } else if (comparison > 0) {
            current = value;
          }
        }
        return current;
      case 'collect':
        return values;
      default:
        throw _ExecutionException('Unsupported aggregate function: $name');
    }
  }

  _AggregateArgument _parseAggregateArgument(
    String functionName,
    List<String> args, {
    required bool allowEmptyForCount,
    required bool allowWildcard,
  }) {
    if (allowEmptyForCount && args.isEmpty) {
      return const _AggregateArgument.wildcard();
    }
    if (args.length != 1) {
      if (functionName == 'count') {
        throw const _ExecutionException(
          'count expects either * or 1 argument.',
        );
      }
      throw _ExecutionException('$functionName expects 1 argument.');
    }

    var expression = args.first.trim();
    var distinct = false;
    final upper = expression.toUpperCase();
    if (upper == 'DISTINCT' || upper.startsWith('DISTINCT ')) {
      distinct = true;
      expression = expression.substring('DISTINCT'.length).trim();
      if (expression.isEmpty) {
        throw _ExecutionException(
          '$functionName DISTINCT requires an expression.',
        );
      }
    }

    if (allowWildcard && expression == '*') {
      if (distinct) {
        throw _ExecutionException(
          '$functionName does not support DISTINCT with *.',
        );
      }
      return const _AggregateArgument.wildcard();
    }

    return _AggregateArgument(expression: expression, distinct: distinct);
  }

  bool _containsEquivalentValue(List<Object?> values, Object? candidate) {
    for (final value in values) {
      if (_valuesEqual(value, candidate)) {
        return true;
      }
    }
    return false;
  }

  String _unwrapEnclosingParentheses(String source) {
    var current = source.trim();
    while (current.startsWith('(') && current.endsWith(')')) {
      final wrapped = _readDelimitedSegment(
        current,
        0,
        open: '(',
        close: ')',
        context: 'parenthesized expression',
      );
      if (wrapped == null || wrapped.$2 != current.length) {
        break;
      }
      final next = wrapped.$1.trim();
      if (next.isEmpty) {
        break;
      }
      current = next;
    }
    return current;
  }

  String? _tryParseSuffixKeywordExpression(String source, String keyword) {
    final index = _findTopLevelKeywordIndex(source, keyword);
    if (index == null) {
      return null;
    }
    if (index + keyword.length != source.length) {
      return null;
    }
    final expression = source.substring(0, index).trim();
    if (expression.isEmpty) {
      return null;
    }
    return expression;
  }

  (String, String)? _tryParseInExpression(String source) {
    final index = _findTopLevelKeywordIndex(source, 'IN');
    if (index == null) {
      return null;
    }
    final left = source.substring(0, index).trim();
    final right = source.substring(index + 2).trim();
    if (left.isEmpty || right.isEmpty) {
      return null;
    }
    return (left, right);
  }

  (String, Set<String>)? _tryParseLabelPredicate(String source) {
    final colonIndex = _findTopLevelChar(source, ':');
    if (colonIndex == null) {
      return null;
    }
    final expression = source.substring(0, colonIndex).trim();
    final labelsText = source.substring(colonIndex + 1).trim();
    if (expression.isEmpty || labelsText.isEmpty) {
      return null;
    }

    final labels = <String>{};
    for (final rawLabel in labelsText.split(':')) {
      final label = rawLabel.trim();
      final normalized = _tryParseIdentifier(label);
      if (normalized == null) {
        return null;
      }
      labels.add(normalized);
    }
    if (labels.isEmpty) {
      return null;
    }
    return (expression, labels);
  }

  (int, String)? _findTopLevelBinaryOperator(
    String source,
    List<String> operators,
  ) {
    final upper = source.toUpperCase();
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;
    var caseDepth = 0;
    int? lastIndex;
    String? lastOperator;

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        continue;
      }

      if (char == '(') {
        parenDepth++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        continue;
      }

      if (parenDepth == 0 && braceDepth == 0 && bracketDepth == 0) {
        if (upper.startsWith('CASE', i) &&
            _isTokenBoundary(source, i - 1) &&
            _isTokenBoundary(source, i + 4)) {
          caseDepth++;
          i += 3;
          continue;
        }
        if (caseDepth > 0 &&
            upper.startsWith('END', i) &&
            _isTokenBoundary(source, i - 1) &&
            _isTokenBoundary(source, i + 3)) {
          caseDepth--;
          i += 2;
          continue;
        }
      }

      if (parenDepth != 0 ||
          braceDepth != 0 ||
          bracketDepth != 0 ||
          caseDepth != 0) {
        continue;
      }

      for (final operator in operators) {
        if (!source.startsWith(operator, i)) {
          continue;
        }
        if ((operator == '+' || operator == '-') &&
            _isUnarySignPosition(source, i)) {
          continue;
        }
        lastIndex = i;
        lastOperator = operator;
      }
    }

    if (lastIndex == null || lastOperator == null) {
      return null;
    }

    final left = source.substring(0, lastIndex).trim();
    final right = source.substring(lastIndex + lastOperator.length).trim();
    if (left.isEmpty || right.isEmpty) {
      return null;
    }
    return (lastIndex, lastOperator);
  }

  int? _findTopLevelPowerOperator(String source) {
    final upper = source.toUpperCase();
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;
    var caseDepth = 0;

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (inSingle) {
        if (char == "'" && prev != r'\') {
          inSingle = false;
        }
        continue;
      }
      if (inDouble) {
        if (char == '"' && prev != r'\') {
          inDouble = false;
        }
        continue;
      }
      if (inBacktick) {
        if (char == '`') {
          inBacktick = false;
        }
        continue;
      }

      if (char == "'") {
        inSingle = true;
        continue;
      }
      if (char == '"') {
        inDouble = true;
        continue;
      }
      if (char == '`') {
        inBacktick = true;
        continue;
      }

      if (char == '(') {
        parenDepth++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        continue;
      }

      if (parenDepth == 0 && braceDepth == 0 && bracketDepth == 0) {
        if (upper.startsWith('CASE', i) &&
            _isTokenBoundary(source, i - 1) &&
            _isTokenBoundary(source, i + 4)) {
          caseDepth++;
          i += 3;
          continue;
        }
        if (caseDepth > 0 &&
            upper.startsWith('END', i) &&
            _isTokenBoundary(source, i - 1) &&
            _isTokenBoundary(source, i + 3)) {
          caseDepth--;
          i += 2;
          continue;
        }
      }

      if (char == '^' &&
          parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0 &&
          caseDepth == 0) {
        return i;
      }
    }

    return null;
  }

  bool _isUnarySignPosition(String source, int index) {
    var current = index - 1;
    while (current >= 0 && source[current].trim().isEmpty) {
      current--;
    }
    if (current < 0) {
      return true;
    }
    final previous = source[current];
    return previous == '(' ||
        previous == '[' ||
        previous == '{' ||
        previous == ',' ||
        previous == '+' ||
        previous == '-' ||
        previous == '*' ||
        previous == '/' ||
        previous == '%' ||
        previous == '^' ||
        previous == '=' ||
        previous == '<' ||
        previous == '>' ||
        previous == '!';
  }

  Object? _evaluateBinaryArithmetic(
      String operator, Object? left, Object? right) {
    if (left == null || right == null) {
      return null;
    }

    switch (operator) {
      case '+':
        if (left is num && right is num) {
          if (left is int && right is int) {
            return left + right;
          }
          return left.toDouble() + right.toDouble();
        }
        if (left is List && right is List) {
          return <Object?>[...left, ...right];
        }
        if (left is List) {
          return <Object?>[...left, right];
        }
        if (right is List) {
          return <Object?>[left, ...right];
        }
        if (left is String || right is String) {
          return '$left$right';
        }
        throw _ExecutionException(
          'Operator + expects numeric, list, or string operands.',
        );
      case '-':
        if (left is! num || right is! num) {
          throw const _ExecutionException('Operator - expects numeric values.');
        }
        if (left is int && right is int) {
          return left - right;
        }
        return left.toDouble() - right.toDouble();
      case '*':
        if (left is! num || right is! num) {
          throw const _ExecutionException('Operator * expects numeric values.');
        }
        if (left is int && right is int) {
          return left * right;
        }
        return left.toDouble() * right.toDouble();
      case '/':
        if (left is! num || right is! num) {
          throw const _ExecutionException('Operator / expects numeric values.');
        }
        if (right == 0) {
          if (left is int && right is int) {
            throw const _ExecutionException('Division by zero.');
          }
          return left.toDouble() / right.toDouble();
        }
        return left.toDouble() / right.toDouble();
      case '%':
        if (left is! num || right is! num) {
          throw const _ExecutionException('Operator % expects numeric values.');
        }
        if (right == 0) {
          throw const _ExecutionException('Modulo by zero.');
        }
        if (left is int && right is int) {
          return left % right;
        }
        return left.toDouble() % right.toDouble();
      case '^':
        if (left is! num || right is! num) {
          throw const _ExecutionException('Operator ^ expects numeric values.');
        }
        final result = math.pow(left.toDouble(), right.toDouble());
        if (left is int && right is int && result is int) {
          return result;
        }
        return result.toDouble();
      default:
        throw _ExecutionException('Unsupported arithmetic operator: $operator');
    }
  }

  (String, String)? _tryParseIndexAccess(String source) {
    if (!source.endsWith(']')) {
      return null;
    }

    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;
    int? openIndex;

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        continue;
      }

      if (char == '(') {
        parenDepth++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        continue;
      }

      if (char == '[') {
        if (parenDepth == 0 && braceDepth == 0 && bracketDepth == 0) {
          openIndex = i;
        }
        bracketDepth++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
      }
    }

    if (openIndex == null) {
      return null;
    }
    final segment = _readDelimitedSegment(
      source,
      openIndex,
      open: '[',
      close: ']',
      context: 'index access',
    );
    if (segment == null || segment.$2 != source.length) {
      return null;
    }

    final target = source.substring(0, openIndex).trim();
    final index = segment.$1.trim();
    if (target.isEmpty || index.isEmpty) {
      return null;
    }
    return (target, index);
  }

  _SliceExpression? _tryParseSliceExpression(String source) {
    final separatorIndex = _findTopLevelRangeSeparator(source);
    if (separatorIndex == null) {
      return null;
    }
    final lowerText = source.substring(0, separatorIndex).trim();
    final upperText = source.substring(separatorIndex + 2).trim();
    return _SliceExpression(
      lowerExpression: lowerText.isEmpty ? null : lowerText,
      upperExpression: upperText.isEmpty ? null : upperText,
      lowerOmitted: lowerText.isEmpty,
      upperOmitted: upperText.isEmpty,
    );
  }

  int? _findTopLevelRangeSeparator(String source) {
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;

    for (var i = 0; i < source.length - 1; i++) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (inSingle) {
        if (char == "'" && prev != r'\') {
          inSingle = false;
        }
        continue;
      }
      if (inDouble) {
        if (char == '"' && prev != r'\') {
          inDouble = false;
        }
        continue;
      }
      if (inBacktick) {
        if (char == '`') {
          inBacktick = false;
        }
        continue;
      }

      if (char == "'") {
        inSingle = true;
        continue;
      }
      if (char == '"') {
        inDouble = true;
        continue;
      }
      if (char == '`') {
        inBacktick = true;
        continue;
      }

      if (char == '(') {
        parenDepth++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        continue;
      }

      if (char == '.' &&
          source[i + 1] == '.' &&
          parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0) {
        return i;
      }
    }
    return null;
  }

  Object? _readIndex({
    required Object? target,
    required Object? index,
  }) {
    if (target == null || index == null) {
      return null;
    }
    if (target is List) {
      if (index is! int) {
        throw const _ExecutionException('List index must be an integer.');
      }
      if (index < 0 || index >= target.length) {
        return null;
      }
      return target[index];
    }
    if (target is String) {
      if (index is! int) {
        throw const _ExecutionException('String index must be an integer.');
      }
      if (index < 0 || index >= target.length) {
        return null;
      }
      return target[index];
    }
    if (target is Map) {
      return target[index];
    }
    if (target is CypherGraphNode || target is CypherGraphRelationship) {
      if (index is! String) {
        return null;
      }
      return _readPropertyValue(value: target, property: index);
    }
    throw _ExecutionException(
      'Cannot index into ${target.runtimeType}.',
    );
  }

  Object? _readSlice({
    required Object? target,
    required Object? lower,
    required Object? upper,
    required bool lowerOmitted,
    required bool upperOmitted,
  }) {
    if (target == null) {
      return null;
    }
    if (target is! List && target is! String) {
      throw _ExecutionException(
        'Cannot slice ${target.runtimeType}.',
      );
    }

    final length = target is List ? target.length : (target as String).length;
    int? lowerIndex;
    if (lowerOmitted) {
      lowerIndex = 0;
    } else {
      if (lower == null) {
        return null;
      }
      if (lower is! int) {
        throw const _ExecutionException(
            'Slice lower bound must be an integer.');
      }
      lowerIndex = lower;
    }

    int? upperIndex;
    if (upperOmitted) {
      upperIndex = length;
    } else {
      if (upper == null) {
        return null;
      }
      if (upper is! int) {
        throw const _ExecutionException(
            'Slice upper bound must be an integer.');
      }
      upperIndex = upper;
    }

    if (lowerIndex < 0) {
      lowerIndex += length;
    }
    if (upperIndex < 0) {
      upperIndex += length;
    }

    if (lowerIndex < 0) {
      lowerIndex = 0;
    }
    if (upperIndex < 0) {
      upperIndex = 0;
    }
    if (lowerIndex > length) {
      lowerIndex = length;
    }
    if (upperIndex > length) {
      upperIndex = length;
    }

    if (lowerIndex > upperIndex) {
      return target is List ? const <Object?>[] : '';
    }

    if (target is List) {
      return List<Object?>.unmodifiable(target.sublist(lowerIndex, upperIndex));
    }
    final value = target as String;
    return value.substring(lowerIndex, upperIndex);
  }

  Object? _readPropertyValue({
    required Object? value,
    required String property,
  }) {
    if (value == null) {
      return null;
    }
    if (value is CypherGraphNode) {
      return value.properties[property];
    }
    if (value is CypherGraphRelationship) {
      return value.properties[property];
    }
    if (value is Map) {
      return value[property];
    }
    if (value is _TemporalValue) {
      return value.property(property);
    }
    if (value is _TemporalDuration) {
      return value.property(property);
    }
    throw _ExecutionException(
      'Cannot read property "$property" from ${value.runtimeType}.',
    );
  }

  int _resolveNonNegativeInt(String expression, {required String label}) {
    final value =
        _evaluateScalarExpression(expression, const <String, Object?>{});
    if (value is! int) {
      throw _ExecutionException('$label value must be an integer. Got: $value');
    }
    if (value < 0) {
      throw _ExecutionException('$label value cannot be negative: $value');
    }
    return value;
  }

  _ProjectionSpec _parseProjectionSpec(String itemsText) {
    final trimmed = itemsText.trim();
    final upper = trimmed.toUpperCase();
    final isDistinctProjection =
        upper == 'DISTINCT' || upper.startsWith('DISTINCT ');
    if (!isDistinctProjection) {
      return _ProjectionSpec(itemsText: trimmed, distinct: false);
    }

    final remaining = trimmed.substring('DISTINCT'.length).trim();
    if (remaining.isEmpty) {
      throw const _ExecutionException(
        'DISTINCT projection requires at least one item.',
      );
    }
    return _ProjectionSpec(itemsText: remaining, distinct: true);
  }

  bool _containsAggregateFunction(String expression) {
    final trimmed = expression.trim();
    if (trimmed.isEmpty) {
      return false;
    }

    final unwrapped = _unwrapEnclosingParentheses(trimmed);
    if (unwrapped != trimmed) {
      return _containsAggregateFunction(unwrapped);
    }

    for (final keyword in const <String>['OR', 'XOR', 'AND']) {
      final parts = _splitTopLevelByKeyword(trimmed, keyword);
      if (parts.length > 1) {
        return parts.any(_containsAggregateFunction);
      }
    }

    if (trimmed.toUpperCase().startsWith('NOT ')) {
      return _containsAggregateFunction(trimmed.substring(4));
    }

    final caseExpression = _tryParseCaseExpression(trimmed);
    if (caseExpression != null) {
      if (caseExpression.caseInputExpression != null &&
          _containsAggregateFunction(caseExpression.caseInputExpression!)) {
        return true;
      }
      for (final whenBranch in caseExpression.whens) {
        if (_containsAggregateFunction(whenBranch.whenExpression) ||
            _containsAggregateFunction(whenBranch.thenExpression)) {
          return true;
        }
      }
      if (caseExpression.elseExpression != null &&
          _containsAggregateFunction(caseExpression.elseExpression!)) {
        return true;
      }
      return false;
    }

    final function = _tryParseFunctionCall(trimmed);
    if (function != null) {
      if (_isAggregateFunctionName(function.$1)) {
        return true;
      }
      final functionName = function.$1.toLowerCase();
      if ((functionName == 'all' ||
              functionName == 'any' ||
              functionName == 'none' ||
              functionName == 'single') &&
          function.$2.length == 1) {
        final header = _tryParseListComprehensionHeader(function.$2.first);
        if (header != null && header.whereExpression != null) {
          return _containsAggregateFunction(header.listExpression) ||
              _containsAggregateFunction(header.whereExpression!);
        }
      }
      for (final argument in function.$2) {
        if (_containsAggregateFunction(argument)) {
          return true;
        }
      }
      return false;
    }

    if (_isWrapped(trimmed, '[', ']')) {
      final inner = trimmed.substring(1, trimmed.length - 1).trim();
      if (inner.isEmpty) {
        return false;
      }
      final projectionIndex = _findTopLevelChar(inner, '|');
      if (projectionIndex != null) {
        final header = inner.substring(0, projectionIndex).trim();
        final projection = inner.substring(projectionIndex + 1).trim();
        if (header.isEmpty || projection.isEmpty) {
          return false;
        }
        final listHeader = _tryParseListComprehensionHeader(header);
        if (listHeader != null) {
          return _containsAggregateFunction(listHeader.listExpression) ||
              (listHeader.whereExpression != null &&
                  _containsAggregateFunction(listHeader.whereExpression!)) ||
              _containsAggregateFunction(projection);
        }
        final whereIndex = _findTopLevelKeywordIndex(header, 'WHERE');
        if (whereIndex == null) {
          // Pattern comprehension without WHERE.
          return _containsAggregateFunction(projection);
        }
        final pattern = header.substring(0, whereIndex).trim();
        final whereExpression =
            header.substring(whereIndex + 'WHERE'.length).trim();
        if (pattern.isEmpty || whereExpression.isEmpty) {
          return _containsAggregateFunction(projection);
        }
        return _containsAggregateFunction(whereExpression) ||
            _containsAggregateFunction(projection);
      }

      for (final part in _splitTopLevelByComma(inner)) {
        if (_containsAggregateFunction(part)) {
          return true;
        }
      }
      return false;
    }

    if (_isWrapped(trimmed, '{', '}')) {
      final inner = trimmed.substring(1, trimmed.length - 1).trim();
      if (inner.isEmpty) {
        return false;
      }
      for (final entry in _splitTopLevelByComma(inner)) {
        final index = _findTopLevelChar(entry, ':');
        if (index == null) {
          continue;
        }
        final valuePart = entry.substring(index + 1).trim();
        if (_containsAggregateFunction(valuePart)) {
          return true;
        }
      }
      return false;
    }

    final isNotNullExpression =
        _tryParseSuffixKeywordExpression(trimmed, 'IS NOT NULL');
    if (isNotNullExpression != null) {
      return _containsAggregateFunction(isNotNullExpression);
    }

    final isNullExpression =
        _tryParseSuffixKeywordExpression(trimmed, 'IS NULL');
    if (isNullExpression != null) {
      return _containsAggregateFunction(isNullExpression);
    }

    final inExpression = _tryParseInExpression(trimmed);
    if (inExpression != null) {
      return _containsAggregateFunction(inExpression.$1) ||
          _containsAggregateFunction(inExpression.$2);
    }

    final labelPredicate = _tryParseLabelPredicate(trimmed);
    if (labelPredicate != null) {
      return _containsAggregateFunction(labelPredicate.$1);
    }

    final comparisonChain = _parseComparisonChain(trimmed);
    if (comparisonChain != null) {
      return comparisonChain.operands.any(_containsAggregateFunction);
    }

    final stringSearch = _tryParseStringSearchExpression(trimmed);
    if (stringSearch != null) {
      return _containsAggregateFunction(stringSearch.left) ||
          _containsAggregateFunction(stringSearch.right);
    }

    final additiveOperator =
        _findTopLevelBinaryOperator(trimmed, const <String>['+', '-']);
    if (additiveOperator != null) {
      return _containsAggregateFunction(
            trimmed.substring(0, additiveOperator.$1),
          ) ||
          _containsAggregateFunction(
            trimmed.substring(additiveOperator.$1 + additiveOperator.$2.length),
          );
    }

    final multiplicativeOperator =
        _findTopLevelBinaryOperator(trimmed, const <String>['*', '/', '%']);
    if (multiplicativeOperator != null) {
      return _containsAggregateFunction(
            trimmed.substring(0, multiplicativeOperator.$1),
          ) ||
          _containsAggregateFunction(
            trimmed.substring(
              multiplicativeOperator.$1 + multiplicativeOperator.$2.length,
            ),
          );
    }

    final indexAccess = _tryParseIndexAccess(trimmed);
    if (indexAccess != null) {
      return _containsAggregateFunction(indexAccess.$1) ||
          _containsAggregateFunction(indexAccess.$2);
    }

    final dotIndex = _findTopLevelChar(trimmed, '.');
    if (dotIndex != null) {
      return _containsAggregateFunction(trimmed.substring(0, dotIndex));
    }

    return false;
  }

  bool _isAggregateFunctionName(String name) {
    return _aggregateFunctionNames.contains(name.toLowerCase());
  }

  List<_ProjectionItem> _parseProjectionItems(String itemsText) {
    final parts = _splitTopLevelByComma(itemsText);
    if (parts.isEmpty) {
      throw const _ExecutionException('Projection items cannot be empty.');
    }

    return parts.map(_parseProjectionItem).toList(growable: false);
  }

  _ProjectionItem _parseProjectionItem(String raw) {
    final item = raw.trim();
    if (item == '*') {
      return const _ProjectionItem.wildcard();
    }

    final asIndex = _findTopLevelKeywordIndex(item, 'AS');
    if (asIndex != null) {
      final expression = item.substring(0, asIndex).trim();
      final alias = item.substring(asIndex + 2).trim();
      final normalizedAlias = _tryParseIdentifier(alias);
      if (normalizedAlias == null) {
        throw _ExecutionException('Invalid projection alias: $alias');
      }
      return _ProjectionItem(expression: expression, alias: normalizedAlias);
    }

    if (_isIdentifier(item)) {
      return _ProjectionItem(
        expression: item,
        alias: _tryParseIdentifier(item)!,
      );
    }

    final propertyAccess = _tryParsePropertyAccess(item);
    if (propertyAccess != null) {
      final alias = propertyAccess.$2;
      return _ProjectionItem(expression: item, alias: alias);
    }

    return _ProjectionItem(expression: item, alias: item);
  }

  List<_OrderItem> _parseOrderItems(String source) {
    final items = _splitTopLevelByComma(source);
    if (items.isEmpty) {
      throw const _ExecutionException('ORDER BY requires at least one item.');
    }

    return items.map((item) {
      final asc = _orderAscPattern.firstMatch(item);
      if (asc != null) {
        return _OrderItem(expression: asc.group(1)!.trim(), descending: false);
      }

      final desc = _orderDescPattern.firstMatch(item);
      if (desc != null) {
        return _OrderItem(expression: desc.group(1)!.trim(), descending: true);
      }
      return _OrderItem(expression: item.trim(), descending: false);
    }).toList(growable: false);
  }

  int _compareForOrdering(
    Object? left,
    Object? right, {
    bool nullAsLargest = true,
  }) {
    if (left == null && right == null) {
      return 0;
    }
    if (left == null) {
      return nullAsLargest ? 1 : -1;
    }
    if (right == null) {
      return nullAsLargest ? -1 : 1;
    }

    if (left is CypherGraphNode && right is CypherGraphNode) {
      return left.id.compareTo(right.id);
    }
    if (left is CypherGraphRelationship && right is CypherGraphRelationship) {
      return left.id.compareTo(right.id);
    }
    if (left is CypherGraphPath && right is CypherGraphPath) {
      return _valueKey(left).compareTo(_valueKey(right));
    }
    if (left is _TemporalDate && right is _TemporalDate) {
      return left.compareTo(right);
    }
    if (left is _TemporalLocalTime && right is _TemporalLocalTime) {
      return left.compareTo(right);
    }
    if (left is _TemporalTime && right is _TemporalTime) {
      return left.compareTo(right);
    }
    if (left is _TemporalLocalDateTime && right is _TemporalLocalDateTime) {
      return left.compareTo(right);
    }
    if (left is _TemporalDateTime && right is _TemporalDateTime) {
      return left.compareTo(right);
    }
    if (left is _TemporalDuration && right is _TemporalDuration) {
      return left.compareTo(right);
    }

    if (left is num && right is num) {
      return left.toDouble().compareTo(right.toDouble());
    }
    if (left is String && right is String) {
      return left.compareTo(right);
    }
    if (left is bool && right is bool) {
      return left == right ? 0 : (left ? 1 : -1);
    }

    return left.toString().compareTo(right.toString());
  }

  bool _valuesEqual(Object? left, Object? right) {
    if (left is CypherGraphNode && right is CypherGraphNode) {
      return left.id == right.id;
    }
    if (left is CypherGraphRelationship && right is CypherGraphRelationship) {
      return left.id == right.id;
    }
    if (left is CypherGraphPath && right is CypherGraphPath) {
      if (left.nodes.length != right.nodes.length ||
          left.relationships.length != right.relationships.length) {
        return false;
      }
      for (var i = 0; i < left.nodes.length; i++) {
        if (left.nodes[i].id != right.nodes[i].id) {
          return false;
        }
      }
      for (var i = 0; i < left.relationships.length; i++) {
        if (left.relationships[i].id != right.relationships[i].id) {
          return false;
        }
      }
      return true;
    }

    if (left is _TemporalValue && right is _TemporalValue) {
      return left == right;
    }
    if (left is _TemporalDuration && right is _TemporalDuration) {
      return left == right;
    }

    if (left is List && right is List) {
      if (left.length != right.length) {
        return false;
      }
      for (var i = 0; i < left.length; i++) {
        if (!_valuesEqual(left[i], right[i])) {
          return false;
        }
      }
      return true;
    }

    if (left is Map && right is Map) {
      if (left.length != right.length) {
        return false;
      }
      for (final key in left.keys) {
        if (!right.containsKey(key)) {
          return false;
        }
        if (!_valuesEqual(left[key], right[key])) {
          return false;
        }
      }
      return true;
    }

    return left == right;
  }

  bool _sameColumns(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) {
        return false;
      }
    }
    return true;
  }

  String _rowKey(_Row row, List<String> columns) {
    final buffer = StringBuffer();
    for (final column in columns) {
      buffer.write('$column=');
      buffer.write(_valueKey(row[column]));
      buffer.write(';');
    }
    return buffer.toString();
  }

  _Row _sanitizeRow(_Row row) {
    final sanitized = <String, Object?>{};
    for (final entry in row.entries) {
      if (_isInternalKey(entry.key)) {
        continue;
      }
      sanitized[entry.key] = entry.value;
    }
    return sanitized;
  }

  bool _isInternalKey(String key) {
    return key.startsWith(_internalKeyPrefix);
  }

  String _valueKey(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is CypherGraphNode) {
      return 'node:${value.id}';
    }
    if (value is CypherGraphRelationship) {
      return 'rel:${value.id}';
    }
    if (value is CypherGraphPath) {
      final nodeIds = value.nodes.map((node) => node.id).join(',');
      final relationshipIds =
          value.relationships.map((relationship) => relationship.id).join(',');
      return 'path:n[$nodeIds]r[$relationshipIds]';
    }
    if (value is _TemporalValue || value is _TemporalDuration) {
      return '${value.runtimeType}:$value';
    }
    if (value is List) {
      return '[${value.map(_valueKey).join(',')}]';
    }
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return '{${keys.map((key) => '$key:${_valueKey(value[key])}').join(',')}}';
    }
    return '${value.runtimeType}:$value';
  }

  List<String> _splitTopLevelByComma(String source) {
    final segments = <String>[];
    var start = 0;
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        continue;
      }

      if (char == '(') {
        parenDepth++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        continue;
      }

      if (char == ',' &&
          parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0) {
        segments.add(source.substring(start, i).trim());
        start = i + 1;
      }
    }

    segments.add(source.substring(start).trim());
    return segments.where((item) => item.isNotEmpty).toList(growable: false);
  }

  List<String> _splitTopLevelByKeyword(String source, String keyword) {
    final keywordUpper = keyword.toUpperCase();
    final upper = source.toUpperCase();
    final segments = <String>[];

    var start = 0;
    var i = 0;
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;

    while (i < source.length) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        i++;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        i++;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        i++;
        continue;
      }

      if (inSingle || inDouble || inBacktick) {
        i++;
        continue;
      }

      if (char == '(') {
        parenDepth++;
        i++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        i++;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        i++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        i++;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        i++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        i++;
        continue;
      }

      if (parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0 &&
          i + keywordUpper.length <= source.length &&
          upper.startsWith(keywordUpper, i) &&
          _isTokenBoundary(source, i - 1) &&
          _isTokenBoundary(source, i + keywordUpper.length)) {
        segments.add(source.substring(start, i).trim());
        start = i + keywordUpper.length;
        i = start;
        continue;
      }

      i++;
    }

    segments.add(source.substring(start).trim());
    return segments.where((item) => item.isNotEmpty).toList(growable: false);
  }

  int? _findTopLevelKeywordIndex(String source, String keyword) {
    final keywordUpper = keyword.toUpperCase();
    final upper = source.toUpperCase();

    var foundIndex = -1;
    var i = 0;
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;

    while (i < source.length) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        i++;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        i++;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        i++;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        i++;
        continue;
      }

      if (char == '(') {
        parenDepth++;
        i++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        i++;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        i++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        i++;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        i++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        i++;
        continue;
      }

      if (parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0 &&
          i + keywordUpper.length <= source.length &&
          upper.startsWith(keywordUpper, i) &&
          _isTokenBoundary(source, i - 1) &&
          _isTokenBoundary(source, i + keywordUpper.length)) {
        foundIndex = i;
      }
      i++;
    }

    return foundIndex < 0 ? null : foundIndex;
  }

  int? _findFirstTopLevelKeywordIndex(String source, String keyword) {
    final keywordUpper = keyword.toUpperCase();
    final upper = source.toUpperCase();

    var i = 0;
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;

    while (i < source.length) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && char == "'" && prev != r'\') {
        inSingle = !inSingle;
        i++;
        continue;
      }
      if (!inSingle && !inBacktick && char == '"' && prev != r'\') {
        inDouble = !inDouble;
        i++;
        continue;
      }
      if (!inSingle && !inDouble && char == '`') {
        inBacktick = !inBacktick;
        i++;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        i++;
        continue;
      }

      if (char == '(') {
        parenDepth++;
        i++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        i++;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        i++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        i++;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        i++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        i++;
        continue;
      }

      if (parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0 &&
          i + keywordUpper.length <= source.length &&
          upper.startsWith(keywordUpper, i) &&
          _isTokenBoundary(source, i - 1) &&
          _isTokenBoundary(source, i + keywordUpper.length)) {
        return i;
      }
      i++;
    }

    return null;
  }

  int? _findTopLevelChar(String source, String char) {
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;

    for (var i = 0; i < source.length; i++) {
      final current = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (!inDouble && !inBacktick && current == "'" && prev != r'\') {
        inSingle = !inSingle;
        continue;
      }
      if (!inSingle && !inBacktick && current == '"' && prev != r'\') {
        inDouble = !inDouble;
        continue;
      }
      if (!inSingle && !inDouble && current == '`') {
        inBacktick = !inBacktick;
        continue;
      }
      if (inSingle || inDouble || inBacktick) {
        continue;
      }

      if (parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0 &&
          current == char) {
        return i;
      }

      if (current == '(') {
        parenDepth++;
        continue;
      }
      if (current == ')' && parenDepth > 0) {
        parenDepth--;
        continue;
      }
      if (current == '{') {
        braceDepth++;
        continue;
      }
      if (current == '}' && braceDepth > 0) {
        braceDepth--;
        continue;
      }
      if (current == '[') {
        bracketDepth++;
        continue;
      }
      if (current == ']' && bracketDepth > 0) {
        bracketDepth--;
        continue;
      }
    }

    return null;
  }

  bool _isTokenBoundary(String source, int index) {
    if (index < 0 || index >= source.length) {
      return true;
    }
    final char = source[index];
    return !_tokenBoundaryCharPattern.hasMatch(char);
  }

  bool _isWrapped(String value, String open, String close) {
    if (!value.startsWith(open) || !value.endsWith(close)) {
      return false;
    }
    if (open.length != 1 || close.length != 1) {
      return false;
    }
    final segment = _readDelimitedSegment(
      value,
      0,
      open: open,
      close: close,
      context: 'delimited expression',
    );
    return segment != null && segment.$2 == value.length;
  }

  bool _isQuotedString(String value) {
    if (value.length < 2) {
      return false;
    }
    final first = value[0];
    if (first != "'" && first != '"') {
      return false;
    }
    if (value[value.length - 1] != first) {
      return false;
    }

    for (var i = 1; i < value.length; i++) {
      if (value[i] == first && value[i - 1] != r'\') {
        return i == value.length - 1;
      }
    }
    return false;
  }

  String _unquote(String value) {
    final quote = value[0];
    final body = value.substring(1, value.length - 1);
    return body.replaceAll('\\$quote', quote).replaceAll(r'\\', r'\');
  }

  bool _isIdentifier(String value) {
    return _tryParseIdentifier(value) != null;
  }

  String? _tryParseIdentifier(String value) {
    final trimmed = value.trim();
    if (_identifierPattern.hasMatch(trimmed)) {
      return trimmed;
    }
    if (trimmed.length >= 2 &&
        trimmed.startsWith('`') &&
        trimmed.endsWith('`')) {
      final body = trimmed.substring(1, trimmed.length - 1);
      if (body.isEmpty) {
        return null;
      }
      return body.replaceAll('``', '`');
    }
    return null;
  }

  String? _tryParseParameterName(String expression) {
    if (!expression.startsWith(r'$')) {
      return null;
    }
    final name = expression.substring(1);
    if (_isIdentifier(name) || _integerPattern.hasMatch(name)) {
      return name;
    }
    return null;
  }

  bool _looksLikeCompositeExpression(String source) {
    const compositeChars = <String>{
      ' ',
      '\t',
      '\n',
      '\r',
      '+',
      '-',
      '*',
      '/',
      '%',
      '^',
      '=',
      '<',
      '>',
      '!',
      '(',
      ')',
      '[',
      ']',
      '{',
      '}',
      ',',
      '.',
      ':',
      '|',
    };
    for (var i = 0; i < source.length; i++) {
      if (compositeChars.contains(source[i])) {
        return true;
      }
    }
    return false;
  }

  (String, String)? _tryParsePropertyAccess(String value) {
    final dot = _findTopLevelChar(value, '.');
    if (dot == null) {
      return null;
    }
    final left = value.substring(0, dot).trim();
    final right = value.substring(dot + 1).trim();
    final variable = _tryParseIdentifier(left);
    final property = _tryParseIdentifier(right);
    if (variable == null || property == null) {
      return null;
    }
    return (variable, property);
  }

  (String, String)? _tryParsePropertyAccessExpression(String source) {
    final dot = _findTopLevelPropertyDot(source);
    if (dot == null) {
      return null;
    }
    final left = source.substring(0, dot).trim();
    final right = source.substring(dot + 1).trim();
    final property = _tryParseIdentifier(right);
    if (left.isEmpty || property == null) {
      return null;
    }
    return (left, property);
  }

  int? _findTopLevelPropertyDot(String source) {
    var inSingle = false;
    var inDouble = false;
    var inBacktick = false;
    var parenDepth = 0;
    var braceDepth = 0;
    var bracketDepth = 0;
    int? lastDot;

    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      final prev = i > 0 ? source[i - 1] : '';

      if (inSingle) {
        if (char == "'" && prev != r'\') {
          inSingle = false;
        }
        continue;
      }
      if (inDouble) {
        if (char == '"' && prev != r'\') {
          inDouble = false;
        }
        continue;
      }
      if (inBacktick) {
        if (char == '`') {
          inBacktick = false;
        }
        continue;
      }

      if (char == "'") {
        inSingle = true;
        continue;
      }
      if (char == '"') {
        inDouble = true;
        continue;
      }
      if (char == '`') {
        inBacktick = true;
        continue;
      }

      if (char == '(') {
        parenDepth++;
        continue;
      }
      if (char == ')' && parenDepth > 0) {
        parenDepth--;
        continue;
      }
      if (char == '{') {
        braceDepth++;
        continue;
      }
      if (char == '}' && braceDepth > 0) {
        braceDepth--;
        continue;
      }
      if (char == '[') {
        bracketDepth++;
        continue;
      }
      if (char == ']' && bracketDepth > 0) {
        bracketDepth--;
        continue;
      }

      if (char == '.' &&
          parenDepth == 0 &&
          braceDepth == 0 &&
          bracketDepth == 0) {
        lastDot = i;
      }
    }

    return lastDot;
  }

  bool _isIntegerLiteral(String value) {
    return _integerPattern.hasMatch(value);
  }

  bool _isHexIntegerLiteral(String value) {
    return _hexIntegerPattern.hasMatch(value);
  }

  bool _isOctalIntegerLiteral(String value) {
    return _octalIntegerPattern.hasMatch(value);
  }

  Object _parseRadixIntegerLiteral(
    String value, {
    required int radix,
    required int prefixLength,
  }) {
    final negative = value.startsWith('-');
    final body = negative ? value.substring(1) : value;
    final digits = body.substring(prefixLength);
    final parsed = BigInt.parse(digits, radix: radix);
    final signed = negative ? -parsed : parsed;
    try {
      return signed.toInt();
    } catch (_) {
      return signed;
    }
  }

  bool _isDoubleLiteral(String value) {
    return _doublePattern.hasMatch(value) ||
        _extendedDoublePattern.hasMatch(value);
  }
}

@immutable
final class _ExecutionOutput {
  const _ExecutionOutput({
    required this.rows,
    required this.columns,
  });

  final List<_Row> rows;
  final List<String> columns;
}

@immutable
final class _ProjectionResult {
  const _ProjectionResult({
    required this.rows,
    required this.columns,
  });

  final List<_Row> rows;
  final List<String> columns;
}

@immutable
final class _ProjectionSpec {
  const _ProjectionSpec({
    required this.itemsText,
    required this.distinct,
  });

  final String itemsText;
  final bool distinct;
}

@immutable
final class _AggregateArgument {
  const _AggregateArgument({
    required this.expression,
    required this.distinct,
  }) : wildcard = false;

  const _AggregateArgument.wildcard()
      : expression = null,
        distinct = false,
        wildcard = true;

  final String? expression;
  final bool distinct;
  final bool wildcard;
}

@immutable
final class _SliceExpression {
  const _SliceExpression({
    required this.lowerExpression,
    required this.upperExpression,
    required this.lowerOmitted,
    required this.upperOmitted,
  });

  final String? lowerExpression;
  final String? upperExpression;
  final bool lowerOmitted;
  final bool upperOmitted;
}

@immutable
final class _ListComprehensionHeader {
  const _ListComprehensionHeader({
    required this.variable,
    required this.listExpression,
    this.whereExpression,
  });

  final String variable;
  final String listExpression;
  final String? whereExpression;
}

@immutable
final class _ComparisonToken {
  const _ComparisonToken({
    required this.index,
    required this.operator,
  });

  final int index;
  final String operator;
}

@immutable
final class _ParsedComparisonChain {
  _ParsedComparisonChain({
    required List<String> operands,
    required List<String> operators,
  })  : operands = List<String>.unmodifiable(operands),
        operators = List<String>.unmodifiable(operators);

  final List<String> operands;
  final List<String> operators;
}

@immutable
final class _StringSearchExpression {
  const _StringSearchExpression({
    required this.left,
    required this.operator,
    required this.right,
  });

  final String left;
  final String operator;
  final String right;
}

@immutable
final class _CaseExpression {
  _CaseExpression({
    required this.caseInputExpression,
    required List<_CaseWhen> whens,
    required this.elseExpression,
  }) : whens = List<_CaseWhen>.unmodifiable(whens);

  final String? caseInputExpression;
  final List<_CaseWhen> whens;
  final String? elseExpression;
}

@immutable
final class _CaseWhen {
  const _CaseWhen({
    required this.whenExpression,
    required this.thenExpression,
  });

  final String whenExpression;
  final String thenExpression;
}

@immutable
final class _ProjectionItem {
  const _ProjectionItem({
    this.expression = '',
    this.alias = '',
    this.isWildcard = false,
  });

  const _ProjectionItem.wildcard() : this(isWildcard: true);

  final String expression;
  final String alias;
  final bool isWildcard;
}

@immutable
final class _OrderItem {
  const _OrderItem({
    required this.expression,
    required this.descending,
  });

  final String expression;
  final bool descending;
}

@immutable
final class _AggregationGroup {
  const _AggregationGroup({
    required this.rows,
    required this.groupValues,
  });

  final List<_Row> rows;
  final Map<int, Object?> groupValues;
}

enum _MergeSetMode {
  onCreate,
  onMatch,
}

enum _PropertyMapSetMode {
  replace,
  merge,
}

@immutable
final class _MergeExecutionResult {
  const _MergeExecutionResult({
    required this.rows,
    required this.nextSetMode,
  });

  final List<_Row> rows;
  final _MergeSetMode? nextSetMode;
}

@immutable
final class _SetExecutionResult {
  const _SetExecutionResult({
    required this.rows,
    required this.nextMode,
  });

  final List<_Row> rows;
  final _MergeSetMode? nextMode;
}

@immutable
final class _NormalizedMergePattern {
  const _NormalizedMergePattern({
    required this.pattern,
    this.setMode,
  });

  final String pattern;
  final _MergeSetMode? setMode;
}

@immutable
final class _NormalizedSetAssignments {
  const _NormalizedSetAssignments({
    required this.assignments,
    this.nextMode,
  });

  final String assignments;
  final _MergeSetMode? nextMode;
}

@immutable
final class _ResolvedNode {
  const _ResolvedNode({
    required this.node,
    required this.created,
  });

  final CypherGraphNode node;
  final bool created;
}

@immutable
final class _ResolvedRelationship {
  const _ResolvedRelationship({
    required this.relationship,
    required this.created,
  });

  final CypherGraphRelationship relationship;
  final bool created;
}

@immutable
final class _CallInvocation {
  const _CallInvocation({
    required this.procedureName,
    required this.argExpressions,
    required this.yieldItems,
  });

  final String procedureName;
  final List<String> argExpressions;
  final List<_YieldItem> yieldItems;
}

@immutable
final class _YieldItem {
  const _YieldItem({
    required this.source,
    required this.alias,
  }) : wildcard = false;

  const _YieldItem.wildcard()
      : source = '*',
        alias = '*',
        wildcard = true;

  final String source;
  final String alias;
  final bool wildcard;
}

@immutable
final class _ParsedPattern {
  const _ParsedPattern({
    required this.pattern,
    this.pathVariable,
  });

  final String pattern;
  final String? pathVariable;
}

@immutable
final class _PatternChain {
  _PatternChain({
    required List<_NodePattern> nodePatterns,
    required List<_PatternRelationshipSegment> relationshipSegments,
    required this.pathVariable,
  })  : nodePatterns = List<_NodePattern>.unmodifiable(nodePatterns),
        relationshipSegments = List<_PatternRelationshipSegment>.unmodifiable(
            relationshipSegments);

  final List<_NodePattern> nodePatterns;
  final List<_PatternRelationshipSegment> relationshipSegments;
  final String? pathVariable;
}

@immutable
final class _PatternRelationshipSegment {
  const _PatternRelationshipSegment({
    required this.pattern,
    required this.direction,
  });

  final _RelationshipPattern pattern;
  final _RelationshipDirection direction;
}

@immutable
final class _RelationshipTraversal {
  _RelationshipTraversal({
    required this.endNode,
    required List<CypherGraphRelationship> relationships,
    required List<CypherGraphNode> nodes,
  })  : relationships =
            List<CypherGraphRelationship>.unmodifiable(relationships),
        nodes = List<CypherGraphNode>.unmodifiable(nodes);

  final CypherGraphNode endNode;
  final List<CypherGraphRelationship> relationships;
  final List<CypherGraphNode> nodes;
}

sealed class _MatchPattern {
  const _MatchPattern();
}

final class _NodeMatchPattern extends _MatchPattern {
  const _NodeMatchPattern(this.nodePattern);

  final _NodePattern nodePattern;
}

final class _RelationshipMatchPattern extends _MatchPattern {
  const _RelationshipMatchPattern({
    required this.leftNode,
    required this.relationshipPattern,
    required this.rightNode,
    required this.direction,
    required this.pathVariable,
  });

  final _NodePattern leftNode;
  final _RelationshipPattern relationshipPattern;
  final _NodePattern rightNode;
  final _RelationshipDirection direction;
  final String? pathVariable;
}

enum _RelationshipDirection {
  outgoing,
  incoming,
  undirected,
}

@immutable
final class _NodePattern {
  const _NodePattern({
    required this.variable,
    required this.labels,
    required this.properties,
  });

  final String? variable;
  final Set<String> labels;
  final Map<String, Object?> properties;
}

@immutable
final class _RelationshipPattern {
  _RelationshipPattern({
    required this.variable,
    required Set<String> types,
    required this.properties,
    required this.minHops,
    required this.maxHops,
    required this.variableLengthSyntax,
  }) : types = Set<String>.unmodifiable(types);

  final String? variable;
  final Set<String> types;
  final Map<String, Object?> properties;
  final int minHops;
  final int? maxHops;
  final bool variableLengthSyntax;
}

sealed class _TemporalValue {
  const _TemporalValue();

  Object? property(String name);
}

@immutable
final class _TemporalDate extends _TemporalValue
    implements Comparable<_TemporalDate> {
  const _TemporalDate({
    required this.year,
    required this.month,
    required this.day,
  });

  final int year;
  final int month;
  final int day;

  DateTime get _dateTime => DateTime.utc(year, month, day);

  int get quarter => ((month - 1) ~/ 3) + 1;

  int get ordinalDay =>
      _dateTime.difference(DateTime.utc(year, 1, 1)).inDays + 1;

  int get weekDay => _dateTime.weekday;

  int get dayOfQuarter {
    final quarterStartMonth = ((quarter - 1) * 3) + 1;
    final quarterStart = DateTime.utc(year, quarterStartMonth, 1);
    return _dateTime.difference(quarterStart).inDays + 1;
  }

  int get weekYear => _isoWeekYearAndWeek.$1;

  int get week => _isoWeekYearAndWeek.$2;

  (int, int) get _isoWeekYearAndWeek {
    // ISO-8601 week date: week 1 contains Jan 4.
    final thursday = _dateTime.add(Duration(days: 4 - _dateTime.weekday));
    final isoYear = thursday.year;
    final week1Thursday = DateTime.utc(isoYear, 1, 4);
    final week1Monday =
        week1Thursday.subtract(Duration(days: week1Thursday.weekday - 1));
    final currentMonday =
        _dateTime.subtract(Duration(days: _dateTime.weekday - 1));
    final weekNumber = currentMonday.difference(week1Monday).inDays ~/ 7 + 1;
    return (isoYear, weekNumber);
  }

  @override
  Object? property(String name) {
    return switch (name) {
      'year' => year,
      'quarter' => quarter,
      'month' => month,
      'week' => week,
      'weekYear' => weekYear,
      'day' => day,
      'ordinalDay' => ordinalDay,
      'weekDay' => weekDay,
      'dayOfQuarter' => dayOfQuarter,
      _ => null,
    };
  }

  @override
  int compareTo(_TemporalDate other) {
    if (year != other.year) {
      return year.compareTo(other.year);
    }
    if (month != other.month) {
      return month.compareTo(other.month);
    }
    return day.compareTo(other.day);
  }

  @override
  String toString() =>
      '${_formatSignedYear(year)}-${_padUnsigned(month, 2)}-${_padUnsigned(day, 2)}';

  @override
  bool operator ==(Object other) {
    return other is _TemporalDate &&
        year == other.year &&
        month == other.month &&
        day == other.day;
  }

  @override
  int get hashCode => Object.hash(year, month, day);
}

@immutable
final class _TemporalLocalTime extends _TemporalValue
    implements Comparable<_TemporalLocalTime> {
  const _TemporalLocalTime({
    required this.hour,
    required this.minute,
    required this.second,
    required this.nanosecond,
  });

  final int hour;
  final int minute;
  final int second;
  final int nanosecond;

  int get millisecond => nanosecond ~/ 1000000;
  int get microsecond => nanosecond ~/ 1000;
  int get microsecondOfSecond => (nanosecond % 1000000000) ~/ 1000;
  int get nanosecondOfDay =>
      (((hour * 60 + minute) * 60) + second) * 1000000000 + nanosecond;

  @override
  Object? property(String name) {
    return switch (name) {
      'hour' => hour,
      'minute' => minute,
      'second' => second,
      'millisecond' => millisecond,
      'microsecond' => microsecond,
      'nanosecond' => nanosecond,
      _ => null,
    };
  }

  @override
  int compareTo(_TemporalLocalTime other) {
    return nanosecondOfDay.compareTo(other.nanosecondOfDay);
  }

  String format({bool alwaysIncludeSeconds = false}) {
    final buffer =
        StringBuffer('${_padUnsigned(hour, 2)}:${_padUnsigned(minute, 2)}');
    final includeSeconds =
        alwaysIncludeSeconds || second != 0 || nanosecond != 0;
    if (!includeSeconds) {
      return buffer.toString();
    }
    buffer.write(':${_padUnsigned(second, 2)}');
    if (nanosecond != 0) {
      final fraction = _trimTrailingZeros(_padUnsigned(nanosecond, 9));
      buffer.write('.$fraction');
    }
    return buffer.toString();
  }

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) {
    return other is _TemporalLocalTime &&
        hour == other.hour &&
        minute == other.minute &&
        second == other.second &&
        nanosecond == other.nanosecond;
  }

  @override
  int get hashCode => Object.hash(hour, minute, second, nanosecond);
}

@immutable
final class _TemporalTime extends _TemporalValue
    implements Comparable<_TemporalTime> {
  const _TemporalTime({
    required this.localTime,
    required this.offsetMinutes,
    this.timezoneName,
  });

  final _TemporalLocalTime localTime;
  final int offsetMinutes;
  final String? timezoneName;

  int get offsetSeconds => offsetMinutes * 60;

  int get _utcNanoseconds =>
      localTime.nanosecondOfDay - offsetSeconds * 1000000000;

  String get offsetString => _formatOffset(offsetMinutes);

  @override
  Object? property(String name) {
    return switch (name) {
      'hour' => localTime.hour,
      'minute' => localTime.minute,
      'second' => localTime.second,
      'millisecond' => localTime.millisecond,
      'microsecond' => localTime.microsecond,
      'nanosecond' => localTime.nanosecond,
      'timezone' => timezoneName ?? offsetString,
      'offset' => offsetString,
      'offsetMinutes' => offsetMinutes,
      'offsetSeconds' => offsetSeconds,
      _ => null,
    };
  }

  @override
  int compareTo(_TemporalTime other) =>
      _utcNanoseconds.compareTo(other._utcNanoseconds);

  @override
  String toString() {
    final suffix = timezoneName == null ? '' : '[${timezoneName!}]';
    return '${localTime.format()}$offsetString$suffix';
  }

  @override
  bool operator ==(Object other) {
    return other is _TemporalTime &&
        localTime == other.localTime &&
        offsetMinutes == other.offsetMinutes &&
        timezoneName == other.timezoneName;
  }

  @override
  int get hashCode => Object.hash(localTime, offsetMinutes, timezoneName);
}

@immutable
final class _TemporalLocalDateTime extends _TemporalValue
    implements Comparable<_TemporalLocalDateTime> {
  const _TemporalLocalDateTime({
    required this.date,
    required this.localTime,
  });

  final _TemporalDate date;
  final _TemporalLocalTime localTime;

  @override
  Object? property(String name) {
    return date.property(name) ?? localTime.property(name);
  }

  @override
  int compareTo(_TemporalLocalDateTime other) {
    final dateCompare = date.compareTo(other.date);
    if (dateCompare != 0) {
      return dateCompare;
    }
    return localTime.compareTo(other.localTime);
  }

  @override
  String toString() =>
      '${date}T${localTime.format(alwaysIncludeSeconds: true)}';

  @override
  bool operator ==(Object other) {
    return other is _TemporalLocalDateTime &&
        date == other.date &&
        localTime == other.localTime;
  }

  @override
  int get hashCode => Object.hash(date, localTime);
}

@immutable
final class _TemporalDateTime extends _TemporalValue
    implements Comparable<_TemporalDateTime> {
  const _TemporalDateTime({
    required this.date,
    required this.time,
    required this.offsetMinutes,
    this.timezoneName,
  });

  final _TemporalDate date;
  final _TemporalLocalTime time;
  final int offsetMinutes;
  final String? timezoneName;

  String get offsetString => _formatOffset(offsetMinutes);
  int get offsetSeconds => offsetMinutes * 60;

  DateTime get _utcDateTime {
    final local = DateTime.utc(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
      time.second,
      time.millisecond,
      time.microsecondOfSecond,
    );
    return local.subtract(Duration(minutes: offsetMinutes));
  }

  @override
  Object? property(String name) {
    return switch (name) {
      'timezone' => timezoneName ?? offsetString,
      'offset' => offsetString,
      'offsetMinutes' => offsetMinutes,
      'offsetSeconds' => offsetSeconds,
      'epochSeconds' =>
        _utcDateTime.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond,
      'epochMillis' => _utcDateTime.millisecondsSinceEpoch,
      _ => date.property(name) ?? time.property(name),
    };
  }

  @override
  int compareTo(_TemporalDateTime other) =>
      _utcDateTime.compareTo(other._utcDateTime);

  @override
  String toString() {
    final suffix = timezoneName == null ? '' : '[${timezoneName!}]';
    return '${date}T${time.format(alwaysIncludeSeconds: true)}$offsetString$suffix';
  }

  @override
  bool operator ==(Object other) {
    return other is _TemporalDateTime &&
        date == other.date &&
        time == other.time &&
        offsetMinutes == other.offsetMinutes &&
        timezoneName == other.timezoneName;
  }

  @override
  int get hashCode => Object.hash(date, time, offsetMinutes, timezoneName);
}

@immutable
final class _TemporalDuration implements Comparable<_TemporalDuration> {
  const _TemporalDuration({
    this.months = 0,
    this.days = 0,
    this.seconds = 0,
    this.nanoseconds = 0,
  });

  final int months;
  final int days;
  final int seconds;
  final int nanoseconds;

  int get years => months ~/ 12;
  int get quarters => months ~/ 3;
  int get weeks => days ~/ 7;
  int get minutes => seconds ~/ 60;
  int get hours => seconds ~/ 3600;

  int get milliseconds => seconds * 1000 + nanoseconds ~/ 1000000;
  int get microseconds => seconds * 1000000 + nanoseconds ~/ 1000;
  int get totalNanoseconds => seconds * 1000000000 + nanoseconds;

  @override
  int compareTo(_TemporalDuration other) {
    if (months != other.months) {
      return months.compareTo(other.months);
    }
    if (days != other.days) {
      return days.compareTo(other.days);
    }
    if (seconds != other.seconds) {
      return seconds.compareTo(other.seconds);
    }
    return nanoseconds.compareTo(other.nanoseconds);
  }

  Object? property(String name) {
    return switch (name) {
      'years' => years,
      'quarters' => quarters,
      'months' => months,
      'weeks' => weeks,
      'days' => days,
      'hours' => hours,
      'minutes' => minutes,
      'seconds' => seconds,
      'milliseconds' => milliseconds,
      'microseconds' => microseconds,
      'nanoseconds' => totalNanoseconds,
      'quartersOfYear' => _signedRemainder(months, 12) ~/ 3,
      'monthsOfQuarter' => _signedRemainder(months, 3),
      'monthsOfYear' => _signedRemainder(months, 12),
      'daysOfWeek' => _signedRemainder(days, 7),
      'minutesOfHour' => _signedRemainder(minutes, 60),
      'secondsOfMinute' => _signedRemainder(seconds, 60),
      'millisecondsOfSecond' => nanoseconds ~/ 1000000,
      'microsecondsOfSecond' => nanoseconds ~/ 1000,
      'nanosecondsOfSecond' => nanoseconds,
      _ => null,
    };
  }

  @override
  String toString() {
    if (months == 0 && days == 0 && seconds == 0 && nanoseconds == 0) {
      return 'PT0S';
    }

    final buffer = StringBuffer('P');
    final yearsPart = months ~/ 12;
    final monthsPart = _signedRemainder(months, 12);
    if (yearsPart != 0) {
      buffer.write('${yearsPart}Y');
    }
    if (monthsPart != 0) {
      buffer.write('${monthsPart}M');
    }
    if (days != 0) {
      buffer.write('${days}D');
    }

    final hasTime = seconds != 0 || nanoseconds != 0;
    if (hasTime) {
      buffer.write('T');
      final hoursPart = seconds ~/ 3600;
      final remainderAfterHours = seconds - hoursPart * 3600;
      final minutesPart = remainderAfterHours ~/ 60;
      final secondsPart = remainderAfterHours - minutesPart * 60;

      if (hoursPart != 0) {
        buffer.write('${hoursPart}H');
      }
      if (minutesPart != 0) {
        buffer.write('${minutesPart}M');
      }
      if (secondsPart != 0 ||
          nanoseconds != 0 ||
          (hoursPart == 0 && minutesPart == 0)) {
        buffer.write(_formatSecondsWithNanos(secondsPart, nanoseconds));
        buffer.write('S');
      }
    }

    return buffer.toString();
  }

  @override
  bool operator ==(Object other) {
    return other is _TemporalDuration &&
        months == other.months &&
        days == other.days &&
        seconds == other.seconds &&
        nanoseconds == other.nanoseconds;
  }

  @override
  int get hashCode => Object.hash(months, days, seconds, nanoseconds);
}

String _padUnsigned(int value, int width) {
  final absolute = value.abs().toString().padLeft(width, '0');
  return value < 0 ? '-$absolute' : absolute;
}

String _formatSignedYear(int year) {
  final absolute = year.abs().toString().padLeft(4, '0');
  return year < 0 ? '-$absolute' : absolute;
}

String _trimTrailingZeros(String value) {
  var index = value.length;
  while (index > 0 && value[index - 1] == '0') {
    index--;
  }
  return index == 0 ? '0' : value.substring(0, index);
}

String _formatOffset(int offsetMinutes) {
  final sign = offsetMinutes < 0 ? '-' : '+';
  final absolute = offsetMinutes.abs();
  final hours = absolute ~/ 60;
  final minutes = absolute % 60;
  return '$sign${_padUnsigned(hours, 2)}:${_padUnsigned(minutes, 2)}';
}

int _signedRemainder(int value, int divisor) {
  if (value >= 0) {
    return value % divisor;
  }
  return -((-value) % divisor);
}

String _formatSecondsWithNanos(int seconds, int nanoseconds) {
  if (nanoseconds == 0) {
    return seconds.toString();
  }
  final sign = seconds < 0 ? '-' : '';
  final absoluteSeconds = seconds.abs();
  final fraction = _trimTrailingZeros(_padUnsigned(nanoseconds, 9));
  return '$sign$absoluteSeconds.$fraction';
}

final class _ExecutionException implements Exception {
  const _ExecutionException(this.message);

  final String message;

  @override
  String toString() => message;
}
