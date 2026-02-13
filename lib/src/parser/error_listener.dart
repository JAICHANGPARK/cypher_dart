import 'diagnostic.dart';
import 'source_mapper.dart';

final class CypherErrorCollector {
  CypherErrorCollector(this.mapper);

  final SourceMapper mapper;
  final List<CypherDiagnostic> _diagnostics = <CypherDiagnostic>[];

  List<CypherDiagnostic> get diagnostics => _diagnostics;

  void add({
    required String code,
    required String message,
    required DiagnosticSeverity severity,
    required int start,
    required int end,
  }) {
    _diagnostics.add(
      CypherDiagnostic(
        code: code,
        message: message,
        severity: severity,
        span: mapper.span(start, end),
      ),
    );
  }

  void addSyntax({
    required String message,
    required int start,
    required int end,
  }) {
    add(
      code: 'CYP100',
      message: message,
      severity: DiagnosticSeverity.error,
      start: start,
      end: end,
    );
  }

  void addSemantic({
    required String code,
    required String message,
    required int start,
    required int end,
  }) {
    add(
      code: code,
      message: message,
      severity: DiagnosticSeverity.error,
      start: start,
      end: end,
    );
  }

  void addInternal({required String message}) {
    add(
      code: 'CYP900',
      message: message,
      severity: DiagnosticSeverity.error,
      start: 0,
      end: 0,
    );
  }
}
