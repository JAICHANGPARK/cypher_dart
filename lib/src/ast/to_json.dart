import 'nodes.dart';

Map<String, Object?> cypherNodeToJson(CypherNode node) {
  switch (node) {
    case CypherDocument():
      return <String, Object?>{
        'type': 'CypherDocument',
        'span': _span(node),
        'statements': node.statements.map(cypherNodeToJson).toList(),
      };
    case CypherQueryStatement():
      return <String, Object?>{
        'type': 'CypherQueryStatement',
        'span': _span(node),
        'clauses': node.clauses.map(cypherNodeToJson).toList(),
      };
    case MatchClause():
      return _clause(node, <String, Object?>{
        'optional': node.optional,
        'pattern': node.pattern,
      });
    case WhereClause():
      return _clause(node, <String, Object?>{'expression': node.expression});
    case WithClause():
      return _clause(node, <String, Object?>{'items': node.items});
    case ReturnClause():
      return _clause(node, <String, Object?>{'items': node.items});
    case OrderByClause():
      return _clause(node, <String, Object?>{'items': node.items});
    case LimitClause():
      return _clause(node, <String, Object?>{'value': node.value});
    case SkipClause():
      return _clause(node, <String, Object?>{'value': node.value});
    case CreateClause():
      return _clause(node, <String, Object?>{'pattern': node.pattern});
    case MergeClause():
      return _clause(node, <String, Object?>{'pattern': node.pattern});
    case SetClause():
      return _clause(node, <String, Object?>{'assignments': node.assignments});
    case RemoveClause():
      return _clause(node, <String, Object?>{'items': node.items});
    case DeleteClause():
      return _clause(node, <String, Object?>{'items': node.items});
  }
}

Map<String, Object?> _clause(CypherClause clause, Map<String, Object?> extra) {
  return <String, Object?>{
    'type': clause.runtimeType.toString(),
    'span': _span(clause),
    'keyword': clause.keyword,
    'body': clause.body,
    ...extra,
  };
}

Map<String, Object?> _span(CypherNode node) {
  return <String, Object?>{
    'start': node.span.start.offset,
    'end': node.span.end.offset,
  };
}
