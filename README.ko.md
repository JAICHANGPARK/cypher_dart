# cypher_dart

[English README](README.md)

`cypher_dart`는 Cypher 쿼리를 파싱하고 포맷팅하는 순수 Dart 패키지입니다.
Dart/Flutter 환경에서 쿼리 검증, 에디터 피드백, 정규화된 쿼리 출력이 필요한 경우를 대상으로 합니다.

## 왜 쓰면 좋은가

- Cypher 텍스트를 타입이 있는 AST로 파싱합니다.
- 소스 위치(`line`, `column`, offset)가 포함된 진단 정보를 제공합니다.
- 기본은 strict OpenCypher로 동작하고, Neo4j 전용 문법은 명시적으로 허용할 수 있습니다.
- 파싱된 쿼리를 일관된 canonical 포맷으로 출력합니다.
- VM과 Flutter(모바일/웹/데스크톱)에서 동일 API를 사용합니다.

## 현재 범위 (`0.1.0`)

- 일반적인 쿼리 흐름에 대한 clause-level OpenCypher 파싱
- 부분적 semantic 검증(절 순서, 중복 alias, 기능 게이트)
- 쿼리 흐름과 쓰기(`MATCH`/`WHERE`/`WITH`/`RETURN`/`ORDER BY`/`SKIP`/`LIMIT`/`UNWIND`/`UNION`/`CREATE`/`MERGE`/`SET`/`REMOVE`/`DELETE`/`DETACH DELETE`/`CALL`)를 지원하는 실험적 인메모리 실행 엔진 포함

## 설치

```bash
dart pub add cypher_dart
```

## Import

권장 엔트리포인트:

```dart
import 'package:cypher_dart/cypher_dart.dart';
```

동일 기능의 하위 엔트리포인트:

```dart
import 'package:cypher_dart/opencypher.dart';
```

## 문서

- [DevRel 문서 인덱스](docs/devrel/README.md)
- [시작 가이드](docs/devrel/getting-started.md)
- [실행 엔진 가이드](docs/devrel/execution-engine.md)
- [벤치마킹 가이드](docs/devrel/benchmarking.md)
- [기술 보고서(LaTeX)](docs/paper/technical_report.tex)
- [기술 보고서 빌드 가이드](docs/paper/README.md)

## 빠른 시작

```dart
import 'package:cypher_dart/cypher_dart.dart';

void main() {
  const query = '''
MATCH (n:Person)
WHERE n.age > 30
RETURN n.name AS name
ORDER BY name
LIMIT 5
''';

  final result = Cypher.parse(query);

  if (result.hasErrors) {
    for (final d in result.diagnostics) {
      print('${d.code} ${d.severity.name}: ${d.message}');
      print('at ${d.span.start.line + 1}:${d.span.start.column + 1}');
    }
    return;
  }

  final formatted = CypherPrinter.format(result.document!);
  print(formatted);
}
```

## 자주 쓰는 활용 패턴

### 1) Fail-fast 검증 (API/서버)

잘못된 쿼리를 즉시 거절해야 한다면 기본 옵션(`recoverErrors: false`)을 사용합니다.

```dart
final result = Cypher.parse(userQuery);
if (result.hasErrors) {
  throw FormatException(result.diagnostics.first.message);
}
```

### 2) 복구 모드 (에디터/IDE)

사용자가 입력 중인 불완전 쿼리도 다루려면 `recoverErrors: true`를 사용합니다.

```dart
final result = Cypher.parse(
  userTypingQuery,
  options: const CypherParseOptions(recoverErrors: true),
);

// diagnostics가 있어도 result.document를 활용할 수 있습니다.
```

### 3) Strict 모드와 Neo4j 확장 제어

기본은 strict OpenCypher입니다. 필요한 확장만 명시적으로 열어 사용합니다.

```dart
final strictResult = Cypher.parse('USE neo4j MATCH (n) RETURN n');
// -> strict 모드에서 CYP204 발생

final relaxedResult = Cypher.parse(
  'USE neo4j MATCH (n) RETURN n',
  options: const CypherParseOptions(
    recoverErrors: true,
    enabledFeatures: <CypherFeature>{
      CypherFeature.neo4jUseClause,
    },
  ),
);
```

### 4) Neo4j 방언 모드

애플리케이션이 Neo4j 중심이라면 `CypherDialect.neo4j5`를 사용합니다.

```dart
final result = Cypher.parse(
  query,
  options: const CypherParseOptions(dialect: CypherDialect.neo4j5),
);
```

### 5) Canonical 포맷팅

```dart
final result = Cypher.parse('MATCH (n)   RETURN   n  ORDER BY n.name   LIMIT 3');
if (!result.hasErrors && result.document != null) {
  final pretty = CypherPrinter.format(result.document!);
  print(pretty);
}
```

### 6) AST를 JSON으로 변환 (로깅/테스트)

```dart
final result = Cypher.parse('MATCH (n) RETURN n');
if (result.document != null) {
  final jsonMap = cypherNodeToJson(result.document!);
  print(jsonMap);
}
```

