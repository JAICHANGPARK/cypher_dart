import 'nodes.dart';

/// A visitor interface for traversing Cypher AST nodes.
abstract interface class CypherNodeVisitor<T> {
  /// Visits a [CypherDocument].
  T visitDocument(CypherDocument node);

  /// Visits a [CypherQueryStatement].
  T visitQueryStatement(CypherQueryStatement node);

  /// Visits a [MatchClause].
  T visitMatchClause(MatchClause node);

  /// Visits a [WhereClause].
  T visitWhereClause(WhereClause node);

  /// Visits a [WithClause].
  T visitWithClause(WithClause node);

  /// Visits a [ReturnClause].
  T visitReturnClause(ReturnClause node);

  /// Visits an [OrderByClause].
  T visitOrderByClause(OrderByClause node);

  /// Visits a [LimitClause].
  T visitLimitClause(LimitClause node);

  /// Visits a [SkipClause].
  T visitSkipClause(SkipClause node);

  /// Visits a [CreateClause].
  T visitCreateClause(CreateClause node);

  /// Visits a [MergeClause].
  T visitMergeClause(MergeClause node);

  /// Visits a [SetClause].
  T visitSetClause(SetClause node);

  /// Visits a [RemoveClause].
  T visitRemoveClause(RemoveClause node);

  /// Visits a [DeleteClause].
  T visitDeleteClause(DeleteClause node);

  /// Visits an [UnwindClause].
  T visitUnwindClause(UnwindClause node);

  /// Visits a [CallClause].
  T visitCallClause(CallClause node);

  /// Visits a [UnionClause].
  T visitUnionClause(UnionClause node);
}
