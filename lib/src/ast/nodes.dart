import 'package:meta/meta.dart';
import 'package:source_span/source_span.dart';

/// A base node type for all Cypher AST nodes.
@immutable
sealed class CypherNode {
  /// Creates an AST node.
  const CypherNode({required this.span});

  /// The source span for this node in the original query.
  final SourceSpan span;
}

/// A top-level Cypher statement node.
@immutable
sealed class CypherStatement extends CypherNode {
  /// Creates a statement node.
  const CypherStatement({required super.span});
}

/// A parsed Cypher document containing one or more statements.
@immutable
final class CypherDocument extends CypherNode {
  /// Creates a document node.
  const CypherDocument({required super.span, required this.statements});

  /// The statements included in this document.
  final List<CypherStatement> statements;
}

/// A query statement composed of an ordered list of clauses.
@immutable
final class CypherQueryStatement extends CypherStatement {
  /// Creates a query statement node.
  const CypherQueryStatement({required super.span, required this.clauses});

  /// The clauses in execution order.
  final List<CypherClause> clauses;
}

/// A base node type for Cypher clauses.
@immutable
sealed class CypherClause extends CypherNode {
  /// Creates a clause node.
  const CypherClause({
    required super.span,
    required this.keyword,
    required this.body,
  });

  /// The normalized clause keyword, such as `MATCH`.
  final String keyword;

  /// The raw clause body text.
  final String body;
}

/// A `MATCH` or `OPTIONAL MATCH` clause.
@immutable
final class MatchClause extends CypherClause {
  /// Creates a match clause.
  const MatchClause({
    required super.span,
    required this.pattern,
    this.optional = false,
  }) : super(
          keyword: optional ? 'OPTIONAL MATCH' : 'MATCH',
          body: pattern,
        );

  /// The pattern expression text.
  final String pattern;

  /// Whether this clause is `OPTIONAL MATCH`.
  final bool optional;
}

/// A `WHERE` clause.
@immutable
final class WhereClause extends CypherClause {
  /// Creates a where clause.
  const WhereClause({required super.span, required this.expression})
      : super(keyword: 'WHERE', body: expression);

  /// The boolean expression text.
  final String expression;
}

/// A `WITH` clause.
@immutable
final class WithClause extends CypherClause {
  /// Creates a with clause.
  const WithClause({required super.span, required this.items})
      : super(keyword: 'WITH', body: items);

  /// The projection items text.
  final String items;
}

/// A `RETURN` clause.
@immutable
final class ReturnClause extends CypherClause {
  /// Creates a return clause.
  const ReturnClause({required super.span, required this.items})
      : super(keyword: 'RETURN', body: items);

  /// The projection items text.
  final String items;
}

/// An `ORDER BY` clause.
@immutable
final class OrderByClause extends CypherClause {
  /// Creates an order-by clause.
  const OrderByClause({required super.span, required this.items})
      : super(keyword: 'ORDER BY', body: items);

  /// The ordering items text.
  final String items;
}

/// A `LIMIT` clause.
@immutable
final class LimitClause extends CypherClause {
  /// Creates a limit clause.
  const LimitClause({required super.span, required this.value})
      : super(keyword: 'LIMIT', body: value);

  /// The limit expression text.
  final String value;
}

/// A `SKIP` clause.
@immutable
final class SkipClause extends CypherClause {
  /// Creates a skip clause.
  const SkipClause({required super.span, required this.value})
      : super(keyword: 'SKIP', body: value);

  /// The skip expression text.
  final String value;
}

/// A `CREATE` clause.
@immutable
final class CreateClause extends CypherClause {
  /// Creates a create clause.
  const CreateClause({required super.span, required this.pattern})
      : super(keyword: 'CREATE', body: pattern);

  /// The pattern expression text.
  final String pattern;
}

/// A `MERGE` clause.
@immutable
final class MergeClause extends CypherClause {
  /// Creates a merge clause.
  const MergeClause({required super.span, required this.pattern})
      : super(keyword: 'MERGE', body: pattern);

  /// The pattern expression text.
  final String pattern;
}

/// A `SET` clause.
@immutable
final class SetClause extends CypherClause {
  /// Creates a set clause.
  const SetClause({required super.span, required this.assignments})
      : super(keyword: 'SET', body: assignments);

  /// The assignment list text.
  final String assignments;
}

/// A `REMOVE` clause.
@immutable
final class RemoveClause extends CypherClause {
  /// Creates a remove clause.
  const RemoveClause({required super.span, required this.items})
      : super(keyword: 'REMOVE', body: items);

  /// The remove item list text.
  final String items;
}

/// A `DELETE` or `DETACH DELETE` clause.
@immutable
final class DeleteClause extends CypherClause {
  /// Creates a delete clause.
  const DeleteClause({
    required super.span,
    required this.items,
    this.detach = false,
  }) : super(keyword: detach ? 'DETACH DELETE' : 'DELETE', body: items);

  /// The delete target list text.
  final String items;

  /// Whether this clause uses `DETACH DELETE`.
  final bool detach;
}

/// An `UNWIND` clause.
@immutable
final class UnwindClause extends CypherClause {
  /// Creates an unwind clause.
  const UnwindClause({required super.span, required this.items})
      : super(keyword: 'UNWIND', body: items);

  /// The unwind expression text.
  final String items;
}

/// A `CALL` clause.
@immutable
final class CallClause extends CypherClause {
  /// Creates a call clause.
  const CallClause({required super.span, required this.invocation})
      : super(keyword: 'CALL', body: invocation);

  /// The procedure invocation text.
  final String invocation;
}

/// A `UNION` or `UNION ALL` clause separating query parts.
@immutable
final class UnionClause extends CypherClause {
  /// Creates a union clause.
  const UnionClause({
    required super.span,
    required this.queryPart,
    this.all = false,
  }) : super(keyword: all ? 'UNION ALL' : 'UNION', body: queryPart);

  /// The following query part text.
  final String queryPart;

  /// Whether this clause is `UNION ALL`.
  final bool all;
}
