// Live smoke check: capabilities without a key, and a real multipart /v1/assess
// with an invalid key (the server must answer 401 invalid_api_key).
import 'package:toneperfect/toneperfect.dart';

Future<void> main() async {
  final client = TonePerfect(apiKey: 'tp_live_invalid');
  final caps = await client.capabilities();
  print('capabilities: ${(caps['languages'] as List).length} languages, ${caps['model_version']}');
  try {
    await client.assess(List.filled(1000, 0), text: '你好');
  } on TonePerfectError catch (e) {
    print('assess with invalid key: $e');
  }
  client.close();
}
