import 'package:meta/meta.dart';
import 'package:source_span/source_span.dart';

enum DiagnosticSeverity {
  info,
  warning,
  error,
}

@immutable
final class CypherDiagnostic {
  const CypherDiagnostic({
    required this.code,
    required this.message,
    required this.severity,
    required this.span,
  });

  final String code;
  final String message;
  final DiagnosticSeverity severity;
  final SourceSpan span;

  bool get isError => severity == DiagnosticSeverity.error;

  @override
  String toString() {
    return '$code [$severity] $message @ ${span.start.line + 1}:${span.start.column + 1}';
  }
}
