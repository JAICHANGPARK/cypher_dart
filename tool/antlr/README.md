# ANTLR Runtime

Place `antlr-4.13.2-complete.jar` in this directory to enable full ANTLR generation mode:

```bash
curl -L -o tool/antlr/antlr-4.13.2-complete.jar \
  https://repo1.maven.org/maven2/org/antlr/antlr4/4.13.2/antlr4-4.13.2-complete.jar
```

Without this JAR, `tool/generate_parser.sh` writes deterministic fallback stubs.
