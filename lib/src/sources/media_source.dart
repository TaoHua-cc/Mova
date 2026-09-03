enum SourceKind { emby, jellyfin, webdav }

class MediaSource {
  const MediaSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.endpoint,
    this.userId,
    this.serverId,
    this.alternateEndpoints = const [],
    this.iconUrl,
  });
  final String id;
  final String name;
  final SourceKind kind;
  final Uri endpoint;
  final String? userId;
  final String? serverId;
  final List<Uri> alternateEndpoints;
  final String? iconUrl;

  List<Uri> get endpoints => [
    endpoint,
    ...alternateEndpoints.where((value) => value != endpoint),
  ];

  String get kindLabel => switch (kind) {
    SourceKind.emby => 'Emby',
    SourceKind.jellyfin => 'Jellyfin',
    SourceKind.webdav => 'WebDAV',
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'endpoint': endpoint.toString(),
    'userId': userId,
    'serverId': serverId,
    'alternateEndpoints': alternateEndpoints
        .map((value) => value.toString())
        .toList(),
    'iconUrl': iconUrl,
  };

  factory MediaSource.fromJson(Map<String, dynamic> json) => MediaSource(
    id: '${json['id']}',
    name: '${json['name'] ?? '媒体库'}',
    kind: SourceKind.values.firstWhere(
      (value) => value.name == json['kind'],
      orElse: () => SourceKind.emby,
    ),
    endpoint: Uri.parse('${json['endpoint']}'),
    userId: json['userId'] as String?,
    serverId: json['serverId'] as String?,
    alternateEndpoints:
        (json['alternateEndpoints'] as List<dynamic>? ?? const [])
            .map((value) => Uri.tryParse('$value'))
            .whereType<Uri>()
            .toList(growable: false),
    iconUrl: json['iconUrl'] as String?,
  );
}
