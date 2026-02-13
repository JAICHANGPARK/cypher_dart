import 'ast_builder.dart';
import 'diagnostic.dart';
import 'error_listener.dart';
import 'lexer_parser.dart';
import 'options.dart';
import 'parse_result.dart';
import 'source_mapper.dart';

abstract final class Cypher {
  static CypherParseResult parse(
    String query, {
    CypherParseOptions options = const CypherParseOptions(),
  }) {
    final mapper = SourceMapper(query);
    final errors = CypherErrorCollector(mapper);

    try {
      final extensionDiagnostics = _detectExtensionDiagnostics(
        query,
        mapper,
        options,
      );

      if (extensionDiagnostics.isNotEmpty) {
        errors.diagnostics.addAll(extensionDiagnostics);
        if (!options.recoverErrors) {
          return CypherParseResult(
            document: null,
            diagnostics: errors.diagnostics,
          );
        }
      }

      final lexed = lexCypher(
        query: query,
        errors: errors,
      );
      final built = AstBuilder(mapper: mapper, errors: errors).build(lexed);

      final hasErrors =
          errors.diagnostics.any((diagnostic) => diagnostic.isError);
      final document =
          !options.recoverErrors && hasErrors ? null : built.document;

      return CypherParseResult(
          document: document, diagnostics: errors.diagnostics);
    } catch (error) {
      errors.addInternal(message: 'Unhandled parse failure: $error');
      return CypherParseResult(document: null, diagnostics: errors.diagnostics);
    }
  }
}

List<CypherDiagnostic> _detectExtensionDiagnostics(
  String query,
  SourceMapper mapper,
  CypherParseOptions options,
) {
  if (options.dialect == CypherDialect.neo4j5) {
    return const <CypherDiagnostic>[];
  }

  final diagnostics = <CypherDiagnostic>[];

  void addIfUnsupported({
    required RegExp pattern,
    required CypherFeature feature,
    required String code,
    required String message,
  }) {
    if (options.isFeatureEnabled(feature)) {
      return;
    }

    final match = pattern.firstMatch(query);
    if (match == null) {
      return;
    }

    diagnostics.add(
      CypherDiagnostic(
        code: code,
        message: message,
        severity: DiagnosticSeverity.error,
        span: mapper.span(match.start, match.end),
      ),
    );
  }

  addIfUnsupported(
    pattern: RegExp(r'\bEXISTS\s*\{', caseSensitive: false),
    feature: CypherFeature.neo4jExistsSubquery,
    code: 'CYP201',
    message: 'Neo4j EXISTS { ... } subquery syntax is disabled in strict mode.',
  );

  addIfUnsupported(
    pattern: RegExp(
      r'\bCALL\s*\{[\s\S]*?\}\s*IN\s+TRANSACTIONS\b',
      caseSensitive: false,
      dotAll: true,
    ),
    feature: CypherFeature.neo4jCallSubqueryInTransactions,
    code: 'CYP202',
    message: 'CALL { ... } IN TRANSACTIONS is disabled in strict mode.',
  );

  addIfUnsupported(
    pattern: RegExp(r'\[[^\]]+\|[^\]]+\]'),
    feature: CypherFeature.neo4jPatternComprehension,
    code: 'CYP203',
    message: 'Pattern comprehension is disabled in strict mode.',
  );

  addIfUnsupported(
    pattern: RegExp(r'\bUSE\s+', caseSensitive: false),
    feature: CypherFeature.neo4jUseClause,
    code: 'CYP204',
    message: 'USE clause is disabled in strict mode.',
  );

  return diagnostics;
}
