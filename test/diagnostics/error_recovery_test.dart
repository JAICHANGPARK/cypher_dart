import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('recoverErrors false returns null document on syntax error', () {
    final result = Cypher.parse('WHERE n.age > 30 RETURN n');

    expect(result.hasErrors, isTrue);
    expect(result.document, isNull);
    expect(result.diagnostics.any((d) => d.code.startsWith('CYP')), isTrue);
  });

  test('recoverErrors true keeps partial document', () {
    final result = Cypher.parse(
      'WHERE n.age > 30 RETURN n',
      options: const CypherParseOptions(recoverErrors: true),
    );

    expect(result.hasErrors, isTrue);
    expect(result.document, isNotNull);
  });
}
