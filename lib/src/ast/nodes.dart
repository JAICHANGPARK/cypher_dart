import 'package:meta/meta.dart';
import 'package:source_span/source_span.dart';

@immutable
sealed class CypherNode {
  const CypherNode({required this.span});

  final SourceSpan span;
}

@immutable
sealed class CypherStatement extends CypherNode {
  const CypherStatement({required super.span});
}

@immutable
final class CypherDocument extends CypherNode {
  const CypherDocument({required super.span, required this.statements});

  final List<CypherStatement> statements;
}

@immutable
final class CypherQueryStatement extends CypherStatement {
  const CypherQueryStatement({required super.span, required this.clauses});

  final List<CypherClause> clauses;
}

@immutable
sealed class CypherClause extends CypherNode {
  const CypherClause({
    required super.span,
    required this.keyword,
    required this.body,
  });

  final String keyword;
  final String body;
}

@immutable
final class MatchClause extends CypherClause {
  const MatchClause({
    required super.span,
    required this.pattern,
    this.optional = false,
  }) : super(
          keyword: optional ? 'OPTIONAL MATCH' : 'MATCH',
          body: pattern,
        );

  final String pattern;
  final bool optional;
}

@immutable
final class WhereClause extends CypherClause {
  const WhereClause({required super.span, required this.expression})
      : super(keyword: 'WHERE', body: expression);

  final String expression;
}

@immutable
final class WithClause extends CypherClause {
  const WithClause({required super.span, required this.items})
      : super(keyword: 'WITH', body: items);

  final String items;
}

@immutable
final class ReturnClause extends CypherClause {
  const ReturnClause({required super.span, required this.items})
      : super(keyword: 'RETURN', body: items);

  final String items;
}

@immutable
final class OrderByClause extends CypherClause {
  const OrderByClause({required super.span, required this.items})
      : super(keyword: 'ORDER BY', body: items);

  final String items;
}

@immutable
final class LimitClause extends CypherClause {
  const LimitClause({required super.span, required this.value})
      : super(keyword: 'LIMIT', body: value);

  final String value;
}

@immutable
final class SkipClause extends CypherClause {
  const SkipClause({required super.span, required this.value})
      : super(keyword: 'SKIP', body: value);

  final String value;
}

@immutable
final class CreateClause extends CypherClause {
  const CreateClause({required super.span, required this.pattern})
      : super(keyword: 'CREATE', body: pattern);

  final String pattern;
}

@immutable
final class MergeClause extends CypherClause {
  const MergeClause({required super.span, required this.pattern})
      : super(keyword: 'MERGE', body: pattern);

  final String pattern;
}

@immutable
final class SetClause extends CypherClause {
  const SetClause({required super.span, required this.assignments})
      : super(keyword: 'SET', body: assignments);

  final String assignments;
}

@immutable
final class RemoveClause extends CypherClause {
  const RemoveClause({required super.span, required this.items})
      : super(keyword: 'REMOVE', body: items);

  final String items;
}

@immutable
final class DeleteClause extends CypherClause {
  const DeleteClause({required super.span, required this.items})
      : super(keyword: 'DELETE', body: items);

  final String items;
}
