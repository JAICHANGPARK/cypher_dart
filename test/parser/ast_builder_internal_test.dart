import 'package:cypher_dart/opencypher.dart';
import 'package:cypher_dart/src/parser/ast_builder.dart';
import 'package:cypher_dart/src/parser/error_listener.dart';
import 'package:cypher_dart/src/parser/lexer_parser.dart';
import 'package:cypher_dart/src/parser/source_mapper.dart';
import 'package:test/test.dart';

void main() {
  test('reports duplicate RETURN in one statement', () {
    final result = Cypher.parse(
      'RETURN 1 AS a RETURN 2 AS b',
      options: const CypherParseOptions(recoverErrors: true),
    );

    expect(result.diagnostics.any((d) => d.code == 'CYP302'), isTrue);
  });

  test('reports ordering violations for WHERE, ORDER BY, LIMIT and UNION', () {
    final where = Cypher.parse(
      'RETURN 1 AS a WHERE a = 1',
      options: const CypherParseOptions(recoverErrors: true),
    );
    final orderBy = Cypher.parse(
      'MATCH (n) ORDER BY n',
      options: const CypherParseOptions(recoverErrors: true),
    );
    final limit = Cypher.parse(
      'MATCH (n) LIMIT 1',
      options: const CypherParseOptions(recoverErrors: true),
    );
    final union = Cypher.parse(
      'MATCH (n) UNION RETURN n',
      options: const CypherParseOptions(recoverErrors: true),
    );

    expect(where.diagnostics.any((d) => d.code == 'CYP300'), isTrue);
    expect(orderBy.diagnostics.any((d) => d.code == 'CYP300'), isTrue);
    expect(limit.diagnostics.any((d) => d.code == 'CYP300'), isTrue);
    expect(union.diagnostics.any((d) => d.code == 'CYP300'), isTrue);
  });

  test('falls back with CYP101 for unsupported clause keyword', () {
    final source = 'FOO 1';
    final mapper = SourceMapper(source);
    final errors = CypherErrorCollector(mapper);
    final output = LexParseOutput(
      statements: <LexedStatement>[
        const LexedStatement(
          start: 0,
          end: 5,
          clauses: <LexedClause>[
            LexedClause(
              keyword: 'FOO',
              body: '1',
              start: 0,
              end: 5,
            ),
          ],
        ),
      ],
    );

    final result = AstBuilder(mapper: mapper, errors: errors).build(output);

    expect(result.document, isNotNull);
    expect(errors.diagnostics.any((d) => d.code == 'CYP101'), isTrue);
  });
}
