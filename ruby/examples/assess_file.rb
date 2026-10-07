# frozen_string_literal: true

# Usage: TONEPERFECT_API_KEY=tp_live_... ruby -Ilib examples/assess_file.rb hello.wav "你好" zh-CN
require "toneperfect"

path, text, language = ARGV
abort "usage: assess_file.rb AUDIO TEXT [LANGUAGE]" unless path && text

client = TonePerfect::Client.new
begin
  result = client.assess(path, text: text, language: language || "zh-CN")
  if result.assessable?
    puts "overall #{result.overall}  #{result.scores.reject { |_, v| v.nil? }}"
    result.words.each do |word|
      flagged = (word["phones"] || []).select { |p| p["decision"] == "review" }
      puts "  #{word['word']}: #{word['score']}#{flagged.empty? ? '' : "  review: #{flagged.map { |p| "#{p['expected']}->#{p['heard']}" }.join(', ')}"}"
    end
  else
    puts "not assessable: #{result.reason} (no credits charged)"
  end
  puts "billing #{result.billing}"
rescue TonePerfect::PaymentRequiredError => e
  warn "#{e.code}: #{e.detail} — see https://api.toneperfect.app/dashboard"
rescue TonePerfect::Error => e
  warn "#{e.status} #{e.code}: #{e.detail} (retry with the same key: #{e.retryable?})"
end
