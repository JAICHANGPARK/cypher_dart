import 'package:meta/meta.dart';

import '../ast/nodes.dart';
import 'diagnostic.dart';

@immutable
final class CypherParseResult {
  CypherParseResult({
    required this.document,
    required List<CypherDiagnostic> diagnostics,
  }) : diagnostics = List<CypherDiagnostic>.unmodifiable(diagnostics);

  final CypherDocument? document;
  final List<CypherDiagnostic> diagnostics;

  bool get hasErrors => diagnostics.any((diagnostic) => diagnostic.isError);
}
