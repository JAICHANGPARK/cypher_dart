import 'dart:io';
import 'dart:math' as math;

import 'package:cypher_dart/opencypher.dart';

final RegExp _queryBlockPattern = RegExp(
  r'(When executing query:|And having executed:)\s*\n\s*"""\s*\n([\s\S]*?)\n\s*"""',
  multiLine: true,
);

final RegExp _scenarioPattern = RegExp(
  r'^\s*Scenario(?: Outline)?:[^\n]*',
  multiLine: true,
  caseSensitive: false,
);

final RegExp _scenarioExpectsErrorPattern = RegExp(
  r'^\s*(Then|And)\s+(?:an?\s+)?[^\n]*\bshould be raised\b',
  multiLine: true,
  caseSensitive: false,
);

final RegExp _placeholderPattern = RegExp(r'<[A-Za-z_][A-Za-z0-9_]*>');

final class _QueryCase {
  const _QueryCase({
    required this.filePath,
    required this.line,
    required this.kind,
    required this.expectsError,
    required this.query,
  });

  final String filePath;
  final int line;
  final String kind;
  final bool expectsError;
  final String query;
}

final class _FailureCase {
  const _FailureCase({
    required this.queryCase,
    required this.code,
    required this.message,
  });

  final _QueryCase queryCase;
  final String code;
  final String message;
}

final class _FileStats {
  _FileStats();

  int checked = 0;
  int failed = 0;
}

