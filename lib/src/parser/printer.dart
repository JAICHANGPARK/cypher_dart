import '../ast/nodes.dart';

abstract final class CypherPrinter {
  static String format(CypherDocument document) {
    final statements = <String>[];

    for (final statement in document.statements) {
      if (statement is! CypherQueryStatement) {
        throw UnsupportedError(
            'Unsupported statement type: ${statement.runtimeType}');
      }

      final clauseLines = <String>[];
      for (final clause in statement.clauses) {
        clauseLines.add(_formatClause(clause));
      }
      statements.add(clauseLines.join('\n'));
    }

    return statements.join(';\n');
  }

  static String _formatClause(CypherClause clause) {
    final body = _normalizeWhitespace(clause.body);

    switch (clause) {
      case MatchClause():
        return '${clause.optional ? 'OPTIONAL MATCH' : 'MATCH'} $body';
      case WhereClause():
        return 'WHERE $body';
      case WithClause():
        return 'WITH $body';
      case ReturnClause():
        return 'RETURN $body';
      case OrderByClause():
        return 'ORDER BY $body';
      case LimitClause():
        return 'LIMIT $body';
      case SkipClause():
        return 'SKIP $body';
      case CreateClause():
        return 'CREATE $body';
      case MergeClause():
        return 'MERGE $body';
      case SetClause():
        return 'SET $body';
      case RemoveClause():
        return 'REMOVE $body';
      case DeleteClause():
        return 'DELETE $body';
    }
  }

  static String _normalizeWhitespace(String value) {
    return value.replaceAll(RegExp(r'\\s+'), ' ').trim();
  }
}
