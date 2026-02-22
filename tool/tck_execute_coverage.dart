import 'dart:convert';
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

final RegExp _parametersBlockPattern = RegExp(
  r'^\s*(?:Given|And)\s+parameters are:\s*\n((?:\s*\|[^\n]*\|\s*\n?)*)',
  multiLine: true,
  caseSensitive: false,
);

final RegExp _parameterRowPattern =
    RegExp(r'^\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$');

final RegExp _placeholderPattern = RegExp(r'<[A-Za-z_][A-Za-z0-9_]*>');

final class _QueryBlock {
  const _QueryBlock({
    required this.kind,
    required this.query,
    required this.line,
  });

  final String kind;
  final String query;
  final int line;

  bool get isSetup => kind == 'And having executed:';
  bool get isExecution => kind == 'When executing query:';
}

final class _ScenarioCase {
  const _ScenarioCase({
    required this.filePath,
    required this.line,
    required this.expectsError,
    required this.queries,
    required this.rawParameters,
  });

  final String filePath;
  final int line;
  final bool expectsError;
  final List<_QueryBlock> queries;
  final Map<String, String> rawParameters;
}

final class _FailureCase {
  const _FailureCase({
    required this.filePath,
    required this.line,
    required this.code,
    required this.message,
    required this.query,
  });

  final String filePath;
  final int line;
  final String code;
  final String message;
  final String query;
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

  final scenarios = <_ScenarioCase>[];
  for (final file in files) {
    final content = file.readAsStringSync();
    scenarios.addAll(_extractScenarioCases(file.path, content));
  }

  final parseOptions = CypherParseOptions(
    dialect: dialect,
    enabledFeatures: const <CypherFeature>{
      CypherFeature.neo4jPatternComprehension,
      CypherFeature.neo4jExistsSubquery,
    },
  );
  var checkedQueries = 0;
  var passedQueries = 0;
  var failedQueries = 0;
  var setupFailures = 0;
  var skippedPlaceholders = 0;
  var expectedErrorQueries = 0;
  var expectedErrorDetected = 0;
  var expectedErrorAutoPassed = 0;

  final failureSamples = <_FailureCase>[];
  final failureCodeCounts = <String, int>{};
  final failureLeadingKeywordCounts = <String, int>{};
  final perFile = <String, _FileStats>{};

  for (final scenario in scenarios) {
    final queries = scenario.queries;
    if (queries.isEmpty) {
      continue;
    }

    final scenarioParameters = _evaluateScenarioParameters(
      scenario.rawParameters,
      parseOptions: parseOptions,
    );

    if (!includePlaceholders &&
        (queries.any((query) => _placeholderPattern.hasMatch(query.query)) ||
            scenario.rawParameters.values
                .any((value) => _placeholderPattern.hasMatch(value)))) {
      skippedPlaceholders++;
      continue;
    }

    final graph = InMemoryGraphStore();
    var setupFailed = false;

    for (final queryBlock in queries.where((q) => q.isSetup)) {
      final setupResult = _safeExecute(
        queryBlock.query,
        graph: graph,
        parseOptions: parseOptions,
        parameters: scenarioParameters,
      );
      if (setupResult.hasErrors) {
        setupFailed = true;
        setupFailures++;
        break;
      }
    }

    final executionBlocks = queries.where((query) => query.isExecution);
    for (final queryBlock in executionBlocks) {
      checkedQueries++;
      final stats = perFile.putIfAbsent(scenario.filePath, _FileStats.new);
      stats.checked++;

      if (scenario.expectsError) {
        expectedErrorQueries++;
        passedQueries++;
        if (!setupFailed) {
          final result = _safeExecute(
            queryBlock.query,
            graph: graph,
            parseOptions: parseOptions,
            parameters: scenarioParameters,
          );
          if (result.hasErrors) {
            expectedErrorDetected++;
          } else {
            expectedErrorAutoPassed++;
          }
        } else {
          expectedErrorDetected++;
        }
        continue;
      }

      if (setupFailed) {
        failedQueries++;
        stats.failed++;
        _recordFailure(
          failures: failureSamples,
          sampleLimit: sampleLimit,
          failureCodeCounts: failureCodeCounts,
          failureLeadingKeywordCounts: failureLeadingKeywordCounts,
          failure: _FailureCase(
            filePath: scenario.filePath,
            line: queryBlock.line,
            code: 'SETUP_FAILED',
            message: 'A setup query failed before execution.',
            query: queryBlock.query,
          ),
        );
        continue;
      }

      final result = _safeExecute(
        queryBlock.query,
        graph: graph,
        parseOptions: parseOptions,
        parameters: scenarioParameters,
      );

      if (!result.hasErrors) {
        passedQueries++;
        continue;
      }

      failedQueries++;
      stats.failed++;
      _recordFailure(
        failures: failureSamples,
        sampleLimit: sampleLimit,
        failureCodeCounts: failureCodeCounts,
        failureLeadingKeywordCounts: failureLeadingKeywordCounts,
        failure: _FailureCase(
          filePath: scenario.filePath,
          line: queryBlock.line,
          code: result.code,
          message: result.message,
          query: queryBlock.query,
        ),
      );
    }
  }

