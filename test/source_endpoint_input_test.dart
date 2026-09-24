import 'package:flutter_test/flutter_test.dart';
import 'package:yingji/src/sources/endpoint_input.dart';

void main() {
  test('selected HTTP scheme applies to a bare host and port', () {
    expect(parseSourceEndpoints(['124.220.4.209:11566/'], 'http'), [
      Uri.parse('http://124.220.4.209:11566/'),
    ]);
  });

  test(
    'explicit alternate protocols remain intact and duplicates collapse',
    () {
      expect(
        parseSourceEndpoints([
          'media.example.com:8096 https://backup.example.com/',
          'http://192.168.1.2:8096',
          'media.example.com:8096/',
        ], 'http'),
        [
          Uri.parse('http://media.example.com:8096/'),
          Uri.parse('https://backup.example.com/'),
          Uri.parse('http://192.168.1.2:8096/'),
        ],
      );
    },
  );

  test('empty and invalid values do not become saved endpoints', () {
    expect(
      parseSourceEndpoints(['', 'http://', 'http://?x=1'], 'https'),
      isEmpty,
    );
  });
}
