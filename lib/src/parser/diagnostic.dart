import 'package:meta/meta.dart';
import 'package:source_span/source_span.dart';

/// The severity level for a [CypherDiagnostic].
enum DiagnosticSeverity {
  /// Informational message.
  info,

  /// Warning-level message.
  warning,

  /// Error-level message.
  error,
}

/// A parser or validation diagnostic with location metadata.
@immutable
final class CypherDiagnostic {
  /// Creates a diagnostic.
  const CypherDiagnostic({
    required this.code,
    required this.message,
    required this.severity,
    required this.span,
  });

  /// The stable diagnostic code, such as `CYP101`.
  final String code;

  /// The human-readable diagnostic message.
  final String message;

  /// The diagnostic severity.
  final DiagnosticSeverity severity;

  /// The source range associated with this diagnostic.
  final SourceSpan span;

  /// Whether this diagnostic is an error.
  bool get isError => severity == DiagnosticSeverity.error;

  @override
  String toString() {
    return '$code [$severity] $message @ ${span.start.line + 1}:${span.start.column + 1}';
  }
}