void main(List<String> args) {
  var root = 'openCypher/tck/features';
  var sampleLimit = 20;
  var includePlaceholders = false;
  var dialect = CypherDialect.openCypher9;

  for (final arg in args) {
    if (arg == '--include-placeholders') {
      includePlaceholders = true;
      continue;
    }
    if (arg.startsWith('--root=')) {
      root = arg.substring('--root='.length);
      continue;
    }
    if (arg.startsWith('--samples=')) {
      sampleLimit =
          int.tryParse(arg.substring('--samples='.length)) ?? sampleLimit;
      continue;
    }
    if (arg.startsWith('--dialect=')) {
      final value = arg.substring('--dialect='.length).trim().toLowerCase();
      if (value == 'opencypher9') {
        dialect = CypherDialect.openCypher9;
      } else if (value == 'neo4j5') {
        dialect = CypherDialect.neo4j5;
      } else {
        _printUsage('Unsupported dialect value: $value');
        exitCode = 2;
        return;
      }
      continue;
    }

    _printUsage('Unknown argument: $arg');
    exitCode = 2;
    return;
  }

  final featureDir = Directory(root);
  if (!featureDir.existsSync()) {
    stderr.writeln('Directory not found: $root');
    exitCode = 2;
    return;
  }

  final files = featureDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.feature'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final queries = <_QueryCase>[];
  for (final file in files) {
    final content = file.readAsStringSync();
    queries.addAll(_extractQueryCases(filePath: file.path, content: content));
  }

  final options = CypherParseOptions(dialect: dialect);
  var rawPassed = 0;
  var rawFailed = 0;
  var expectationPassed = 0;
  var expectationFailed = 0;
  var expectedErrorQueries = 0;
  var expectedErrorDetectedByParser = 0;
  var expectedErrorAutoPassed = 0;
  var skippedPlaceholders = 0;
  final failureSamples = <_FailureCase>[];
  final failureCodeCounts = <String, int>{};
  final failureLeadingKeywordCounts = <String, int>{};
  final perFile = <String, _FileStats>{};

  for (final queryCase in queries) {
    if (!includePlaceholders && _placeholderPattern.hasMatch(queryCase.query)) {
      skippedPlaceholders++;
      continue;
    }

    final stats = perFile.putIfAbsent(queryCase.filePath, _FileStats.new);
    stats.checked++;

    final result = Cypher.parse(queryCase.query, options: options);
    final hasFailure = result.hasErrors || result.document == null;
    if (hasFailure) {
      rawFailed++;
    } else {
      rawPassed++;
    }

    if (queryCase.expectsError) {
      expectedErrorQueries++;
      expectationPassed++;
      if (hasFailure) {
        expectedErrorDetectedByParser++;
      } else {
        expectedErrorAutoPassed++;
      }
      continue;
    }

    if (!hasFailure) {
      expectationPassed++;
      continue;
    }

    expectationFailed++;
    stats.failed++;

    final diagnostic =
        result.diagnostics.isNotEmpty ? result.diagnostics.first : null;
    final code = diagnostic?.code ?? 'NO_DIAG';
    final message = diagnostic?.message ?? 'No diagnostic emitted.';
    failureCodeCounts.update(code, (count) => count + 1, ifAbsent: () => 1);

    final keyword = _leadingKeyword(queryCase.query);
    failureLeadingKeywordCounts.update(
      keyword,
      (count) => count + 1,
      ifAbsent: () => 1,
    );

    if (failureSamples.length < sampleLimit) {
      failureSamples.add(
        _FailureCase(
          queryCase: queryCase,
          code: code,
          message: message,
        ),
      );
    }
  }

  final checked = rawPassed + rawFailed;
  stdout.writeln('openCypher TCK parse coverage');
  stdout.writeln('  Root: $root');
  stdout.writeln('  Dialect: ${dialect.name}');
  stdout.writeln('  Feature files: ${files.length}');
  stdout.writeln('  Extracted query blocks: ${queries.length}');
  stdout.writeln('  Skipped placeholder templates: $skippedPlaceholders');
  stdout.writeln('  Checked queries: $checked');
  stdout.writeln(
    '  Raw parser pass/fail: $rawPassed/$checked '
    '(${_percent(rawPassed, checked)})',
  );
  stdout.writeln(
    '  Expectation-aware pass/fail (error-expected queries auto-pass): '
    '$expectationPassed/$checked (${_percent(expectationPassed, checked)})',
  );
  stdout.writeln(
    '  Expected-error queries: $expectedErrorQueries '
    '(parser raised error on $expectedErrorDetectedByParser, '
    'auto-passed without parser error: $expectedErrorAutoPassed)',
  );

  if (expectationFailed > 0) {
    stdout.writeln('');
    stdout.writeln('Top expectation-aware failure diagnostic codes:');
    for (final entry in _sortedEntries(failureCodeCounts).take(10)) {
      stdout.writeln('  ${entry.key}: ${entry.value}');
    }

    stdout.writeln('');
    stdout.writeln('Top leading keywords among expectation-aware failures:');
    for (final entry in _sortedEntries(failureLeadingKeywordCounts).take(10)) {
      stdout.writeln('  ${entry.key}: ${entry.value}');
    }

    stdout.writeln('');
    stdout.writeln('Sample expectation-aware failures:');
    for (final sample in failureSamples) {
      final queryOneLine = _singleLine(sample.queryCase.query, maxLength: 140);
      stdout.writeln(
        '  ${sample.queryCase.filePath}:${sample.queryCase.line} '
        '[${sample.queryCase.kind}] ${sample.code}: ${sample.message}',
      );
      stdout.writeln('    $queryOneLine');
    }

    stdout.writeln('');
    stdout
        .writeln('Most failure-heavy files (by expectation-aware fail ratio):');
    final fileEntries =
        perFile.entries.where((entry) => entry.value.checked > 0).toList()
          ..sort((a, b) {
            final leftRatio = a.value.failed / a.value.checked;
            final rightRatio = b.value.failed / b.value.checked;
            final ratioCompare = rightRatio.compareTo(leftRatio);
            if (ratioCompare != 0) {
              return ratioCompare;
            }
            return b.value.failed.compareTo(a.value.failed);
          });

    for (final entry in fileEntries.take(10)) {
      final stats = entry.value;
      stdout.writeln(
        '  ${entry.key}: ${stats.failed}/${stats.checked} '
        '(${_percent(stats.failed, stats.checked)})',
      );
    }
  }
}

void _printUsage(String reason) {
  stderr.writeln(reason);
  stderr.writeln(
    'Usage: dart run tool/tck_parse_coverage.dart '
    '[--root=openCypher/tck/features] [--samples=20] '
    '[--dialect=openCypher9|neo4j5] [--include-placeholders]\n'
    'Note: expectation-aware score auto-passes scenarios that expect errors.',
  );
}