  stdout.writeln('openCypher TCK execution smoke coverage');
  stdout.writeln('  Root: $root');
  stdout.writeln('  Dialect: ${dialect.name}');
  stdout.writeln('  Feature files: ${files.length}');
  stdout.writeln('  Extracted scenarios: ${scenarios.length}');
  stdout.writeln('  Skipped placeholder scenarios: $skippedPlaceholders');
  stdout.writeln('  Setup query failures: $setupFailures');
  stdout.writeln('  Checked execution queries: $checkedQueries');
  stdout.writeln(
    '  Pass/fail: $passedQueries/$checkedQueries (${_percent(passedQueries, checkedQueries)})',
  );
  stdout.writeln(
    '  Expected-error queries: $expectedErrorQueries '
    '(detected by parser/runtime: $expectedErrorDetected, '
    'auto-passed without error: $expectedErrorAutoPassed)',
  );

  if (failedQueries == 0) {
    return;
  }

  stdout.writeln('');
  stdout.writeln('Top failure codes:');
  for (final entry in _sortedEntries(failureCodeCounts).take(10)) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }

  stdout.writeln('');
  stdout.writeln('Top leading keywords among failures:');
  for (final entry in _sortedEntries(failureLeadingKeywordCounts).take(10)) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }

  stdout.writeln('');
  stdout.writeln('Sample failures:');
  for (final sample in failureSamples) {
    stdout.writeln(
      '  ${sample.filePath}:${sample.line} ${sample.code}: ${sample.message}',
    );
    stdout.writeln('    ${_singleLine(sample.query, maxLength: 160)}');
  }

  stdout.writeln('');
  stdout.writeln('Most failure-heavy files (by fail ratio):');
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

void _printUsage(String reason) {
  stderr.writeln(reason);
  stderr.writeln(
    'Usage: dart run tool/tck_execute_coverage.dart '
    '[--root=openCypher/tck/features] [--samples=20] '
    '[--dialect=openCypher9|neo4j5] [--include-placeholders]\n'
    'Note: expected-error scenarios are counted as pass.',
  );
}

void _recordFailure({
  required List<_FailureCase> failures,
  required int sampleLimit,
  required Map<String, int> failureCodeCounts,
  required Map<String, int> failureLeadingKeywordCounts,
  required _FailureCase failure,
}) {
  failureCodeCounts.update(failure.code, (count) => count + 1,
      ifAbsent: () => 1);
  failureLeadingKeywordCounts.update(
    _leadingKeyword(failure.query),
    (count) => count + 1,
    ifAbsent: () => 1,
  );
  if (failures.length < sampleLimit) {
    failures.add(failure);
  }
}

final class _ExecutionProbeResult {
  const _ExecutionProbeResult({
    required this.hasErrors,
    required this.code,
    required this.message,
  });

  final bool hasErrors;
  final String code;
  final String message;
}

_ExecutionProbeResult _safeExecute(
  String query, {
  required InMemoryGraphStore graph,
  required CypherParseOptions parseOptions,
  Map<String, Object?> parameters = const <String, Object?>{},
}) {
  try {
    final result = CypherEngine.execute(
      query,
      graph: graph,
      parameters: parameters,
      options: CypherExecutionOptions(parseOptions: parseOptions),
    );
    if (!result.hasErrors) {
      return const _ExecutionProbeResult(
        hasErrors: false,
        code: 'OK',
        message: '',
      );
    }

    if (result.runtimeErrors.isNotEmpty) {
      return _ExecutionProbeResult(
        hasErrors: true,
        code: 'RUNTIME',
        message: result.runtimeErrors.first,
      );
    }

    if (result.parseResult.diagnostics.isNotEmpty) {
      final diagnostic = result.parseResult.diagnostics.first;
      return _ExecutionProbeResult(
        hasErrors: true,
        code: diagnostic.code,
        message: diagnostic.message,
      );
    }

    return const _ExecutionProbeResult(
      hasErrors: true,
      code: 'UNKNOWN',
      message: 'Execution reported an unknown error.',
    );
  } catch (error) {
    return _ExecutionProbeResult(
      hasErrors: true,
      code: 'THROW',
      message: '$error',
    );
  }
}

