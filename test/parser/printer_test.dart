import 'package:cypher_dart/opencypher.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';

SourceSpan _span() {
  final file =
      SourceFile.fromString('x', url: Uri.parse('memory:printer.cypher'));
  return file.span(0, 1);
}

void main() {
  test('formats clauses with canonical keyword style and spacing', () {
    final span = _span();
    final first = CypherQueryStatement(
      span: span,
      clauses: <CypherClause>[
        MatchClause(span: span, pattern: ' (n) '),
        MatchClause(span: span, pattern: ' (m) ', optional: true),
        WhereClause(span: span, expression: 'n.age\t>\n1'),
        WithClause(span: span, items: 'n'),
        ReturnClause(span: span, items: 'n'),
        OrderByClause(span: span, items: ' n.name   DESC '),
        LimitClause(span: span, value: ' 5 '),
        SkipClause(span: span, value: ' 1 '),
        CreateClause(span: span, pattern: ' (a) '),
        MergeClause(span: span, pattern: ' (a) '),
        SetClause(span: span, assignments: 'a.age = 30'),
        RemoveClause(span: span, items: 'a.age'),
        DeleteClause(span: span, items: 'a'),
        DeleteClause(span: span, items: 'b', detach: true),
        UnwindClause(span: span, items: '[1, 2] AS x'),
        CallClause(span: span, invocation: 'db.labels()'),
        UnionClause(span: span, queryPart: ''),
        UnionClause(span: span, queryPart: ' RETURN n ', all: true),
      ],
    );
    final second = CypherQueryStatement(
      span: span,
      clauses: <CypherClause>[
        ReturnClause(span: span, items: ' 1 AS n '),
      ],
    );
    final document = CypherDocument(
      span: span,
      statements: <CypherStatement>[first, second],
    );

    final formatted = CypherPrinter.format(document);

    expect(
      formatted,
      contains('WHERE n.age > 1'),
    );
    expect(formatted, contains('UNION\nUNION ALL RETURN n'));
    expect(formatted, contains('DETACH DELETE b'));
    expect(formatted, contains(';\nRETURN 1 AS n'));
  });

  test('formats empty document as empty text', () {
    final span = _span();
    final document = CypherDocument(
      span: span,
      statements: const <CypherStatement>[],
    );

    expect(CypherPrinter.format(document), isEmpty);
  });
}
