// Assess one recording and print what the API returned.
//
//   export TONEPERFECT_API_KEY=tp_live_...
//   dart run example/main.dart hello.wav 你好 zh-CN
//
// Without arguments it only lists the languages (no key needed).
import 'dart:io';

import 'package:toneperfect/toneperfect.dart';

Future<void> main(List<String> args) async {
  final client = TonePerfect(apiKey: Platform.environment['TONEPERFECT_API_KEY'] ?? '');
  try {
    if (args.length < 2) {
      final caps = await client.capabilities();
      for (final lang in caps['languages'] as List) {
        print('${lang['locale']}  ${lang['status']}');
      }
      return;
    }
    final language = args.length > 2 ? args[2] : 'zh-CN';
    final result = await client.assess(File(args[0]).readAsBytesSync(),
        text: args[1], language: language, filename: args[0].split('/').last);
    print('model: ${result.modelVersion} | request: ${result.id} | billing: ${result.billing}');
    if (!result.assessable) {
      print('not assessable: ${result.reason}');
      return;
    }
    print('scores: ${result.scores}');
    for (final word in result.words) {
      print('  ${word['word']}  ${word['score']}');
      for (final phone in (word['phones'] as List? ?? const [])) {
        if (phone['decision'] == 'review') {
          print('      expected ${phone['expected']} heard ${phone['heard']} (${phone['score']})');
        }
      }
    }
  } on PaymentRequiredError catch (e) {
    print('No credits left (${e.code}): ${e.message} -> https://api.toneperfect.app/dashboard');
  } on TonePerfectError catch (e) {
    print('${e.status} ${e.code}: ${e.message}');
  } finally {
    client.close();
  }
}
