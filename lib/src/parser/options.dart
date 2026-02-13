import 'package:meta/meta.dart';

enum CypherDialect {
  openCypher9,
  neo4j5,
}

enum CypherFeature {
  neo4jExistsSubquery,
  neo4jCallSubqueryInTransactions,
  neo4jPatternComprehension,
  neo4jUseClause,
}

@immutable
final class CypherParseOptions {
  const CypherParseOptions({
    this.dialect = CypherDialect.openCypher9,
    this.enabledFeatures = const <CypherFeature>{},
    this.recoverErrors = false,
  });

  final CypherDialect dialect;
  final Set<CypherFeature> enabledFeatures;
  final bool recoverErrors;

  bool isFeatureEnabled(CypherFeature feature) {
    if (dialect == CypherDialect.neo4j5) {
      return true;
    }
    return enabledFeatures.contains(feature);
  }
}
