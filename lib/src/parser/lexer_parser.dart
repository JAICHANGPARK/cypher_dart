import 'error_listener.dart';

final class LexedClause {
  const LexedClause({
    required this.keyword,
    required this.body,
    required this.start,
    required this.end,
  });

  final String keyword;
  final String body;
  final int start;
  final int end;
}

final class LexedStatement {
  const LexedStatement({
    required this.start,
    required this.end,
    required this.clauses,
  });

  final int start;
  final int end;
  final List<LexedClause> clauses;
}

final class LexParseOutput {
  const LexParseOutput({required this.statements});

  final List<LexedStatement> statements;
}

const List<String> _keywords = <String>[
  'OPTIONAL MATCH',
  'ORDER BY',
  'MATCH',
  'WHERE',
  'WITH',
  'RETURN',
  'CREATE',
  'MERGE',
  'SET',
  'REMOVE',
  'DELETE',
  'LIMIT',
  'SKIP',
];

final RegExp _keywordPattern = RegExp(
  r'\bOPTIONAL\s+MATCH\b|\bORDER\s+BY\b|\bMATCH\b|\bWHERE\b|\bWITH\b|\bRETURN\b|\bCREATE\b|\bMERGE\b|\bSET\b|\bREMOVE\b|\bDELETE\b|\bLIMIT\b|\bSKIP\b',
  caseSensitive: false,
);

LexParseOutput lexCypher({
  required String query,
  required CypherErrorCollector errors,
}) {
  final statementSpans = _splitStatements(query);
  final statements = <LexedStatement>[];

  for (final span in statementSpans) {
    final statementText = query.substring(span.$1, span.$2);
    if (statementText.trim().isEmpty) {
      continue;
    }

    final clauses = _extractClauses(
      statementText,
      absoluteStart: span.$1,
      errors: errors,
    );

    if (clauses.isNotEmpty) {
      statements.add(
        LexedStatement(
          start: clauses.first.start,
          end: clauses.last.end,
          clauses: clauses,
        ),
      );
    }
  }

  if (statements.isEmpty &&
      query.trim().isNotEmpty &&
      errors.diagnostics.isEmpty) {
    errors.addSyntax(
      message: 'Could not locate any recognizable Cypher clauses.',
      start: 0,
      end: query.length,
    );
  }

  return LexParseOutput(statements: statements);
}

List<(int, int)> _splitStatements(String query) {
  final spans = <(int, int)>[];
  var start = 0;

  var inSingle = false;
  var inDouble = false;
  var inBacktick = false;
  var parenDepth = 0;
  var braceDepth = 0;
  var bracketDepth = 0;

  for (var i = 0; i < query.length; i++) {
    final char = query[i];
    final prev = i > 0 ? query[i - 1] : '';

    if (!inDouble && !inBacktick && char == "'" && prev != '\\') {
      inSingle = !inSingle;
      continue;
    }

    if (!inSingle && !inBacktick && char == '"' && prev != '\\') {
      inDouble = !inDouble;
      continue;
    }

    if (!inSingle && !inDouble && char == '`') {
      inBacktick = !inBacktick;
      continue;
    }

    if (inSingle || inDouble || inBacktick) {
      continue;
    }

    if (char == '(') {
      parenDepth++;
      continue;
    }
    if (char == ')' && parenDepth > 0) {
      parenDepth--;
      continue;
    }
    if (char == '{') {
      braceDepth++;
      continue;
    }
    if (char == '}' && braceDepth > 0) {
      braceDepth--;
      continue;
    }
    if (char == '[') {
      bracketDepth++;
      continue;
    }
    if (char == ']' && bracketDepth > 0) {
      bracketDepth--;
      continue;
    }

    if (char == ';' &&
        parenDepth == 0 &&
        braceDepth == 0 &&
        bracketDepth == 0) {
      spans.add((start, i));
      start = i + 1;
    }
  }

  spans.add((start, query.length));
  return spans;
}

List<LexedClause> _extractClauses(
  String statement, {
  required int absoluteStart,
  required CypherErrorCollector errors,
}) {
  final quotedMask = _quotedMask(statement);
  final matches = <RegExpMatch>[];

  for (final match in _keywordPattern.allMatches(statement)) {
    if (match.start < quotedMask.length && quotedMask[match.start]) {
      continue;
    }

    matches.add(match);
  }

  if (matches.isEmpty) {
    errors.addSyntax(
      message: 'Statement does not contain a known Cypher clause keyword.',
      start: absoluteStart,
      end: absoluteStart + statement.length,
    );
    return const <LexedClause>[];
  }

  final leading = statement.substring(0, matches.first.start);
  if (leading.trim().isNotEmpty) {
    errors.addSyntax(
      message: 'Unexpected tokens before first clause: "${leading.trim()}".',
      start: absoluteStart,
      end: absoluteStart + matches.first.start,
    );
  }

  final clauses = <LexedClause>[];
  for (var i = 0; i < matches.length; i++) {
    final current = matches[i];
    final next = i + 1 < matches.length ? matches[i + 1] : null;

    final keyword = _normalizeKeyword(current.group(0)!);
    if (!_keywords.contains(keyword)) {
      continue;
    }

    final bodyStart = current.end;
    final bodyEnd = next?.start ?? statement.length;
    final body = statement.substring(bodyStart, bodyEnd).trim();

    final clauseStart = absoluteStart + current.start;
    final clauseEnd = absoluteStart + bodyEnd;

    if (body.isEmpty) {
      errors.addSyntax(
        message: 'Clause "$keyword" is missing a body expression.',
        start: clauseStart,
        end: clauseEnd,
      );
    }

    clauses.add(
      LexedClause(
        keyword: keyword,
        body: body,
        start: clauseStart,
        end: clauseEnd,
      ),
    );
  }

  return clauses;
}

List<bool> _quotedMask(String source) {
  final mask = List<bool>.filled(source.length, false);

  var inSingle = false;
  var inDouble = false;
  var inBacktick = false;

  for (var i = 0; i < source.length; i++) {
    final char = source[i];
    final prev = i > 0 ? source[i - 1] : '';

    if (!inDouble && !inBacktick && char == "'" && prev != '\\') {
      inSingle = !inSingle;
      mask[i] = true;
      continue;
    }

    if (!inSingle && !inBacktick && char == '"' && prev != '\\') {
      inDouble = !inDouble;
      mask[i] = true;
      continue;
    }

    if (!inSingle && !inDouble && char == '`') {
      inBacktick = !inBacktick;
      mask[i] = true;
      continue;
    }

    if (inSingle || inDouble || inBacktick) {
      mask[i] = true;
    }
  }

  return mask;
}

String _normalizeKeyword(String raw) {
  return raw.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}
