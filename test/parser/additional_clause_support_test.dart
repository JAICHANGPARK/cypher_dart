import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('parses UNWIND clause', () {
    final result = Cypher.parse('UNWIND [1, 2, 3] AS n RETURN n');

    expect(result.hasErrors, isFalse);
    expect(result.document, isNotNull);

    final statement =
        result.document!.statements.single as CypherQueryStatement;
    expect(statement.clauses.first, isA<UnwindClause>());
    expect((statement.clauses.first as UnwindClause).items, '[1, 2, 3] AS n');
  });

  test('parses standalone CALL clause', () {
    final result = Cypher.parse('CALL test.doNothing()');

    expect(result.hasErrors, isFalse);
    expect(result.document, isNotNull);

    final statement =
        result.document!.statements.single as CypherQueryStatement;
    expect(statement.clauses.single, isA<CallClause>());
    expect((statement.clauses.single as CallClause).invocation,
        'test.doNothing()');
  });

  test('parses UNION between query parts', () {
    final result = Cypher.parse('RETURN 1 AS n UNION RETURN 2 AS n');

    expect(result.hasErrors, isFalse);
    expect(result.document, isNotNull);

    final statement =
        result.document!.statements.single as CypherQueryStatement;
    expect(
      statement.clauses.whereType<UnionClause>().single.all,
      isFalse,
    );
  });

  test('parses DETACH DELETE clause', () {
    final result = Cypher.parse('MATCH (n) DETACH DELETE n');

    expect(result.hasErrors, isFalse);
    expect(result.document, isNotNull);

    final statement =
        result.document!.statements.single as CypherQueryStatement;
    final delete = statement.clauses.last as DeleteClause;
    expect(delete.detach, isTrue);
    expect(delete.keyword, 'DETACH DELETE');
    expect(delete.items, 'n');
  });
}
