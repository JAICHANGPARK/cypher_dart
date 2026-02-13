#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRAMMAR_FILE="$ROOT_DIR/tool/grammar/Cypher.g4"
OUTPUT_DIR="$ROOT_DIR/lib/src/generated"
ANTLR_JAR="$ROOT_DIR/tool/antlr/antlr-4.13.2-complete.jar"

mkdir -p "$OUTPUT_DIR"

write_fallback() {
  cat > "$OUTPUT_DIR/generated_metadata.dart" <<'GEN'
// auto-generated, do not edit.

const String cypherGeneratedMode = 'fallback-stub';
const String cypherGeneratedGrammar = 'openCypher9 (vendored)';
GEN

  cat > "$OUTPUT_DIR/cypher_lexer.dart" <<'GEN'
// auto-generated, do not edit.

final class CypherGeneratedLexer {
  CypherGeneratedLexer(this.source);

  final String source;
}
GEN

  cat > "$OUTPUT_DIR/cypher_parser.dart" <<'GEN'
// auto-generated, do not edit.

final class CypherGeneratedParser {
  CypherGeneratedParser(this.source);

  final String source;

  String parseEntryRule() {
    return source;
  }
}
GEN
}

if [[ ! -f "$GRAMMAR_FILE" ]]; then
  echo "Grammar file is missing: $GRAMMAR_FILE"
  exit 1
fi

if command -v java >/dev/null 2>&1 && [[ -f "$ANTLR_JAR" ]]; then
  rm -f "$OUTPUT_DIR"/*.dart
  java -jar "$ANTLR_JAR" -Dlanguage=Dart -visitor -no-listener -o "$OUTPUT_DIR" "$GRAMMAR_FILE"

  cat > "$OUTPUT_DIR/generated_metadata.dart" <<'GEN'
// auto-generated, do not edit.

const String cypherGeneratedMode = 'antlr4';
const String cypherGeneratedGrammar = 'openCypher9 (vendored)';
GEN
else
  echo "ANTLR runtime not found, writing deterministic fallback stubs."
  write_fallback
fi

dart format "$OUTPUT_DIR" >/dev/null
