import 'package:cypher_dart/src/parser/diagnostic.dart';
import 'package:cypher_dart/src/parser/error_listener.dart';
import 'package:cypher_dart/src/parser/source_mapper.dart';
import 'package:test/test.dart';

void main() {
  test('maps offsets safely with SourceMapper', () {
    final mapper = SourceMapper('abc');

    final clamped = mapper.span(-10, 99);
    expect(clamped.start.offset, 0);
    expect(clamped.end.offset, 3);

    final empty = mapper.emptySpanAt(2);
    expect(empty.start.offset, 2);
    expect(empty.end.offset, 2);
  });

  test('collects syntax, semantic, and internal diagnostics', () {
    final collector = CypherErrorCollector(SourceMapper('MATCH (n)'));

    collector.add(
      code: 'CYP001',
      message: 'custom',
      severity: DiagnosticSeverity.warning,
      start: 0,
      end: 5,
    );
    collector.addSyntax(message: 'syntax', start: 1, end: 2);
    collector.addSemantic(
      code: 'CYP301',
      message: 'semantic',
      start: 2,
      end: 3,
    );
    collector.addInternal(message: 'internal');

    final diagnostics = collector.diagnostics;
    expect(diagnostics, hasLength(4));
    expect(diagnostics[0].code, 'CYP001');
    expect(diagnostics[0].severity, DiagnosticSeverity.warning);
    expect(diagnostics[1].code, 'CYP100');
    expect(diagnostics[2].code, 'CYP301');
    expect(diagnostics[3].code, 'CYP900');
    expect(diagnostics[3].span.start.offset, 0);
    expect(diagnostics[3].span.end.offset, 0);
  });
}
