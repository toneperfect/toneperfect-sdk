# frozen_string_literal: true

# TonePerfect pronunciation assessment API client (Ruby 3.0+, standard library only).
#
# Wraps the public endpoints of https://api.toneperfect.app:
#
#   GET  /v1/capabilities   -> languages served, limits, model version (no key)
#   POST /v1/assess         -> score one scripted recording
#   POST /v1/lint           -> check a reference text before recording (free, no key)
#   GET  /v1/status         -> synthetic engine probe summary (free, no key)
#
# Accounts, API keys and billing are managed in the web dashboard; those routes are session-based
# and are deliberately not wrapped. Full reference: https://api.toneperfect.app/docs
#
#   require "toneperfect"
#   client = TonePerfect::Client.new           # reads TONEPERFECT_API_KEY
#   result = client.assess("hello.ogg", text: "你好", language: "zh-CN")
#   puts result.assessable?, result.overall, result.billing.credits
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module TonePerfect
  VERSION = "0.3.0"
  DEFAULT_BASE_URL = "https://api.toneperfect.app"
  # Where a 402 is fixed. A 402 from the API may carry its own billing_url.
  BILLING_URL = "https://api.toneperfect.app/dashboard?tab=billing"
  TASKS = %w[general connected_speech isolated_word].freeze
  # Outcomes a tp_test_ key can rehearse (test_outcome: on Client#assess).
  TEST_OUTCOMES = %w[success unassessable invalid_assessment engine_unavailable subscription_required
                     subscription_past_due insufficient_credits account_busy rate_limit].freeze
  # Values of +decision+. review / uncertain / no_correction are the feedback decisions; unassessable,
  # partial and legacy_correction also occur. Treat unknown values as "no decision".
  DECISIONS = %w[review uncertain no_correction unassessable partial legacy_correction].freeze
  # Error codes after which the SAME Idempotency-Key is retried: nothing was stored under it.
  RETRY_SAME_KEY_CODES = %w[rate_limit account_busy uploads_in_progress gateway_busy decoder_busy audio_decoder_unavailable
                            upload_timeout request_pending request_interrupted engine_unavailable result_held
                            timeout network_error].freeze
  # Error codes that mean the key is spent: start a new attempt with a new key.
  NEW_KEY_CODES = %w[idempotency_expired idempotency_conflict].freeze
  # free_capacity (429): free credits reached today's shared limit; clears at the next UTC day or with a plan.
  NOT_RETRYABLE_CODES = %w[free_capacity].freeze
  RETRY_STATUSES = [0, 408, 429, 502, 503, 504].freeze
  CONTENT_TYPES = { ".wav" => "audio/wav", ".mp3" => "audio/mpeg", ".m4a" => "audio/mp4", ".mp4" => "audio/mp4", ".aac" => "audio/aac",
                    ".ogg" => "audio/ogg", ".oga" => "audio/ogg", ".opus" => "audio/ogg", ".webm" => "audio/webm", ".flac" => "audio/flac" }.freeze

  # A fresh Idempotency-Key (a UUID) for one recording attempt. Client#assess makes one per call and
  # reuses it for its own retries; pass your own to resend the same recording safely across restarts.
  def self.new_idempotency_key
    SecureRandom.uuid
  end

  # Base class of every error: each non-2xx response and each transport failure (+status+ 0).
  # +code+ and +detail+ come from the API's +error+ object; branch on +code+.
  # * retryable? — nothing was stored under the key; the client already retried with the SAME key.
  # * needs_new_key? — the failure is stored under the key (finalized?: a 4xx with a req_… +id+ and
  #   +billing+, such as invalid_assessment) or the key expired or conflicts.
  # * otherwise — fix the request (invalid_api_key, invalid_audio, unsupported_language, …).
  class Error < StandardError
    attr_reader :status, :code, :detail, :request_id, :retry_after, :body, :id, :billing,
                :billing_url, :pricing_url, :plan
    attr_accessor :idempotency_key

    def initialize(status, code, message, request_id: nil, retry_after: nil, body: nil, idempotency_key: nil)
      @status = status
      @code = code
      @detail = message
      @request_id = request_id
      @retry_after = retry_after
      @body = body.is_a?(Hash) ? body : {}
      @idempotency_key = idempotency_key
      @id = @body["id"].is_a?(String) ? @body["id"] : nil
      @billing = @body["billing"].is_a?(Hash) ? @body["billing"] : nil
      error = @body["error"].is_a?(Hash) ? @body["error"] : {}
      # 402: where to start, renew or fix a plan (the API's link, else the dashboard billing tab).
      @billing_url = error["billing_url"] || (status == 402 ? BILLING_URL : nil)
      @pricing_url = error["pricing_url"]
      @plan = error["plan"].is_a?(Hash) ? error["plan"] : nil
      text = "#{status} #{code}: #{message}"
      text += " (#{@billing_url})" if @billing_url && !message.to_s.include?(@billing_url)
      super(text)
    end

    # A stored result for this key: a 4xx with +id+ and +billing+. A 5xx is never stored.
    def finalized?
      !id.nil? && !billing.nil? && status < 500
    end

    # Start a new attempt with a new Idempotency-Key; the old key replays this response.
    def needs_new_key?
      finalized? || NEW_KEY_CODES.include?(code)
    end

    # Retry later with the SAME Idempotency-Key: nothing was stored under it.
    def retryable?
      return false if finalized? || NEW_KEY_CODES.include?(code) || NOT_RETRYABLE_CODES.include?(code)

      RETRY_SAME_KEY_CODES.include?(code) || RETRY_STATUSES.include?(status)
    end
  end

  # 401: missing, unknown or revoked key. Send +Authorization: Bearer KEY+.
  class AuthenticationError < Error; end
  # 402: nothing charged. subscription_required, subscription_past_due, insufficient_credits or payment_balance_due; see +billing_url+.
  class PaymentRequiredError < Error; end
  # 429: rate_limit, account_busy, uploads_in_progress (retried) or free_capacity (not retried).
  class RateLimitError < Error; end
  # Any other 4xx: the request needs a fix. needs_new_key? tells whether to change the key.
  class ValidationError < Error; end
  # 5xx: never stored, never charged; retried with the same key.
  class ServerError < Error; end
  # Transport failure (status 0): timeout or network_error. The outcome is unknown; retried with the same key.
  class APIConnectionError < Error; end

  def self.error_class(status)
    return APIConnectionError if status.zero?
    return AuthenticationError if status == 401
    return PaymentRequiredError if status == 402
    return RateLimitError if status == 429
    return ServerError if status >= 500
    return ValidationError if status >= 400

    Error
  end

  # Typed view of one JSON object; +row["field"]+ still reads the raw JSON.
  class Row
    attr_reader :data

    def initialize(data)
      @data = data
    end

    def [](key)
      data[key.to_s]
    end
  end

  # One scored unit under a word: a phoneme, or a Mandarin initial, final or tone.
  class Phone < Row
    def dimension = data["dimension"]
    def expected = data["expected"]
    def heard = data["heard"]
    def score = data["score"]
    def decision = data["decision"]
  end

  # One word (one character in Mandarin). Full and compact responses map to the same methods.
  class Word < Row
    def word = data.key?("word") ? data["word"] : data["text"]
    def score = data["score"]
    def start_ms = data["start_ms"]
    def end_ms = data["end_ms"]
    def decision = data["decision"]
    def pinyin = data["pinyin"]

    def phones
      list = data["phones"].is_a?(Array) ? data["phones"] : Array(data["units"])
      list.select { |p| p.is_a?(Hash) }.map { |p| Phone.new(p) }
    end
  end

  # What the request cost: +credits+, +balance_credits+, +free_credits+, +source+ (free, plan or test).
  class Billing < Row
    def credits = data["credits"].to_i
    def balance_credits = data["balance_credits"]
    def free_credits = data["free_credits"]
    def source = data["source"]
  end

  # One POST /v1/assess result. +data+ is the JSON body as returned (full or compact schema).
  class Assessment
    attr_reader :data, :status, :headers, :request_id, :idempotency_key

    def initialize(data, status, headers, idempotency_key)
      @data = data
      @status = status
      @headers = headers
      @request_id = headers["x-request-id"]
      @idempotency_key = headers["idempotency-key"] || idempotency_key
    end

    def replayed? = headers["idempotent-replayed"].to_s.casecmp("true").zero?
    def id = data["id"] || request_id
    # false when the recording could not be scored (see +reason+). Free, and never a score of zero.
    def assessable? = data["assessable"] == true
    def reason = data["reason"]
    # 0–100 display grades per dimension; nil = not measured by this pack.
    def scores = data["scores"] || {}
    def overall = scores["overall"]
    def words = Array(data["words"]).select { |w| w.is_a?(Hash) }.map { |w| Word.new(w) }
    def warnings = Array(data["warnings"]).select { |w| w.is_a?(String) }
    def billing = Billing.new(data["billing"] || {})
    def model_version = data["model_version"]
    # "primary" or "fallback".
    def engine = data.dig("engine_route", "engine") || headers["x-toneperfect-engine"]
    # true for a fixed example response from a tp_test_ key.
    def test? = data["test"] == true
    def compact? = data["schema"] == "toneperfect.compact.v1"
  end

  Response = Struct.new(:status, :headers, :body)

  # Client for https://api.toneperfect.app.
  class Client
    attr_reader :api_key, :base_url, :timeout, :max_retries, :headers, :user_agent

    # +api_key+: tp_live_… or a tp_test_… test key (default: ENV["TONEPERFECT_API_KEY"]).
    # +base_url+: default ENV["TONEPERFECT_BASE_URL"], else https://api.toneperfect.app (a proxy with a 26 s
    # limit: a longer assessment comes back on the automatic retry, charged once).
    # +timeout+: seconds per request. +max_retries+: automatic retries of a retryable failure with the same key.
    # +headers+: extra headers for every request, e.g. { "TonePerfect-Fallback" => "off" }.
    def initialize(api_key: nil, base_url: nil, timeout: 60, max_retries: 2, headers: {}, user_agent: nil, transport: nil)
      @api_key = api_key || ENV.fetch("TONEPERFECT_API_KEY", "")
      @base_url = (base_url || ENV["TONEPERFECT_BASE_URL"] || DEFAULT_BASE_URL).sub(%r{/+\z}, "")
      @timeout = timeout
      @max_retries = [max_retries.to_i, 0].max
      @headers = headers.dup
      @user_agent = user_agent || "toneperfect-ruby/#{VERSION}"
      @transport = transport || method(:net_http_transport)
    end

    # GET /v1/capabilities (no key): languages, limits, model_version.
    def capabilities
      call("GET", "/v1/capabilities", {}, nil).first
    end

    # POST /v1/lint (free, no key): {"ok", "language", "issues", "units"}.
    def lint(text, language:, pinyin: "", task: "general")
      raise ArgumentError, "language is required, for example \"en-US\" or \"zh-CN\"" if blank?(language)

      body = JSON.generate("text" => text.to_s, "language" => language, "pinyin" => pinyin.to_s, "task" => task)
      call("POST", "/v1/lint", { "Content-Type" => "application/json" }, body).first
    end

    # GET /v1/status (no key): the synthetic engine probe.
    def status
      call("GET", "/v1/status", {}, nil).first
    end

    # POST /v1/assess: score one scripted recording (WAV, MP3, M4A, Ogg or WebM, 0.15–120 s, up to 10 MB).
    # +audio+ is a path, a binary String or an IO. +language+ is required. Raises a TonePerfect::Error subclass.
    def assess(audio, language:, text: nil, pinyin: nil, task: "general", idempotency_key: nil, filename: nil,
               content_type: nil, compact: false, test_outcome: nil)
      raise AuthenticationError.new(401, "invalid_api_key", "Set api_key or the TONEPERFECT_API_KEY environment variable.") if blank?(api_key)
      raise ArgumentError, "language is required, for example \"en-US\" or \"zh-CN\"" if blank?(language)
      raise ArgumentError, "task must be one of #{TASKS.join(', ')}" unless TASKS.include?(task)
      raise ArgumentError, "Provide text (or, for Mandarin, pinyin with tones)." if blank?(text) && blank?(pinyin)

      key = idempotency_key || TonePerfect.new_idempotency_key
      raise ArgumentError, "idempotency_key must be 1-255 printable ASCII characters" unless key.match?(/\A[\x20-\x7e]{1,255}\z/)

      data, name = read_audio(audio)
      name = filename || name || "recording"
      ctype = content_type || CONTENT_TYPES.fetch(File.extname(name).downcase, "application/octet-stream")
      fields = { "language" => language, "task" => task }
      fields["text"] = text unless blank?(text)
      fields["pinyin"] = pinyin unless blank?(pinyin)
      body, boundary = multipart(fields, "audio", name, ctype, data)
      extra = { "Authorization" => "Bearer #{api_key}", "Idempotency-Key" => key,
                "Content-Type" => "multipart/form-data; boundary=#{boundary}" }
      extra["TonePerfect-Response"] = "compact" if compact
      extra["TonePerfect-Test-Outcome"] = test_outcome.to_s if test_outcome
      result, resp = call("POST", "/v1/assess", extra, body, key)
      Assessment.new(result, resp.status, resp.headers, key)
    end

    private

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def call(method, path, extra, body, key = nil)
      attempt = 0
      begin
        resp = send_request(method, path, extra, body)
        [parse_json(resp, key), resp]
      rescue Error => e
        e.idempotency_key ||= key
        raise if attempt >= max_retries || !e.retryable?

        sleep(backoff(e, attempt))
        attempt += 1
        retry
      end
    end

    def backoff(error, attempt)
      return error.retry_after.clamp(0, 30) if error.retry_after

      base = error.code == "engine_unavailable" ? 2.0 : 0.5
      [base * (2**attempt), 8.0].min + rand * 0.25
    end

    def send_request(method, path, extra, body)
      all = { "Accept" => "application/json", "User-Agent" => user_agent }.merge(headers).merge(extra)
      resp = @transport.call(method, base_url + path, all, body)
      Response.new(resp.status.to_i, (resp.headers || {}).transform_keys { |k| k.to_s.downcase }, resp.body.to_s)
    rescue Error
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      raise APIConnectionError.new(0, "timeout", "No response within #{timeout}s; the outcome is unknown, retry with the same Idempotency-Key.")
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, EOFError => e
      raise APIConnectionError.new(0, "network_error", "Could not reach #{base_url}: #{e.message}")
    end

    def net_http_transport(method, url, headers, body)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout if http.respond_to?(:write_timeout=)
      req = method == "POST" ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      res = http.request(req)
      hdrs = {}
      res.each_header { |k, v| hdrs[k.downcase] = v }
      Response.new(res.code.to_i, hdrs, res.body.to_s)
    end

    def parse_json(resp, key)
      data = begin
        resp.body.empty? ? {} : JSON.parse(resp.body)
      rescue JSON::ParserError
        nil
      end
      return data if resp.status.between?(200, 299) && data.is_a?(Hash)

      retry_after = begin
        resp.headers["retry-after"] ? Float(resp.headers["retry-after"]) : nil
      rescue ArgumentError
        nil
      end
      klass = TonePerfect.error_class(resp.status)
      rid = resp.headers["x-request-id"]
      if data.is_a?(Hash) && data["error"].is_a?(Hash)
        err = data["error"]
        raise klass.new(resp.status, (err["code"] || "request_error").to_s, err["message"].to_s,
                        request_id: data["request_id"] || rid, retry_after: retry_after, body: data, idempotency_key: key)
      end
      if data.is_a?(Hash) && data["detail"].is_a?(String) # framework errors (405 on a trailing slash)
        raise klass.new(resp.status, "http_error", data["detail"], request_id: rid, retry_after: retry_after, body: data, idempotency_key: key)
      end
      snippet = resp.body.dup.force_encoding(Encoding::UTF_8).scrub[0, 200].strip
      raise klass.new(resp.status, "http_error", snippet.empty? ? "HTTP #{resp.status}" : snippet,
                      request_id: rid, retry_after: retry_after, idempotency_key: key)
    end

    def read_audio(audio)
      if audio.respond_to?(:read)
        data = audio.read
        raise TypeError, "Open audio files in binary mode ('rb')." unless data.is_a?(String)

        name = audio.respond_to?(:path) && audio.path ? File.basename(audio.path) : nil
        return [data.b, name]
      end
      return [File.binread(audio.to_path), File.basename(audio.to_path)] if audio.respond_to?(:to_path)
      raise TypeError, "audio must be a path, a binary String or an IO" unless audio.is_a?(String)

      # A binary (ASCII-8BIT) String is audio bytes; any other String is a file path.
      audio.encoding == Encoding::BINARY ? [audio, nil] : [File.binread(audio), File.basename(audio)]
    end

    def multipart(fields, file_field, filename, content_type, data)
      boundary = "----toneperfect#{SecureRandom.hex(16)}"
      out = String.new(encoding: Encoding::BINARY)
      fields.each do |name, value|
        out << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n".b
        out << value.to_s.dup.force_encoding(Encoding::BINARY) << "\r\n".b
      end
      safe = filename.to_s.tr('"', "_").delete("\r\n")
      out << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{file_field}\"; filename=\"#{safe}\"\r\nContent-Type: #{content_type}\r\n\r\n".b.force_encoding(Encoding::BINARY)
      out << data.b << "\r\n--#{boundary}--\r\n".b
      [out, boundary]
    end
  end
end
