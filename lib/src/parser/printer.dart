import '../ast/nodes.dart';

/// Formats parsed Cypher AST nodes into canonical query text.
abstract final class CypherPrinter {
  /// Formats [document] into normalized Cypher text.
  ///
  /// Statements are separated with `;` and clause keywords are emitted using a
  /// canonical uppercase style.
  static String format(CypherDocument document) {
    final statements = <String>[];

    for (final statement in document.statements.cast<CypherQueryStatement>()) {
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
        return '${clause.detach ? 'DETACH DELETE' : 'DELETE'} $body';
      case UnwindClause():
        return 'UNWIND $body';
      case CallClause():
        return 'CALL $body';
      case UnionClause():
        if (body.isEmpty) {
          return clause.all ? 'UNION ALL' : 'UNION';
        }
        return '${clause.all ? 'UNION ALL' : 'UNION'} $body';
    }
  }

  static String _normalizeWhitespace(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
