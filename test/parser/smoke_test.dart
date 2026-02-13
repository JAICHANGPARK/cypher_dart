import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('parses basic MATCH WHERE RETURN ORDER BY LIMIT', () {
    final result = Cypher.parse(
      'MATCH (n:Person) WHERE n.age > 30 RETURN n.name AS name ORDER BY name LIMIT 5',
    );

    expect(result.hasErrors, isFalse);
    expect(result.document, isNotNull);

    final statement =
        result.document!.statements.single as CypherQueryStatement;
    expect(statement.clauses.whereType<MatchClause>().single.pattern,
        '(n:Person)');
    expect(statement.clauses.whereType<ReturnClause>().single.items,
        'n.name AS name');
  });
}
