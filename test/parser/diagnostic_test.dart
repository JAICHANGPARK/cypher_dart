import 'package:cypher_dart/opencypher.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';

SourceSpan _span() {
  final file =
      SourceFile.fromString('a\nb', url: Uri.parse('memory:diag.cypher'));
  return file.span(2, 3);
}

void main() {
  test('reports isError only for error severity', () {
    final span = _span();
    final info = CypherDiagnostic(
      code: 'I',
      message: 'info',
      severity: DiagnosticSeverity.info,
      span: span,
    );
    final warning = CypherDiagnostic(
      code: 'W',
      message: 'warning',
      severity: DiagnosticSeverity.warning,
      span: span,
    );
    final error = CypherDiagnostic(
      code: 'E',
      message: 'error',
      severity: DiagnosticSeverity.error,
      span: span,
    );

    expect(info.isError, isFalse);
    expect(warning.isError, isFalse);
    expect(error.isError, isTrue);
  });

  test('formats diagnostic as a readable string', () {
    final diagnostic = CypherDiagnostic(
      code: 'CYP123',
      message: 'Something went wrong',
      severity: DiagnosticSeverity.error,
      span: _span(),
    );

    final text = diagnostic.toString();
    expect(text, contains('CYP123 [DiagnosticSeverity.error]'));
    expect(text, contains('Something went wrong'));
    expect(text, contains('@ 2:1'));
  });
}
