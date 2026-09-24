/// Parse pasted URLs and host:port entries without changing their stored Uri format.
List<Uri> parseSourceEndpoints(Iterable<String> fields, String selectedScheme) {
  final result = <Uri>[];
  for (final field in fields) {
    final tokens = field
        .split(RegExp(r'[\s,;]+'))
        .where((part) => part.isNotEmpty);
    for (final token in tokens) {
      final hasScheme = RegExp(
        r'^https?://',
        caseSensitive: false,
      ).hasMatch(token);
      final uri = Uri.tryParse(hasScheme ? token : '$selectedScheme://$token');
      if (uri == null ||
          uri.host.isEmpty ||
          !const {'http', 'https'}.contains(uri.scheme)) {
        continue;
      }
      final normalized = uri.path.endsWith('/')
          ? uri
          : uri.replace(path: '${uri.path}/');
      if (!result.contains(normalized)) result.add(normalized);
    }
  }
  return result;
}
