# frozen_string_literal: true

# TonePerfect pronunciation assessment API client (Ruby 2.7+, standard library only).
#
# Wraps the two public endpoints of https://api.toneperfect.app:
#
#   GET  /v1/capabilities   -> languages served, limits, model version
#   POST /v1/assess         -> score one scripted recording
#
# Accounts, API keys and billing are managed in the web dashboard
# (https://api.toneperfect.app/dashboard); those routes are session-based and are
# deliberately not wrapped. Full reference: https://api.toneperfect.app/docs
#
#   require "toneperfect"
#   client = TonePerfect::Client.new(api_key: "tp_live_...")
#   result = client.assess("hello.wav", text: "你好", language: "zh-CN")
#   puts result.assessable?, result.overall, result.billing
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "uri"

module TonePerfect
  VERSION = "0.1.0"
  DEFAULT_BASE_URL = "https://api.toneperfect.app"
  TASKS = %w[general connected_speech isolated_word].freeze
  # Values of +decision+ on words and phones. review / uncertain / no_correction are the feedback
  # decisions; unassessable, partial and legacy_correction also occur. Treat unknown values as "no decision".
  DECISIONS = %w[review uncertain no_correction unassessable partial legacy_correction].freeze
  # Error codes after which the SAME Idempotency-Key must be retried: nothing was finalized.
  RETRY_SAME_KEY_CODES = %w[rate_limit account_busy gateway_busy decoder_busy audio_decoder_unavailable
                            upload_timeout request_pending timeout network_error].freeze
  # Error codes that mean the key is spent: start a new attempt with a new key.
  NEW_KEY_CODES = %w[idempotency_expired idempotency_conflict].freeze
  # Error codes a retry cannot fix soon. free_capacity (429): free credits reached today's shared
  # limit; it clears at the next UTC day, or immediately with a paid plan.
  NOT_RETRYABLE_CODES = %w[free_capacity].freeze
  RETRY_STATUSES = [408, 429, 502, 503, 504].freeze
  IDEMPOTENCY_RE = /\A[A-Za-z0-9_.:-]{8,128}\z/.freeze

  # A fresh Idempotency-Key for one recording attempt. Keep the same key while the result is
  # unknown or pending (Error#retryable?); use a new key for a different attempt or after a
  # definite failed response (Error#needs_new_key?). Never generate one inside an automatic retry loop.
  def self.new_idempotency_key(prefix = "tp")
    key = "#{prefix}-#{SecureRandom.uuid.delete('-')}-#{SecureRandom.hex(2)}"
    raise ArgumentError, "prefix must be letters, digits, dots, dashes, underscores or colons" unless IDEMPOTENCY_RE.match?(key)

    key
  end

  # Raised for any non-2xx response, and for transport failures (+status+ 0).
  #
  # +code+ and +message+ come from the API's +error+ object. A non-JSON body (for example an
  # HTML 502 from a proxy) gets code "http_error" and the raw text as the message.
  # What to do next is decided by the BODY, not the status:
  # * finalized? — the failure was stored under this Idempotency-Key (body carries a req_… +id+
  #   and +billing+ with credits 0). The same key replays it for 24 h: needs_new_key? is true.
  # * retryable? — nothing was finalized; retry later with the SAME key.
  # * anything else (invalid_api_key, insufficient_credits, invalid_audio, …) needs a fix on your side.
  class Error < StandardError
    attr_reader :status, :code, :detail, :request_id, :retry_after, :body, :id, :billing

    def initialize(status, code, message, request_id: nil, retry_after: nil, body: nil)
      super("#{status} #{code}: #{message}")
      @status = status
      @code = code
      @detail = message
      @request_id = request_id
      @retry_after = retry_after
      @body = body.is_a?(Hash) ? body : {}
      @id = @body["id"].is_a?(String) ? @body["id"] : nil
      @billing = @body["billing"].is_a?(Hash) ? @body["billing"] : nil
    end

    # The failure is a stored result for this key (+id+ + +billing+ present).
    def finalized?
      !@id.nil? && !@billing.nil?
    end

    # Start a new attempt with a new Idempotency-Key; the old key replays this response.
    def needs_new_key?
      finalized? || NEW_KEY_CODES.include?(@code)
    end

    # Retry later with the SAME Idempotency-Key: nothing was finalized.
    def retryable?
      return false if finalized? || NEW_KEY_CODES.include?(@code) || NOT_RETRYABLE_CODES.include?(@code)

      RETRY_SAME_KEY_CODES.include?(@code) || RETRY_STATUSES.include?(@status)
    end
  end

  # 401 — missing, revoked or unknown API key (invalid_api_key).
  class AuthenticationError < Error; end
  # 402 — nothing was charged. code: subscription_required (the 50 free credits are used up and there
  # is no active plan), insufficient_credits or payment_balance_due. Fix it in the dashboard.
  class PaymentRequiredError < Error; end
  # 429 — rate_limit (60/min) or account_busy (2 running): retry with the SAME key after retry_after.
  # free_capacity (free credits hit today's shared limit) is not retryable: it clears at the next UTC day.
  class RateLimitError < Error; end
  # Other 4xx — the request needs a fix (invalid_audio, unsupported_language, upload_too_large, …).
  class ValidationError < Error; end
  # 5xx — engine_unavailable, request_interrupted or a proxy 502/504. Check retryable? / needs_new_key?.
  class ServerError < Error; end
  # Transport failure (status 0): timeout or network_error. The outcome is unknown: retry with the same key.
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

  # One POST /v1/assess result. +data+ is the full JSON body exactly as returned by the API.
  class Assessment
    attr_reader :data, :status, :headers, :request_id

    def initialize(data, status, headers)
      @data = data
      @status = status
      @headers = headers
      @request_id = headers["x-request-id"]
    end

    # True when the result was replayed from a previous identical request (not charged again).
    def replayed?
      headers["idempotent-replayed"].to_s.downcase == "true"
    end

    # false when the audio could not be meaningfully scored (silence, wrong sentence, unreadable).
    # Never show an unassessable result as a score of zero; see #reason.
    def assessable?
      data["assessable"] ? true : false
    end

    def reason
      data["reason"]
    end

    # 0-100 display grades per dimension; nil means the dimension is not supported by this pack.
    def scores
      data["scores"] || {}
    end

    def overall
      scores["overall"]
    end

    # Per word/character rows: score, start_ms/end_ms and phones (expected, heard, score, decision).
    def words
      data["words"] || []
    end

    # {"credits" => charged, "balance_credits" => remaining}; failed or unassessable requests charge 0.
    def billing
      data["billing"] || {}
    end

    def model_version
      data["model_version"]
    end

    # Result id (req_…), also returned in the X-Request-Id header.
    def id
      data["id"] || request_id
    end
  end

  # Raw transport response: status, lower-cased header hash, body string.
  Response = Struct.new(:status, :headers, :body)

  # Client for https://api.toneperfect.app.
  class Client
    attr_reader :api_key, :base_url, :timeout, :user_agent

    # api_key:  secret key from the dashboard (tp_live_...). Defaults to ENV["TONEPERFECT_API_KEY"].
    # base_url: API origin. api.toneperfect.app goes through a proxy with a 26-second request timeout;
    #           if your assessments run longer, ask nik@toneperfect.app for the direct gateway address.
    # timeout:  seconds for open/read/write of each request (default 90).
    # transport: optional callable (method, url, headers, body) -> TonePerfect::Response, for tests/proxies.
    def initialize(api_key: nil, base_url: DEFAULT_BASE_URL, timeout: 90, user_agent: nil, transport: nil)
      @api_key = api_key || ENV.fetch("TONEPERFECT_API_KEY", "")
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @timeout = timeout
      @user_agent = user_agent || "toneperfect-ruby/#{VERSION}"
      @transport = transport || method(:net_http_transport)
    end

    # GET /v1/capabilities: languages (locale, status, dimensions, limitations), limits, model_version.
    # No API key required.
    def capabilities
      resp = send_request("GET", "/v1/capabilities", {}, nil)
      parse_json(resp)
    end

    # POST /v1/assess: score one scripted recording against its reference text.
    #
    # audio:    a path, a binary String, or an IO opened in binary mode. Up to 30 s and 10 MB.
    # text:     what the learner was asked to read. Required unless pinyin is given (Mandarin only).
    # language: locale such as zh-CN, en-US, fr-FR — see #capabilities.
    # pinyin:   optional explicit Mandarin reading with numbered tones, e.g. "ni3 hao3".
    # task:     general (default), connected_speech or isolated_word.
    # idempotency_key: unique per recording attempt; generated when omitted. Retry with the same key
    #           and identical inputs when the outcome is unknown (Error#retryable?).
    def assess(audio, text: nil, language: "zh-CN", pinyin: nil, task: "general", idempotency_key: nil,
               filename: "recording.wav", content_type: "application/octet-stream")
      if api_key.nil? || api_key.empty?
        raise AuthenticationError.new(401, "invalid_api_key", "Set api_key or the TONEPERFECT_API_KEY environment variable.")
      end
      raise ArgumentError, "task must be one of #{TASKS.join(', ')}" unless TASKS.include?(task)
      raise ArgumentError, "Provide text (or pinyin for Mandarin)." if blank?(text) && blank?(pinyin)

      key = idempotency_key || TonePerfect.new_idempotency_key
      unless IDEMPOTENCY_RE.match?(key)
        raise ArgumentError, "idempotency_key must be 8-128 letters, digits, dots, dashes, underscores or colons"
      end

      fields = { "language" => language, "task" => task }
      fields["text"] = text unless blank?(text)
      fields["pinyin"] = pinyin unless blank?(pinyin)
      body, boundary = multipart(fields, "audio", filename, content_type, read_audio(audio))
      headers = {
        "Authorization" => "Bearer #{api_key}",
        "Idempotency-Key" => key,
        "Content-Type" => "multipart/form-data; boundary=#{boundary}"
      }
      resp = send_request("POST", "/v1/assess", headers, body)
      Assessment.new(parse_json(resp), resp.status, resp.headers)
    end

    private

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    def send_request(method, path, headers, body)
      all = { "Accept" => "application/json", "User-Agent" => user_agent }.merge(headers)
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

    def parse_json(resp)
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
      if data.is_a?(Hash) && data["error"].is_a?(Hash)
        err = data["error"]
        raise klass.new(resp.status, (err["code"] || "request_error").to_s, err["message"].to_s,
                        request_id: data["request_id"] || resp.headers["x-request-id"], retry_after: retry_after, body: data)
      end
      snippet = resp.body.dup.force_encoding(Encoding::UTF_8).scrub[0, 200].strip
      raise klass.new(resp.status, "http_error", snippet.empty? ? "HTTP #{resp.status}" : snippet,
                      request_id: resp.headers["x-request-id"], retry_after: retry_after)
    end

    def read_audio(audio)
      if audio.respond_to?(:read)
        data = audio.read
        raise TypeError, "Open audio files in binary mode ('rb')." unless data.is_a?(String)

        return data.b
      end
      return File.binread(audio.to_path) if audio.respond_to?(:to_path)
      raise TypeError, "audio must be a path, a binary String or an IO" unless audio.is_a?(String)

      # A binary (ASCII-8BIT) String is audio bytes; any other String is a file path.
      audio.encoding == Encoding::BINARY ? audio : File.binread(audio)
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
