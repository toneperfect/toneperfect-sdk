<?php
// Assess one recording and print what the API returned.
//   export TONEPERFECT_API_KEY=tp_test_...      (or tp_live_... for real scores)
//   php examples/assess_file.php hello.ogg 你好 zh-CN
declare(strict_types=1);
require __DIR__ . '/../src/TonePerfect.php';

use TonePerfect\{Client, PaymentRequiredError, TonePerfectException};

if ($argc < 4) { fwrite(STDERR, "usage: assess_file.php <audio> <text> <locale>\n"); exit(2); }
[, $path, $text, $language] = $argv;
$client = new Client();
try {
    $result = $client->assess($path, text: $text, language: $language);
} catch (PaymentRequiredError $e) {
    fwrite(STDERR, "{$e->code()}: {$e->detail} Fix it at {$e->billingUrl}\n"); exit(1);
} catch (TonePerfectException $e) {
    fwrite(STDERR, "{$e->status} {$e->code()}: {$e->detail} (request {$e->requestId})\n"); exit(1);
}
echo 'model: ', $result->modelVersion(), ' | request: ', $result->id(), ' | engine: ', $result->engine(), ' | test: ', var_export($result->test(), true), "\n";
echo 'billing: ', $result->billing()->credits, ' credit(s), source ', $result->billing()->source, "\n";
if (!$result->assessable()) { echo 'not assessable: ', $result->reason(), "\n"; exit(1); }
foreach ($result->words() as $word) {
    $flagged = array_map(fn ($p) => "{$p->dimension} {$p->expected}->{$p->heard}", array_filter($word->phones, fn ($p) => $p->decision === 'review'));
    echo implode("\t", [$word->word, $word->score, $word->decision, implode(', ', $flagged)]), "\n";
}
