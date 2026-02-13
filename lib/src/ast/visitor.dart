import 'nodes.dart';

abstract interface class CypherNodeVisitor<T> {
  T visitDocument(CypherDocument node);
  T visitQueryStatement(CypherQueryStatement node);
  T visitMatchClause(MatchClause node);
  T visitWhereClause(WhereClause node);
  T visitWithClause(WithClause node);
  T visitReturnClause(ReturnClause node);
  T visitOrderByClause(OrderByClause node);
  T visitLimitClause(LimitClause node);
  T visitSkipClause(SkipClause node);
  T visitCreateClause(CreateClause node);
  T visitMergeClause(MergeClause node);
  T visitSetClause(SetClause node);
  T visitRemoveClause(RemoveClause node);
  T visitDeleteClause(DeleteClause node);
}
