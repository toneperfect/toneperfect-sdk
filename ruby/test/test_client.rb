# frozen_string_literal: true

# Contract tests against testing/mock_api.py (a local stand-in that follows the live gateway's rules).
require "minitest/autorun"
require "json"
require "net/http"
require "toneperfect"

HELLO = File.expand_path("../../testing/fixtures/hello.ogg", __dir__)
MOCK = File.expand_path("../../testing/mock_api.py", __dir__)

module MockServers
  @servers = {}
  def self.url(gateway)
    @servers[gateway] ||= begin
      io = IO.popen(["python3", MOCK, "--gateway", gateway])
      at_exit { Process.kill("TERM", io.pid) rescue nil }
      io.gets.strip
    end
  end
end

module Contract
  def client(**kw) = TonePerfect::Client.new(api_key: "tp_test_mock", base_url: url, **kw)
  def url = MockServers.url(gateway)

  def attempts(key)
    JSON.parse(Net::HTTP.get(URI("#{url}/_mock/log"))).select { |e| e["idempotency_key"] == key }
  end

  def test_request_and_typed_result
    result = client.assess(HELLO, text: "你好", language: "zh-CN", task: "connected_speech")
    sent = attempts(result.idempotency_key).first
    assert_match(/\A[0-9a-f-]{36}\z/, result.idempotency_key)
    assert_equal "Bearer", sent["auth_scheme"]
    assert_equal({ "language" => "zh-CN", "task" => "connected_speech", "text" => "你好" }, sent["fields"])
    assert_equal %w[hello.ogg audio/ogg], [sent["audio"]["filename"], sent["audio"]["content_type"]]
    assert_equal "toneperfect-ruby/#{TonePerfect::VERSION}", sent["user_agent"]
    assert result.assessable? && result.test?
    assert_equal 78.0, result.overall
    assert_equal %w[你 好], result.words.map(&:word)
    assert_equal %w[initial final tone], result.words[0].phones.map(&:dimension)
    assert_equal [0, "test"], [result.billing.credits, result.billing.source]
    assert_equal "primary", result.engine
  end

  def test_compact_maps_to_the_same_fields
    result = File.open(HELLO, "rb") { |f| client.assess(f, text: "I like sunny days", language: "en-US", compact: true) }
    assert result.compact?
    assert_equal %w[I like sunny days], result.words.map(&:word)
    assert_equal "phoneme", result.words[1].phones[0].dimension
  end

  def test_replay_with_the_same_key
    key = TonePerfect.new_idempotency_key
    first = client.assess(HELLO, text: "你好", language: "zh-CN", idempotency_key: key)
    again = client.assess(HELLO, text: "你好", language: "zh-CN", idempotency_key: key)
    assert_equal first.id, again.id
    assert again.replayed?
  end

  def test_retries_with_the_same_key
    result = client(headers: { "X-Mock-Fail" => "gateway_busy:2" }).assess(HELLO, text: "你好", language: "zh-CN")
    assert_equal 3, attempts(result.idempotency_key).size
    result = client(headers: { "X-Mock-Fail" => "html502:1" }).assess(HELLO, text: "你好", language: "zh-CN")
    assert_equal 2, attempts(result.idempotency_key).size
    error = assert_raises(TonePerfect::ServerError) do
      client(max_retries: 0, headers: { "X-Mock-Fail" => "engine_unavailable:1" }).assess(HELLO, text: "你好", language: "zh-CN")
    end
    assert error.retryable? && !error.needs_new_key?
    error = assert_raises(TonePerfect::RateLimitError) { client(max_retries: 1).assess(HELLO, text: "你好", language: "zh-CN", test_outcome: "rate_limit") }
    assert_equal 2, attempts(error.idempotency_key).size
  end

  def test_finalized_failure_needs_a_new_key
    error = assert_raises(TonePerfect::ValidationError) { client.assess(HELLO, text: "你好", language: "zh-CN", test_outcome: "invalid_assessment") }
    assert error.finalized? && error.needs_new_key? && !error.retryable?
    assert error.id.start_with?("req_")
    assert_equal 1, attempts(error.idempotency_key).size
  end

  def test_payment_required_carries_a_billing_link
    error = assert_raises(TonePerfect::PaymentRequiredError) { client.assess(HELLO, text: "你好", language: "zh-CN", test_outcome: "subscription_required") }
    assert_equal "subscription_required", error.code
    assert_equal TonePerfect::BILLING_URL, error.billing_url
    assert_includes error.message, error.billing_url
    refute error.retryable?
    return unless gateway == "1110"

    assert_equal "Starter", error.plan["name"]
    assert_equal "https://api.toneperfect.app/pricing/", error.pricing_url
  end

  def test_authentication_timeout_and_required_language
    assert_raises(TonePerfect::AuthenticationError) { TonePerfect::Client.new(api_key: "nope", base_url: url).assess(HELLO, text: "你好", language: "zh-CN") }
    error = assert_raises(TonePerfect::APIConnectionError) do
      client(timeout: 0.3, max_retries: 0, headers: { "X-Mock-Delay" => "1" }).assess(HELLO, text: "你好", language: "zh-CN")
    end
    assert_equal [0, "timeout", true], [error.status, error.code, error.retryable?]
    assert_raises(ArgumentError) { client.assess(HELLO, text: "你好") }
  end

  def test_other_endpoints
    assert_includes client.capabilities["languages"].map { |l| l["locale"] }, "zh-CN"
    assert client.lint("你好", language: "zh-CN")["ok"]
    assert client.status.key?("status")
  end
end

class TestContractLive < Minitest::Test
  include Contract
  def gateway = "live"
end

class TestContract1110 < Minitest::Test
  include Contract
  def gateway = "1110"
end

class TestDefaults < Minitest::Test
  def test_environment_defaults
    ENV["TONEPERFECT_BASE_URL"] = "http://example.invalid/"
    ENV["TONEPERFECT_API_KEY"] = "tp_test_env"
    c = TonePerfect::Client.new
    assert_equal ["http://example.invalid", "tp_test_env", 2, 60], [c.base_url, c.api_key, c.max_retries, c.timeout]
  ensure
    ENV.delete("TONEPERFECT_BASE_URL")
    ENV.delete("TONEPERFECT_API_KEY")
  end
end
