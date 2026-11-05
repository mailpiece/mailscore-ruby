require "json"
require "net/http"
require_relative "client/version"

module MailScore
  # A thin client for mailscore's HTTP API, on Net::HTTP alone. See README.md.
  class Client
    # The root of what the client raises: a non-2xx answer with its status and
    # error code, or a body that is not the JSON promised.
    class Error < StandardError
      attr_reader :status, :code

      def initialize(message = nil, status: nil, code: nil)
        @status, @code = status, code
        super((message || [ status, code ].compact.join(" "))[0, 200])
      end
    end

    # A timeout or a connection that failed, with no answer from the server.
    class Unreachable < Error; end

    Result = Data.define(:action, :score, :complete, :symbols, :smtp_reply, :subject) do
      def complete? = complete
    end
    Result::Symbol = Data.define(:name, :weight, :detail, :description) do
      def initialize(name:, weight:, detail:, description: nil) = super
    end
    Result::SmtpReply = Data.define(:code, :enhanced, :text)

    ACTIONS = %i[ no_action add_header rewrite_subject soft_reject reject ].to_h { [ it.to_s.tr("_", " "), it ] }.freeze

    ENVELOPE = { ip: "IP", helo: "Helo", hostname: "Hostname", reverse_dns_status: "Reverse-DNS-Status",
      unconfirmed_hostname: "Unconfirmed-Hostname", from: "From", rcpt: "Rcpt", deliver_to: "Deliver-To",
      user: "User", tls_version: "TLS-Version", tls_cipher: "TLS-Cipher", queue_id: "Queue-Id" }.freeze
    ENVELOPE_LIMIT = 1024
    BODY_LIMIT = 1_048_576
    ERROR_BODY_LIMIT = 4096

    Response = Data.define(:status, :body) do
      def success? = status.between?(200, 299)
    end
    private_constant :Response

    def initialize(url: ENV.fetch("MAILSCORE_URL", "http://localhost:8080"), read_token: ENV["MAILSCORE_READ_TOKEN"],
      write_token: ENV.fetch("MAILSCORE_WRITE_TOKEN", read_token), open_timeout: 1, read_timeout: 10,
      deadline: open_timeout + read_timeout)
      @uri = parse_url(url)
      @read_token, @write_token = read_token, write_token
      @open_timeout, @read_timeout, @deadline = open_timeout, read_timeout, deadline
    end

    def check(message, ip: nil, helo: nil, hostname: nil, reverse_dns_status: nil, unconfirmed_hostname: nil, from: nil, rcpt: nil,
      deliver_to: nil, user: nil, tls_version: nil, tls_cipher: nil, queue_id: nil)
      envelope = { ip:, helo:, hostname:, reverse_dns_status:, unconfirmed_hostname:, from:, rcpt:, deliver_to:, user:, tls_version:, tls_cipher:, queue_id: }
      result(post("/check", message, @read_token, envelope_headers(envelope)))
    end

    def spam!(message) = learn("spam", message)
    def ham!(message) = learn("ham", message)

    def fuzzy_add(message, flag:, weight: nil) = json(post("/fuzzy/add", message, @write_token, { "Flag" => flag, "Weight" => weight&.to_s }.compact))
    def fuzzy_delete(message, flag:) = json(post("/fuzzy/delete", message, @write_token, "Flag" => flag))
    def fuzzy_check(message) = json(post("/fuzzy/check", message, @read_token))

    def ping
      response = exchange(new_request(Net::HTTP::Get, "/ping"), limit: 16)
      response.status == 200 && response.body == "pong"
    rescue Error
      false
    end

    def inspect
      tokens = { read_token: @read_token, write_token: @write_token }.map { |name, token| "#{name}=#{token ? "[FILTERED]" : "nil"}" }
      "#<#{self.class.name} host=#{@uri.host}:#{@uri.port} #{tokens.join(" ")}>"
    end

    def health = json(get("/health"))
    def stats = json(get("/stats"))
    def symbols = json(get("/symbols"))

    private
      def parse_url(url)
        uri = URI(url.to_s)
        raise ArgumentError, "url must be http or https" unless uri.is_a?(URI::HTTP)
        raise ArgumentError, "url must have a host" if uri.hostname.to_s.empty?
        raise ArgumentError, "url must not carry a user or password" if uri.userinfo
        uri
      rescue URI::InvalidURIError
        raise ArgumentError, "url is not a valid URI"
      end

      def envelope_headers(envelope)
        envelope.compact.to_h do |name, value|
          values = name == :rcpt && value.is_a?(Array) ? value : [ value ]
          values.each do |it|
            raise Error, "#{name} must be a string" unless it.is_a?(String)
            raise Error, "#{name} is over #{ENVELOPE_LIMIT} bytes" if it.bytesize > ENVELOPE_LIMIT
            raise Error, "#{name} must be text with no control characters" unless it.valid_encoding? && !it.match?(/[[:cntrl:]]/)
            raise Error, "rcpt has a comma: give each address as its own string" if name == :rcpt && it.include?(",")
          end
          [ ENVELOPE.fetch(name), values ]
        end
      end

      def learn(kind, message)
        post("/learn/#{kind}", message, @write_token).status == 200
      end

      def get(path)
        perform(new_request(Net::HTTP::Get, path), @read_token)
      end

      def post(path, message, token, headers = {})
        request = new_request(Net::HTTP::Post, path)
        request.content_type = "message/rfc822"
        request.body = message
        headers.each { |name, values| Array(values).each { request.add_field(name, it) } }
        perform(request, token)
      end

      # Asking for the body as it is keeps Net::HTTP from inflating a gzip
      # answer past the size limit.
      def new_request(type, path)
        type.new(@uri.path.chomp("/") + path, "Accept-Encoding" => "identity")
      end

      def perform(request, token)
        request["Authorization"] = "Bearer #{token}"
        exchange(request).tap do |response|
          raise Error.new(status: response.status, code: error_code(response)) unless response.success?
        end
      end

      # The timeouts bound each connect, read and write, so a server answering a
      # byte at a time would never trip them; the deadline bounds the whole call.
      def exchange(request, limit: BODY_LIMIT)
        Timeout.timeout(@deadline, nil, "no answer within #{@deadline} seconds") do
          Net::HTTP.start(@uri.hostname, @uri.port, nil, use_ssl: @uri.scheme == "https",
            open_timeout: @open_timeout, read_timeout: @read_timeout, write_timeout: @read_timeout) do |http|
            body = nil
            response = http.request(request) { body = read_body(it, limit) }
            Response.new(status: response.code.to_i, body:)
          end
        end
      rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => error
        raise Unreachable, error.message
      rescue Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
        raise Error, "response is not HTTP"
      end

      def read_body(response, limit)
        limit = [ limit, ERROR_BODY_LIMIT ].min unless response.is_a?(Net::HTTPSuccess)

        String.new.tap do |body|
          response.read_body do |chunk|
            body << chunk
            raise Error.new("response body over #{limit} bytes", status: response.code.to_i) if body.bytesize > limit
          end
        end
      end

      def error_code(response)
        body = JSON.parse(response.body.to_s)
        code = body["error"] if body.is_a?(Hash)
        code if code.is_a?(String) && code.valid_encoding? && code.match?(/\A[a-z_]{1,64}\z/)
      rescue JSON::ParserError
        nil
      end

      def json(response)
        JSON.parse(response.body)
      rescue JSON::ParserError, TypeError
        raise Error.new("response is not JSON", status: response.status)
      end

      def result(response)
        body = json(response)
        action = ACTIONS.fetch(body.fetch("action"))

        Result.new \
          action:,
          score: number(body.fetch("score")),
          complete: boolean(body.fetch("complete")),
          symbols: body.fetch("symbols").map { symbol(it) },
          smtp_reply: smtp_reply(action, body["smtp_reply"]),
          subject: subject(body["subject"])
      rescue KeyError, TypeError, NoMethodError => error
        raise Error.new("unexpected /check response: #{error.message}", status: response.status)
      end

      def symbol(symbol)
        Result::Symbol.new(name: symbol.fetch("name"), weight: number(symbol.fetch("weight")), detail: text(symbol["detail"]), description: text(symbol["description"]))
      end

      def number(value)
        value.is_a?(Numeric) ? value : raise(TypeError, "#{value.inspect[0, 20]} is not a number")
      end

      def text(value)
        value.nil? || value.is_a?(String) ? value : raise(TypeError, "#{value.inspect[0, 20]} is not text")
      end

      def boolean(value)
        value == true || value == false ? value : raise(TypeError, "#{value.inspect[0, 20]} is not true or false")
      end

      # A reply is kept only when it could go back to the SMTP client as it is:
      # a 4xx for a soft reject, a 5xx for a reject, and one line of text.
      def smtp_reply(action, reply)
        digit = { soft_reject: 4, reject: 5 }[action]
        return unless digit && reply.is_a?(Hash)

        code, enhanced, text = reply.values_at("code", "enhanced", "text")
        if code.is_a?(Integer) && code / 100 == digit && ascii?(enhanced, /\A#{digit}\.\d{1,3}\.\d{1,3}\z/) && ascii?(text, /\A[ -~]{1,200}\z/)
          Result::SmtpReply.new(code:, enhanced:, text:)
        end
      end

      def subject(subject)
        subject if subject.is_a?(String) && subject.valid_encoding? && !subject.match?(/[\r\n]/)
      end

      def ascii?(value, pattern)
        value.is_a?(String) && value.b.match?(pattern)
      end
  end
end
