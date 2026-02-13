import 'package:cypher_dart/opencypher.dart';

void main() {
  const query = '''
MATCH (n:Person)
WHERE n.age > 30
RETURN n.name AS name
ORDER BY name
LIMIT 5
''';

  final result = Cypher.parse(query);

  if (result.hasErrors) {
    for (final diagnostic in result.diagnostics) {
      // ignore: avoid_print
      print(diagnostic);
    }
    return;
  }

  final document = result.document!;
  // ignore: avoid_print
  print(CypherPrinter.format(document));
}
