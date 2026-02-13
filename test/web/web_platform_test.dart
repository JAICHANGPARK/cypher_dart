// ignore_for_file: unnecessary_library_name

@TestOn('browser')
library web_platform_test;

import 'package:cypher_dart/opencypher.dart';
import 'package:test/test.dart';

void main() {
  test('parser works on browser platform', () {
    final result = Cypher.parse('MATCH (n) RETURN n');
    expect(result.hasErrors, isFalse);
    expect(result.document, isNotNull);
  });
}