### 7) 실험적 인메모리 실행

```dart
final graph = InMemoryGraphStore()
  ..createNode(
    labels: {'Person'},
    properties: {'name': 'Alice', 'age': 34},
  );

final execution = CypherEngine.execute(
  'MATCH (n:Person) WHERE n.age >= 30 RETURN n.name AS name',
  graph: graph,
);

print(execution.records); // [{name: Alice}]
```

엔진 메모:
- `(a)-[r:TYPE]->(b)` 형태의 단일 hop 관계 패턴 매칭을 지원합니다.
- `[r:T1|:T2]` 관계 타입 alternation과 `MATCH p = (a)-[r]->(b)` 경로 변수 바인딩을 지원합니다.
- `WITH`/`RETURN`에서 기본 집계(`count`, `sum`, `avg`, `min`, `max`)를 지원합니다.
- `MERGE ... ON CREATE SET ... ON MATCH SET ...`를 절 단위 `SET` 체인에서 지원합니다.
- `CALL`은 인메모리 내장 프로시저 `db.labels()`, `db.relationshipTypes()`, `db.propertyKeys()`를 지원합니다.

## Parse 옵션

- `dialect`: `CypherDialect.openCypher9`(기본) 또는 `CypherDialect.neo4j5`
- `enabledFeatures`: Neo4j 확장 기능 allow-list
- `recoverErrors`: `false`(fail-fast) 또는 `true`(best-effort 파싱)

## 용어집

- `AST` (Abstract Syntax Tree): 원본 텍스트가 아니라 구조화된 노드 트리로 표현한 쿼리 형태입니다.
- `Cypher`: 그래프 데이터베이스용 질의 언어입니다.
- `OpenCypher`: 벤더 중립적인 Cypher 규격입니다.
- `Neo4j`: OpenCypher를 확장한 문법/기능을 제공하는 그래프 데이터베이스입니다.
- `Dialect`: 파서 동작 모드입니다(예: strict OpenCypher, Neo4j 모드).
- `Feature gate`: 특정 문법 기능의 허용/차단을 명시적으로 제어하는 스위치입니다.
- `Parse` (파싱): 쿼리 텍스트를 AST 같은 구조화된 모델로 변환하는 과정입니다.
- `Parser` (파서): 파싱을 수행하고 진단 정보를 생성하는 구성요소입니다.
- `Clause`: `MATCH`, `WHERE`, `RETURN`, `ORDER BY` 같은 쿼리의 주요 단위입니다.
- `Diagnostic`: 코드/심각도/소스 위치를 포함한 파서·검증 메시지입니다.
- `Span`: 노드나 진단에 연결된 소스 범위(`start`, `end`)입니다.
- `Offset`: 원본 쿼리 문자열 기준 문자 인덱스입니다.
- `Fail-fast`: 오류 발생 시 즉시 중단하고 문서를 반환하지 않는 동작(`recoverErrors: false`)입니다.
- `Recovery mode`: 오류가 있어도 파싱을 계속해 부분 구조를 유지하는 동작(`recoverErrors: true`)입니다.
- `Canonical formatting`: 의미는 같지만 표기를 일관된 스타일로 정규화하는 포맷팅입니다.

## 지원하는 clause 노드 타입

- `MatchClause` (`OPTIONAL MATCH` 포함)
- `WhereClause`
- `WithClause`
- `ReturnClause`
- `OrderByClause`
- `LimitClause`
- `SkipClause`
- `CreateClause`
- `MergeClause`
- `SetClause`
- `RemoveClause`
- `DeleteClause`
- `UnwindClause`
- `CallClause`
- `UnionClause` (`UNION`, `UNION ALL`)

## 진단 코드 범위

- `CYP1xx`: 구문/파서 오류
- `CYP2xx`: 확장 기능/게이트 위반
- `CYP3xx`: semantic 검증 오류
- `CYP9xx`: 내부 파서 실패

## Flutter 통합 메모

라이브러리는 순수 Dart이며 `lib/`에서 `dart:io`에 의존하지 않습니다.

일반적인 Flutter 연동 흐름:

1. `TextEditingController`에 쿼리 입력을 바인딩합니다.
2. 텍스트 변경 시 파싱합니다(보통 debounce + `recoverErrors: true`).
3. UI에 `result.diagnostics`를 표시합니다.
4. 파싱 성공 시 `CypherPrinter.format(result.document!)`를 표시합니다.

샘플 앱: `example/flutter_cypher_lab/lib/main.dart`

## 예제와 테스트

- CLI 예제: `example/main.dart`
- 파서 테스트: `test/parser`
- 진단 테스트: `test/diagnostics`
- 기능 게이트 테스트: `test/extensions`
- 브라우저 호환 테스트: `test/web/web_platform_test.dart`

## 로컬 개발

```bash
./tool/release_check.sh
```

이 스크립트는 format, analyze, test, 브라우저 테스트(Chrome 존재 시), 문서 링크 검증, 파서 생성, 생성 파일 동기화 검사를 실행합니다.

ANTLR 설정: `tool/antlr/README.md`

## 라이선스

MIT
