import 'package:meta/meta.dart';

import '../ast/nodes.dart';
import 'diagnostic.dart';

/// The result of parsing a Cypher query.
@immutable
final class CypherParseResult {
  /// Creates a parse result.
  CypherParseResult({
    required this.document,
    required List<CypherDiagnostic> diagnostics,
  }) : diagnostics = List<CypherDiagnostic>.unmodifiable(diagnostics);

  /// The parsed document when parsing succeeded.
  ///
  /// This can be `null` when parsing fails in fail-fast mode.
  final CypherDocument? document;

  /// The diagnostics collected during parsing and validation.
  final List<CypherDiagnostic> diagnostics;

  /// Whether any diagnostic has error severity.
  bool get hasErrors => diagnostics.any((diagnostic) => diagnostic.isError);
}
