import 'ast_builder.dart';
import 'diagnostic.dart';
import 'error_listener.dart';
import 'lexer_parser.dart';
import 'options.dart';
import 'parse_result.dart';
import 'source_mapper.dart';

/// Entry point for parsing Cypher queries.
abstract final class Cypher {
  /// Parses [query] into a [CypherParseResult].
  ///
  /// Parsing behavior is controlled by [options]. In fail-fast mode
  /// (`recoverErrors: false`), [CypherParseResult.document] is `null` when
  /// errors are present.
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

  if (!options.isFeatureEnabled(CypherFeature.neo4jPatternComprehension)) {
    final patternComprehensionSpan = _findPatternComprehensionSpan(query);
    if (patternComprehensionSpan != null) {
      diagnostics.add(
        CypherDiagnostic(
          code: 'CYP203',
          message: 'Pattern comprehension is disabled in strict mode.',
          severity: DiagnosticSeverity.error,
          span: mapper.span(
            patternComprehensionSpan.$1,
            patternComprehensionSpan.$2,
          ),
        ),
      );
    }
  }

  addIfUnsupported(
    pattern: RegExp(r'\bUSE\s+', caseSensitive: false),
    feature: CypherFeature.neo4jUseClause,
    code: 'CYP204',
    message: 'USE clause is disabled in strict mode.',
  );

  return diagnostics;
}

(int, int)? _findPatternComprehensionSpan(String query) {
  final bracketStack = <int>[];

  var inSingle = false;
  var inDouble = false;
  var inBacktick = false;

  for (var i = 0; i < query.length; i++) {
    final char = query[i];
    final prev = i > 0 ? query[i - 1] : '';

    if (!inDouble && !inBacktick && char == "'" && prev != '\\') {
      inSingle = !inSingle;
      continue;
    }

    if (!inSingle && !inBacktick && char == '"' && prev != '\\') {
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

    if (char == '[') {
      bracketStack.add(i);
      continue;
    }

    if (char == ']' && bracketStack.isNotEmpty) {
      final start = bracketStack.removeLast();
      final content = query.substring(start + 1, i);
      if (_isLikelyPatternComprehension(content)) {
        return (start, i + 1);
      }
    }
  }

  return null;
}

bool _isLikelyPatternComprehension(String content) {
  final barIndex = content.indexOf('|');
  if (barIndex < 0) {
    return false;
  }

  final left = content.substring(0, barIndex);
  if (RegExp(r'\bIN\b', caseSensitive: false).hasMatch(left)) {
    return false;
  }

  if (!left.contains('(')) {
    return false;
  }
  if (!left.contains('-')) {
    return false;
  }
  return true;
}
