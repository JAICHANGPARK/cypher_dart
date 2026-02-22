import 'package:meta/meta.dart';

/// The parser behavior profile used while parsing Cypher text.
enum CypherDialect {
  /// Strict OpenCypher-oriented parsing and validation behavior.
  openCypher9,

  /// Neo4j-oriented parsing behavior with extension support enabled.
  neo4j5,
}

/// Optional syntax extensions that can be enabled in strict mode.
enum CypherFeature {
  /// Enables `EXISTS { ... }` subquery syntax.
  neo4jExistsSubquery,

  /// Enables `CALL { ... } IN TRANSACTIONS` syntax.
  neo4jCallSubqueryInTransactions,

  /// Enables pattern comprehension syntax.
  neo4jPatternComprehension,

  /// Enables the `USE` clause.
  neo4jUseClause,
}

/// Configuration for [Cypher.parse].
@immutable
final class CypherParseOptions {
  /// Creates parser options.
  ///
  /// The [dialect] controls default extension behavior. The [enabledFeatures]
  /// set enables individual extensions when running in strict mode. When
  /// [recoverErrors] is `true`, parsing continues after recoverable errors.
  const CypherParseOptions({
    this.dialect = CypherDialect.openCypher9,
    this.enabledFeatures = const <CypherFeature>{},
    this.recoverErrors = false,
  });

  /// The parsing dialect profile.
  final CypherDialect dialect;

  /// The explicit extension allow-list in strict mode.
  final Set<CypherFeature> enabledFeatures;

  /// Whether parsing should continue after recoverable errors.
  final bool recoverErrors;

  /// Whether [feature] is currently enabled.
  ///
  /// Returns `true` for all features when [dialect] is [CypherDialect.neo4j5].
  bool isFeatureEnabled(CypherFeature feature) {
    if (dialect == CypherDialect.neo4j5) {
      return true;
    }
    return enabledFeatures.contains(feature);
  }
}