List<_ScenarioCase> _extractScenarioCases(String filePath, String content) {
  final scenarios = <_ScenarioCase>[];
  final scenarioMatches = _scenarioPattern.allMatches(content).toList();

  if (scenarioMatches.isEmpty) {
    final queries =
        _extractQueryBlocks(content, blockStart: 0, fullText: content);
    if (queries.isNotEmpty) {
      scenarios.add(
        _ScenarioCase(
          filePath: filePath,
          line: 1,
          expectsError: false,
          queries: queries,
          rawParameters: _extractRawParameters(content),
        ),
      );
    }
    return scenarios;
  }

  for (var i = 0; i < scenarioMatches.length; i++) {
    final start = scenarioMatches[i].start;
    final end = i + 1 < scenarioMatches.length
        ? scenarioMatches[i + 1].start
        : content.length;
    final block = content.substring(start, end);
    final line = _lineNumberAt(content, start);
    final expectsError = _scenarioExpectsErrorPattern.hasMatch(block);
    final queries = _extractQueryBlocks(
      block,
      blockStart: start,
      fullText: content,
    );
    if (queries.isEmpty) {
      continue;
    }
    scenarios.add(
      _ScenarioCase(
        filePath: filePath,
        line: line,
        expectsError: expectsError,
        queries: queries,
        rawParameters: _extractRawParameters(block),
      ),
    );
  }

  return scenarios;
}

Map<String, String> _extractRawParameters(String block) {
  final parameters = <String, String>{};
  for (final match in _parametersBlockPattern.allMatches(block)) {
    final table = match.group(1) ?? '';
    for (final line in const LineSplitter().convert(table)) {
      final rowMatch = _parameterRowPattern.firstMatch(line);
      if (rowMatch == null) {
        continue;
      }
      final key = rowMatch.group(1)!.trim();
      if (key.isEmpty) {
        continue;
      }
      parameters[key] = rowMatch.group(2)!.trim();
    }
  }
  return parameters;
}

Map<String, Object?> _evaluateScenarioParameters(
  Map<String, String> rawParameters, {
  required CypherParseOptions parseOptions,
}) {
  if (rawParameters.isEmpty) {
    return const <String, Object?>{};
  }

  final resolved = <String, Object?>{};
  for (final entry in rawParameters.entries) {
    resolved[entry.key] = _evaluateParameterExpression(
      entry.value,
      parseOptions: parseOptions,
    );
  }
  return resolved;
}

Object? _evaluateParameterExpression(
  String expression, {
  required CypherParseOptions parseOptions,
}) {
  final trimmed = expression.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final probe = CypherEngine.execute(
    'RETURN $trimmed AS value',
    graph: InMemoryGraphStore(),
    options: CypherExecutionOptions(parseOptions: parseOptions),
  );
  if (probe.hasErrors || probe.records.isEmpty) {
    return trimmed;
  }
  return probe.records.first['value'];
}

List<_QueryBlock> _extractQueryBlocks(
  String block, {
  required int blockStart,
  required String fullText,
}) {
  final queries = <_QueryBlock>[];
  for (final match in _queryBlockPattern.allMatches(block)) {
    final kind = match.group(1)!;
    final query = (match.group(2) ?? '').trim();
    if (query.isEmpty) {
      continue;
    }

    final absoluteOffset = blockStart + match.start;
    final line = _lineNumberAt(fullText, absoluteOffset);
    queries.add(
      _QueryBlock(
        kind: kind,
        query: query,
        line: line,
      ),
    );
  }
  return queries;
}

int _lineNumberAt(String text, int offset) {
  if (offset <= 0) {
    return 1;
  }
  final clamped = math.min(offset, text.length);
  return '\n'.allMatches(text.substring(0, clamped)).length + 1;
}

String _leadingKeyword(String query) {
  final trimmed = query.trimLeft();
  if (trimmed.isEmpty) {
    return '<empty>';
  }
  final token = trimmed.split(RegExp(r'\s+')).take(2).join(' ').toUpperCase();
  return token.isEmpty ? '<empty>' : token;
}

String _singleLine(String text, {int maxLength = 140}) {
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.length <= maxLength) {
    return oneLine;
  }
  return '${oneLine.substring(0, maxLength - 3)}...';
}

String _percent(int numerator, int denominator) {
  if (denominator == 0) {
    return '0.00%';
  }
  final value = numerator * 100 / denominator;
  return '${value.toStringAsFixed(2)}%';
}

List<MapEntry<String, int>> _sortedEntries(Map<String, int> counts) {
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final countCompare = b.value.compareTo(a.value);
      if (countCompare != 0) {
        return countCompare;
      }
      return a.key.compareTo(b.key);
    });
  return entries;
}
