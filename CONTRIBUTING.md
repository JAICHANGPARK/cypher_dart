# Contributing

## Prerequisites

- Dart SDK 3.6+
- Optional: Java 17+ for ANTLR generation

## Local Checks

```bash
./tool/release_check.sh
```

## Parser Generation

```bash
./tool/generate_parser.sh
```

If ANTLR is unavailable, a deterministic fallback stub is generated.