List<_QueryCase> _extractQueryCases({
  required String filePath,
  required String content,
}) {
  final queryCases = <_QueryCase>[];
  final scenarioMatches = _scenarioPattern.allMatches(content).toList();

  if (scenarioMatches.isEmpty) {
    _appendQueryCasesFromBlock(
      queryCases: queryCases,
      block: content,
      blockStart: 0,
      filePath: filePath,
      fileContent: content,
      scenarioExpectsError: false,
    );
    return queryCases;
  }

  final prefixEnd = scenarioMatches.first.start;
  if (prefixEnd > 0) {
    _appendQueryCasesFromBlock(
      queryCases: queryCases,
      block: content.substring(0, prefixEnd),
      blockStart: 0,
      filePath: filePath,
      fileContent: content,
      scenarioExpectsError: false,
    );
  }

  for (var i = 0; i < scenarioMatches.length; i++) {
    final start = scenarioMatches[i].start;
    final end = i + 1 < scenarioMatches.length
        ? scenarioMatches[i + 1].start
        : content.length;
    final block = content.substring(start, end);
    final scenarioExpectsError = _scenarioExpectsErrorPattern.hasMatch(block);

    _appendQueryCasesFromBlock(
      queryCases: queryCases,
      block: block,
      blockStart: start,
      filePath: filePath,
      fileContent: content,
      scenarioExpectsError: scenarioExpectsError,
    );
  }

  return queryCases;
}

void _appendQueryCasesFromBlock({
  required List<_QueryCase> queryCases,
  required String block,
  required int blockStart,
  required String filePath,
  required String fileContent,
  required bool scenarioExpectsError,
}) {
  for (final match in _queryBlockPattern.allMatches(block)) {
    final rawQuery = match.group(2)!;
    final query = _stripIndent(rawQuery).trim();
    if (query.isEmpty) {
      continue;
    }

    final kind = match.group(1)!;
    final appliesErrorExpectationToThisQuery = scenarioExpectsError &&
        kind.toUpperCase().startsWith('WHEN EXECUTING QUERY');

    queryCases.add(
      _QueryCase(
        filePath: filePath,
        line: _lineOfOffset(fileContent, blockStart + match.start),
        kind: kind,
        expectsError: appliesErrorExpectationToThisQuery,
        query: query,
      ),
    );
  }
}

String _stripIndent(String source) {
  final normalized = source.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n');

  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }

  if (lines.isEmpty) {
    return '';
  }

  final indents = lines
      .where((line) => line.trim().isNotEmpty)
      .map((line) => line.length - line.trimLeft().length)
      .toList();
  final minIndent = indents.isEmpty ? 0 : indents.reduce(math.min);

  return lines.map((line) {
    if (line.trim().isEmpty) {
      return '';
    }
    if (line.length <= minIndent) {
      return line.trimLeft();
    }
    return line.substring(minIndent);
  }).join('\n');
}

int _lineOfOffset(String text, int offset) {
  var line = 1;
  final cappedOffset = math.min(offset, text.length);
  for (var i = 0; i < cappedOffset; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
    }
  }
  return line;
}

String _percent(int part, int total) {
  if (total == 0) {
    return '0.00%';
  }
  final value = (part * 100) / total;
  return '${value.toStringAsFixed(2)}%';
}

String _leadingKeyword(String query) {
  final match = RegExp(r'^\s*([A-Za-z]+(?:\s+[A-Za-z]+)?)').firstMatch(query);
  return (match?.group(1) ?? '<unknown>').toUpperCase();
}

String _singleLine(String text, {required int maxLength}) {
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.length <= maxLength) {
    return oneLine;
  }
  return '${oneLine.substring(0, maxLength - 3)}...';
}

List<MapEntry<String, int>> _sortedEntries(Map<String, int> counts) {
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      if (byCount != 0) {
        return byCount;
      }
      return a.key.compareTo(b.key);
    });
  return entries;
}
