import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('format output can be parsed again', () {
    const input = 'MATCH (n)   RETURN   n  ORDER   BY n.name  LIMIT  3';

    final first = Cypher.parse(input);
    expect(first.hasErrors, isFalse);

    final formatted = CypherPrinter.format(first.document!);
    final second = Cypher.parse(formatted);

    expect(second.hasErrors, isFalse);
    expect(second.document, isNotNull);
  });
}
