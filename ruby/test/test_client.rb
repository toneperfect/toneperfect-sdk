# frozen_string_literal: true

# Offline tests: the transport is faked (plus one loopback TCP server); nothing touches the network.
# Run: ruby -Ilib -Itest test/test_client.rb
require "minitest/autorun"
require "socket"
require "stringio"
require "tempfile"
require "toneperfect"

class FakeTransport
  attr_reader :calls

  def initialize(status, body, headers = {})
    @status = status
    @body = body.is_a?(String) ? body : JSON.generate(body)
    @headers = headers
    @calls = []
  end

  def call(method, url, headers, body)
    @calls << { method: method, url: url, headers: headers, body: body }
    TonePerfect::Response.new(@status, @headers, @body)
  end
end

class ClientTest < Minitest::Test
  OK_BODY = { "assessable" => true, "scores" => { "overall" => 86, "tone" => 80, "fluency" => nil },
              "words" => [{ "word" => "你", "score" => 94 }], "billing" => { "credits" => 1, "balance_credits" => 2499 },
              "model_version" => "mandarin-human-v2-x", "id" => "req_1" }.freeze

  def client(transport, api_key: "tp_live_test")
    TonePerfect::Client.new(api_key: api_key, base_url: "https://api.toneperfect.app/", transport: transport)
  end

  def test_assess_sends_real_contract
    t = FakeTransport.new(200, OK_BODY, { "X-Request-Id" => "req_1" })
    result = client(t).assess("RIFF....".b, text: "你好", language: "zh-CN", pinyin: "ni3 hao3", task: "connected_speech",
                                            idempotency_key: "lesson-42-attempt-1", filename: "hello.wav")
    call = t.calls.first
    assert_equal "POST", call[:method]
    assert_equal "https://api.toneperfect.app/v1/assess", call[:url]
    assert_equal "Bearer tp_live_test", call[:headers]["Authorization"]
    assert_equal "lesson-42-attempt-1", call[:headers]["Idempotency-Key"]
    assert_equal "toneperfect-ruby/0.1.0", call[:headers]["User-Agent"]
    assert_match(/\Amultipart\/form-data; boundary=/, call[:headers]["Content-Type"])
    raw = call[:body].dup.force_encoding(Encoding::UTF_8)
    { "text" => "你好", "language" => "zh-CN", "pinyin" => "ni3 hao3", "task" => "connected_speech" }.each do |field, value|
      assert_includes raw, "name=\"#{field}\"\r\n\r\n#{value}\r\n"
    end
    assert_includes raw, 'name="audio"; filename="hello.wav"'
    assert_includes raw, "RIFF...."
    assert_kind_of TonePerfect::Assessment, result
    assert result.assessable?
    assert_equal 86, result.overall
    assert_nil result.scores["fluency"]
    assert_equal 1, result.billing["credits"]
    assert_equal "mandarin-human-v2-x", result.model_version
    assert_equal "req_1", result.id
    assert_equal "你", result.words.first["word"]
    refute result.replayed?
  end

  def test_audio_from_path_and_io
    Tempfile.create(["clip", ".wav"]) do |f|
      f.binmode
      f.write("WAVDATA")
      f.flush
      t = FakeTransport.new(200, OK_BODY)
      client(t).assess(f.path, text: "hi", language: "en-US")
      assert_includes t.calls.last[:body], "WAVDATA"
      client(t).assess(StringIO.new("IODATA".b), text: "hi", language: "en-US")
      assert_includes t.calls.last[:body], "IODATA"
    end
  end

  def test_replay_header_generated_key_unassessable
    t = FakeTransport.new(200, { "assessable" => false, "reason" => "silence", "scores" => { "overall" => nil },
                                 "billing" => { "credits" => 0, "balance_credits" => 5 } }, { "Idempotent-Replayed" => "true" })
    result = client(t).assess(StringIO.new("abc"), text: "hi", language: "en-US")
    assert_match TonePerfect::IDEMPOTENCY_RE, t.calls.first[:headers]["Idempotency-Key"]
    refute_includes t.calls.first[:body], 'name="pinyin"'
    assert result.replayed?
    refute result.assessable?
    assert_equal "silence", result.reason
    assert_equal 0, result.billing["credits"]
  end

  def error_from(status, body, headers = {})
    err = assert_raises(TonePerfect::Error) do
      client(FakeTransport.new(status, body, headers)).assess("x".b, text: "hi", idempotency_key: "lesson-42-attempt-1")
    end
    err
  end

  def test_api_error_is_typed
    e = error_from(402, { "error" => { "code" => "insufficient_credits", "message" => "Purchase a credit pack." }, "request_id" => "req_9" })
    assert_kind_of TonePerfect::PaymentRequiredError, e
    assert_equal [402, "insufficient_credits", "req_9"], [e.status, e.code, e.request_id]
    refute e.retryable?
  end

  def test_errors_typed_by_status
    { 401 => TonePerfect::AuthenticationError, 402 => TonePerfect::PaymentRequiredError, 429 => TonePerfect::RateLimitError,
      422 => TonePerfect::ValidationError, 503 => TonePerfect::ServerError }.each do |status, klass|
      t = FakeTransport.new(status, { "error" => { "code" => "subscription_required", "message" => "m" } })
      e = assert_raises(klass) { client(t).capabilities }
      assert_equal status, e.status
    end
  end

  def test_finalized_failure_needs_new_key
    e = error_from(503, { "error" => { "code" => "engine_unavailable", "message" => "No credits were charged." },
                          "id" => "req_77", "billing" => { "credits" => 0, "balance_credits" => 12 } }, { "idempotent-replayed" => "true" })
    assert_equal "req_77", e.id
    assert_equal({ "credits" => 0, "balance_credits" => 12 }, e.billing)
    assert e.finalized?
    assert e.needs_new_key?
    refute e.retryable?
  end

  def test_not_finalized_failures_retry_same_key
    [[409, "request_pending"], [429, "rate_limit"], [429, "account_busy"], [503, "gateway_busy"], [503, "decoder_busy"],
     [503, "audio_decoder_unavailable"], [408, "upload_timeout"], [503, "engine_unavailable"]].each do |status, code|
      e = error_from(status, { "error" => { "code" => code, "message" => "later" }, "request_id" => "req_x" }, { "retry-after" => "1" })
      assert e.retryable?, code
      refute e.needs_new_key?, code
      refute e.finalized?, code
      assert_equal 1.0, e.retry_after
    end
  end

  def test_spent_keys_and_client_errors
    %w[idempotency_expired idempotency_conflict].each do |code|
      e = error_from(409, { "error" => { "code" => code, "message" => "new key" } })
      assert e.needs_new_key?, code
      refute e.retryable?, code
    end
    [[401, "invalid_api_key"], [402, "insufficient_credits"], [422, "invalid_audio"], [422, "unsupported_language"], [413, "upload_too_large"]].each do |status, code|
      e = error_from(status, { "error" => { "code" => code, "message" => "fix" } })
      refute e.retryable?, code
      refute e.needs_new_key?, code
    end
  end

  def test_non_json_proxy_error
    e = assert_raises(TonePerfect::ServerError) { client(FakeTransport.new(504, "<html>Gateway Timeout</html>")).capabilities }
    assert_equal [504, "http_error"], [e.status, e.code]
    assert e.retryable?
    refute e.needs_new_key?
    e = assert_raises(TonePerfect::ServerError) { client(FakeTransport.new(502, "")).capabilities }
    assert e.retryable?
  end

  def test_transport_failures_keep_same_key
    timeout = ->(*) { raise Net::ReadTimeout }
    e = assert_raises(TonePerfect::APIConnectionError) { client(timeout).assess("x".b, text: "hi") }
    assert_equal [0, "timeout"], [e.status, e.code]
    assert e.retryable?
    refute e.needs_new_key?
    refused = ->(*) { raise Errno::ECONNREFUSED }
    e = assert_raises(TonePerfect::APIConnectionError) { client(refused).assess("x".b, text: "hi") }
    assert_equal "network_error", e.code
    assert e.retryable?
  end

  def test_capabilities_needs_no_key
    t = FakeTransport.new(200, { "languages" => [{ "locale" => "zh-CN", "status" => "experimental" }] })
    caps = client(t, api_key: "").capabilities
    assert_equal "https://api.toneperfect.app/v1/capabilities", t.calls.first[:url]
    assert_equal "GET", t.calls.first[:method]
    assert_nil t.calls.first[:headers]["Authorization"]
    assert_equal "zh-CN", caps["languages"].first["locale"]
  end

  def test_validation
    t = FakeTransport.new(200, {})
    assert_raises(TonePerfect::AuthenticationError) { client(t, api_key: "").assess("x".b, text: "x") }
    assert_raises(ArgumentError) { client(t).assess("x".b, language: "en-US") }
    assert_raises(ArgumentError) { client(t).assess("x".b, text: "x", task: "freestyle") }
    assert_raises(ArgumentError) { client(t).assess("x".b, text: "x", idempotency_key: "short") }
    assert_match TonePerfect::IDEMPOTENCY_RE, TonePerfect.new_idempotency_key("lesson.42")
    assert_raises(ArgumentError) { TonePerfect.new_idempotency_key("bad prefix") }
    assert_empty t.calls
  end

  def test_env_default_key
    ENV["TONEPERFECT_API_KEY"] = "tp_live_env"
    assert_equal "tp_live_env", TonePerfect::Client.new.api_key
  ensure
    ENV.delete("TONEPERFECT_API_KEY")
  end

  # Exercises the real Net::HTTP transport against a loopback socket.
  def test_net_http_transport_end_to_end
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    received = +""
    thread = Thread.new do
      sock = server.accept
      head = +""
      head << sock.readpartial(65_536) until head.include?("\r\n\r\n")
      length = head[/content-length: (\d+)/i, 1].to_i
      body = head.split("\r\n\r\n", 2)[1] || +""
      body << sock.readpartial(65_536) while body.bytesize < length
      received << head
      payload = JSON.generate({ "error" => { "code" => "subscription_required", "message" => "Choose a plan." }, "request_id" => "req_402" })
      sock.write("HTTP/1.1 402 Payment Required\r\nContent-Type: application/json\r\nX-Request-Id: req_402\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      sock.close
    end
    c = TonePerfect::Client.new(api_key: "tp_live_local", base_url: "http://127.0.0.1:#{port}", timeout: 5)
    e = assert_raises(TonePerfect::PaymentRequiredError) { c.assess("RIFF".b, text: "hello", language: "en-US", idempotency_key: "loopback-0001") }
    thread.join
    assert_equal "subscription_required", e.code
    assert_equal "req_402", e.request_id
    assert_match %r{\APOST /v1/assess HTTP/1.1}, received
    assert_match(/authorization: Bearer tp_live_local/i, received)
    assert_match(/idempotency-key: loopback-0001/i, received)
  ensure
    server&.close
  end
end
