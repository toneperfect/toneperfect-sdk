<?php
// Usage: TONEPERFECT_API_KEY=tp_live_... php examples/assess_file.php hello.wav "你好" zh-CN
declare(strict_types=1);
require __DIR__ . '/../src/TonePerfect.php'; // or: require 'vendor/autoload.php';

[$_, $path, $text, $language] = $argv + [null, null, null, 'zh-CN'];
if (!$path || !$text) { fwrite(STDERR, "usage: assess_file.php AUDIO TEXT [LANGUAGE]\n"); exit(2); }

$client = new TonePerfect\Client();
try {
    $result = $client->assess($path, ['text' => $text, 'language' => $language]);
    if (!$result->assessable()) {
        echo "not assessable: {$result->reason()} (no credits charged)\n";
        exit(0);
    }
    echo "overall {$result->overall()}\n";
    foreach ($result->words() as $word) echo "  {$word['word']}: {$word['score']}\n";
    echo 'billing ' . json_encode($result->billing()) . "\n";
} catch (TonePerfect\PaymentRequiredError $e) {
    fwrite(STDERR, "{$e->code()}: {$e->detail} — see https://api.toneperfect.app/dashboard\n");
} catch (TonePerfect\TonePerfectException $e) {
    fwrite(STDERR, "{$e->status} {$e->code()}: {$e->detail} (retry with the same key: " . var_export($e->retryable(), true) . ")\n");
}
