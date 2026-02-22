import 'package:cypher_dart/opencypher.dart';
import 'package:source_span/source_span.dart';
import 'package:test/test.dart';

SourceSpan _span() {
  final file = SourceFile.fromString('x', url: Uri.parse('memory:test.cypher'));
  return file.span(0, 1);
}

void main() {
  test('serializes document and all clause variants to JSON', () {
    final span = _span();
    final statement = CypherQueryStatement(
      span: span,
      clauses: <CypherClause>[
        MatchClause(span: span, pattern: '(n)'),
        MatchClause(span: span, pattern: '(m)', optional: true),
        WhereClause(span: span, expression: 'n.age > 1'),
        WithClause(span: span, items: 'n'),
        ReturnClause(span: span, items: 'n'),
        OrderByClause(span: span, items: 'n'),
        LimitClause(span: span, value: '1'),
        SkipClause(span: span, value: '0'),
        CreateClause(span: span, pattern: '(a)'),
        MergeClause(span: span, pattern: '(a)'),
        SetClause(span: span, assignments: 'a.x = 1'),
        RemoveClause(span: span, items: 'a.x'),
        DeleteClause(span: span, items: 'a'),
        DeleteClause(span: span, items: 'a', detach: true),
        UnwindClause(span: span, items: '[1] AS x'),
        CallClause(span: span, invocation: 'db.labels()'),
        UnionClause(span: span, queryPart: ''),
        UnionClause(span: span, queryPart: 'RETURN n', all: true),
      ],
    );
    final document = CypherDocument(
      span: span,
      statements: <CypherStatement>[statement],
    );

    final json = cypherNodeToJson(document);

    expect(json['type'], 'CypherDocument');
    final statements = json['statements'] as List<Object?>;
    expect(statements, hasLength(1));

    final queryJson = statements.single as Map<String, Object?>;
    expect(queryJson['type'], 'CypherQueryStatement');
    final clauses = queryJson['clauses'] as List<Object?>;
    expect(clauses, hasLength(18));

    final keywords = clauses
        .cast<Map<String, Object?>>()
        .map((clause) => clause['keyword'])
        .toList(growable: false);
    expect(
      keywords,
      containsAll(<String>[
        'MATCH',
        'OPTIONAL MATCH',
        'WHERE',
        'WITH',
        'RETURN',
        'ORDER BY',
        'LIMIT',
        'SKIP',
        'CREATE',
        'MERGE',
        'SET',
        'REMOVE',
        'DELETE',
        'DETACH DELETE',
        'UNWIND',
        'CALL',
        'UNION',
        'UNION ALL',
      ]),
    );

    final detachDelete = clauses
        .cast<Map<String, Object?>>()
        .singleWhere((clause) => clause['keyword'] == 'DETACH DELETE');
    expect(detachDelete['detach'], isTrue);
  });
}
