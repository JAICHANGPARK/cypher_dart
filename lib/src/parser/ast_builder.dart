import 'package:source_span/source_span.dart';

import '../ast/nodes.dart';
import 'error_listener.dart';
import 'lexer_parser.dart';
import 'source_mapper.dart';

final class AstBuildResult {
  const AstBuildResult({required this.document});

  final CypherDocument? document;
}

final class AstBuilder {
  AstBuilder({
    required this.mapper,
    required this.errors,
  });

  final SourceMapper mapper;
  final CypherErrorCollector errors;

  AstBuildResult build(LexParseOutput output) {
    final statements = <CypherStatement>[];

    for (final statement in output.statements) {
      final clauses = <CypherClause>[];
      var sawReturn = false;
      String? previousKeyword;

      for (final rawClause in statement.clauses) {
        final span = mapper.span(rawClause.start, rawClause.end);
        final clause = _toAst(rawClause, span);
        clauses.add(clause);

        _validateOrdering(
          rawClause: rawClause,
          previousKeyword: previousKeyword,
          sawReturn: sawReturn,
        );

        if (_isUnionKeyword(rawClause.keyword)) {
          sawReturn = false;
          previousKeyword = rawClause.keyword;
          continue;
        }

        if (rawClause.keyword == 'RETURN') {
          if (sawReturn) {
            errors.addSemantic(
              code: 'CYP302',
              message: 'RETURN may only appear once per statement.',
              start: rawClause.start,
              end: rawClause.end,
            );
          }
          sawReturn = true;
        }

        if (rawClause.keyword == 'WITH' || rawClause.keyword == 'RETURN') {
          _validateProjectionAliases(rawClause);
        }

        previousKeyword = rawClause.keyword;
      }

      if (clauses.isEmpty) {
        continue;
      }

      statements.add(
        CypherQueryStatement(
          span: mapper.span(statement.start, statement.end),
          clauses: List<CypherClause>.unmodifiable(clauses),
        ),
      );
    }

    final maxOffset =
        output.statements.isEmpty ? 0 : output.statements.last.end;
    final document = CypherDocument(
      span: mapper.span(0, maxOffset),
      statements: List<CypherStatement>.unmodifiable(statements),
    );
    return AstBuildResult(document: document);
  }

  CypherClause _toAst(LexedClause clause, SourceSpan span) {
    switch (clause.keyword) {
      case 'MATCH':
        return MatchClause(span: span, pattern: clause.body);
      case 'OPTIONAL MATCH':
        return MatchClause(span: span, pattern: clause.body, optional: true);
      case 'WHERE':
        return WhereClause(span: span, expression: clause.body);
      case 'WITH':
        return WithClause(span: span, items: clause.body);
      case 'RETURN':
        return ReturnClause(span: span, items: clause.body);
      case 'ORDER BY':
        return OrderByClause(span: span, items: clause.body);
      case 'LIMIT':
        return LimitClause(span: span, value: clause.body);
      case 'SKIP':
        return SkipClause(span: span, value: clause.body);
      case 'CREATE':
        return CreateClause(span: span, pattern: clause.body);
      case 'MERGE':
        return MergeClause(span: span, pattern: clause.body);
      case 'SET':
        return SetClause(span: span, assignments: clause.body);
      case 'REMOVE':
        return RemoveClause(span: span, items: clause.body);
      case 'DELETE':
        return DeleteClause(span: span, items: clause.body);
      case 'DETACH DELETE':
        return DeleteClause(span: span, items: clause.body, detach: true);
      case 'UNWIND':
        return UnwindClause(span: span, items: clause.body);
      case 'CALL':
        return CallClause(span: span, invocation: clause.body);
      case 'UNION':
        return UnionClause(span: span, queryPart: clause.body);
      case 'UNION ALL':
        return UnionClause(span: span, queryPart: clause.body, all: true);
      default:
        errors.addSemantic(
          code: 'CYP101',
          message: 'Unsupported clause keyword "${clause.keyword}".',
          start: clause.start,
          end: clause.end,
        );
        return WithClause(span: span, items: clause.body);
    }
  }

  void _validateOrdering({
    required LexedClause rawClause,
    required String? previousKeyword,
    required bool sawReturn,
  }) {
    final keyword = rawClause.keyword;

    if (sawReturn &&
        keyword != 'ORDER BY' &&
        keyword != 'LIMIT' &&
        keyword != 'SKIP' &&
        !_isUnionKeyword(keyword)) {
      errors.addSemantic(
        code: 'CYP300',
        message: 'Only ORDER BY, SKIP, LIMIT, and UNION may follow RETURN.',
        start: rawClause.start,
        end: rawClause.end,
      );
    }

    if (keyword == 'WHERE' &&
        previousKeyword != 'MATCH' &&
        previousKeyword != 'OPTIONAL MATCH' &&
        previousKeyword != 'WITH') {
      errors.addSemantic(
        code: 'CYP300',
        message: 'WHERE must follow MATCH, OPTIONAL MATCH, or WITH.',
        start: rawClause.start,
        end: rawClause.end,
      );
      return;
    }

    if (keyword == 'ORDER BY' &&
        previousKeyword != 'RETURN' &&
        previousKeyword != 'WITH') {
      errors.addSemantic(
        code: 'CYP300',
        message: 'ORDER BY must follow RETURN or WITH.',
        start: rawClause.start,
        end: rawClause.end,
      );
      return;
    }

    if ((keyword == 'LIMIT' || keyword == 'SKIP') &&
        previousKeyword != 'RETURN' &&
        previousKeyword != 'WITH' &&
        previousKeyword != 'ORDER BY' &&
        previousKeyword != 'LIMIT' &&
        previousKeyword != 'SKIP') {
      errors.addSemantic(
        code: 'CYP300',
        message: '$keyword must follow RETURN/WITH/ORDER BY/SKIP/LIMIT.',
        start: rawClause.start,
        end: rawClause.end,
      );
    }

    if (_isUnionKeyword(keyword) &&
        previousKeyword != 'RETURN' &&
        previousKeyword != 'ORDER BY' &&
        previousKeyword != 'LIMIT' &&
        previousKeyword != 'SKIP') {
      errors.addSemantic(
        code: 'CYP300',
        message: '$keyword must follow RETURN/ORDER BY/SKIP/LIMIT.',
        start: rawClause.start,
        end: rawClause.end,
      );
    }
  }

  Iterable<String> _extractAliases(String clauseBody) sync* {
    final aliasPattern = RegExp(
      r'\bAS\s+([A-Za-z_][A-Za-z0-9_]*)\b',
      caseSensitive: false,
    );
    for (final match in aliasPattern.allMatches(clauseBody)) {
      final alias = match.group(1);
      if (alias != null) {
        yield alias;
      }
    }
  }

  void _validateProjectionAliases(LexedClause clause) {
    final seenInClause = <String>{};
    for (final alias in _extractAliases(clause.body)) {
      if (!seenInClause.add(alias)) {
        errors.addSemantic(
          code: 'CYP301',
          message: 'Duplicate alias "$alias" detected in ${clause.keyword}.',
          start: clause.start,
          end: clause.end,
        );
      }
    }
  }
}

bool _isUnionKeyword(String keyword) {
  return keyword == 'UNION' || keyword == 'UNION ALL';
}
