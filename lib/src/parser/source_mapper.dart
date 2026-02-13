import 'package:source_span/source_span.dart';

final class SourceMapper {
  SourceMapper(String source)
      : _source = source,
        _file = SourceFile.fromString(source,
            url: Uri.parse('memory:query.cypher'));

  final String _source;
  final SourceFile _file;

  SourceSpan span(int start, int end) {
    final safeStart = start.clamp(0, _source.length);
    final safeEnd = end.clamp(safeStart, _source.length);
    return _file.span(safeStart, safeEnd);
  }

  SourceSpan emptySpanAt(int offset) {
    return span(offset, offset);
  }
}
