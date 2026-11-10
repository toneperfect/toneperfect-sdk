// Assess one recording and print what the API returned.
//   export TONEPERFECT_API_KEY=tp_test_...      (or tp_live_... for real scores)
//   dart run example/main.dart hello.ogg 你好 zh-CN
import 'dart:io';

import 'package:toneperfect/toneperfect.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: main.dart <audio> <text> <locale>');
    exit(2);
  }
  final client = TonePerfect(); // reads TONEPERFECT_API_KEY
  try {
    final result = await client.assess(await File(args[0]).readAsBytes(), filename: args[0], text: args[1], language: args[2]);
    print('model: ${result.modelVersion} | request: ${result.id} | engine: ${result.engine} | test: ${result.test}');
    print('billing: ${result.billing.credits} credit(s), source ${result.billing.source}');
    if (!result.assessable) {
      print('not assessable: ${result.reason}');
      return;
    }
    for (final word in result.words) {
      final flagged = word.phones.where((p) => p.decision == 'review').map((p) => '${p.dimension} ${p.expected}->${p.heard}');
      print('${word.word}\t${word.score}\t${word.decision ?? ''}\t${flagged.join(', ')}');
    }
  } on PaymentRequiredError catch (e) {
    stderr.writeln('${e.code}: ${e.message} Fix it at ${e.billingUrl}');
  } on TonePerfectError catch (e) {
    stderr.writeln('${e.status} ${e.code}: ${e.message} (request ${e.requestId})');
  } finally {
    client.close();
  }
}
