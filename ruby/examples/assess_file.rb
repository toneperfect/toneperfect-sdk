# frozen_string_literal: true

# Assess one recording and print what the API returned.
#   export TONEPERFECT_API_KEY=tp_test_...      (or tp_live_... for real scores)
#   ruby -Ilib examples/assess_file.rb hello.ogg 你好 zh-CN
require "toneperfect"

abort "usage: assess_file.rb <audio> <text> <locale>" if ARGV.size < 3
path, text, language = ARGV
client = TonePerfect::Client.new
begin
  result = client.assess(path, text: text, language: language)
rescue TonePerfect::PaymentRequiredError => e
  abort "#{e.code}: #{e.detail} Fix it at #{e.billing_url}"
rescue TonePerfect::Error => e
  abort "#{e.status} #{e.code}: #{e.detail} (request #{e.request_id})"
end
puts "model: #{result.model_version} | request: #{result.id} | engine: #{result.engine} | test: #{result.test?}"
puts "billing: #{result.billing.credits} credit(s), source #{result.billing.source}"
abort "not assessable: #{result.reason}" unless result.assessable?
result.words.each do |word|
  flagged = word.phones.select { |p| p.decision == "review" }.map { |p| "#{p.dimension} #{p.expected}->#{p.heard}" }
  puts [word.word, word.score, word.decision, flagged.join(", ")].join("\t")
end
