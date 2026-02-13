import 'package:cypher_dart/opencypher.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const CypherLabApp());
}

class CypherLabApp extends StatelessWidget {
  const CypherLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cypher Lab',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const CypherLabPage(),
    );
  }
}

class CypherLabPage extends StatefulWidget {
  const CypherLabPage({super.key});

  @override
  State<CypherLabPage> createState() => _CypherLabPageState();
}

class _CypherLabPageState extends State<CypherLabPage> {
  final _controller = TextEditingController(
    text: 'MATCH (n:Person) RETURN n.name AS name ORDER BY name LIMIT 5',
  );

  CypherParseResult _result = Cypher.parse(
    'MATCH (n:Person) RETURN n.name AS name ORDER BY name LIMIT 5',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _runParse() {
    setState(() {
      _result = Cypher.parse(
        _controller.text,
        options: const CypherParseOptions(recoverErrors: true),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = _result.diagnostics;
    final formatted =
        _result.document == null ? '' : CypherPrinter.format(_result.document!);

    return Scaffold(
      appBar: AppBar(title: const Text('Cypher Lab')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Cypher query',
              ),
              onChanged: (_) => _runParse(),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _runParse,
              child: const Text('Parse'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: ListView(
                          children: [
                            const Text('Diagnostics',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            if (diagnostics.isEmpty)
                              const Text('No diagnostics')
                            else
                              for (final d in diagnostics)
                                Text(
                                    '${d.code} ${d.severity.name}: ${d.message}'),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: ListView(
                          children: [
                            const Text('Formatted',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            SelectableText(formatted),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
