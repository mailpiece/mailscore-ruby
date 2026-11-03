require "test_helper"
require "openssl"
require "socket"
require "zlib"

class MailScore::ClientTest < Minitest::Test
  MESSAGE = "From: someone@example.com\r\nSubject: Hello\r\n\r\nHello\r\n".b

  # A one-connection-at-a-time HTTP server that records each request and
  # answers with whatever the test set last.
  class Stub
    Request = Data.define(:method, :path, :headers, :body) do
      def [](name) = headers.filter_map { |key, value| value if key.casecmp?(name) }
    end

    attr_reader :port, :requests

    def initialize(host = "127.0.0.1")
      @server = TCPServer.new(host, 0)
      @port = @server.addr[1]
      @requests = []
      answer 200, "{}"
      @thread = Thread.new { loop { serve(@server.accept) } }
    end

    def answer(status, body, type: "application/json", delay: 0)
      @answer = [ status, body, type, delay ]
    end

    # Answers by writing whatever the block writes to the socket.
    def answer_raw(&block)
      @answer = block
    end

    def close
      @thread.kill
      @server.close
    end

    private
      def serve(socket)
        method, path = socket.gets.split
        headers = []
        while (line = socket.gets) != "\r\n"
          headers << line.chomp.split(": ", 2)
        end
        length = headers.find { |key, _| key.casecmp?("Content-Length") }&.last.to_i
        @requests << Request.new(method:, path:, headers:, body: socket.read(length))

        return @answer.call(socket) if @answer.is_a?(Proc)

        status, body, type, delay = @answer
        sleep delay
        socket.write "HTTP/1.1 #{status} X\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      rescue SystemCallError, IOError
      ensure
        socket.close
      end
  end

  def setup
    @stub = Stub.new
    @client = client(@stub.port)
  end

  def teardown
    @stub.close
  end

  def test_requiring_the_client_loads_only_the_standard_library
    script = <<~RUBY
      require "mailscore-ruby"
      loaded = %i[ Rack Puma SQLite3 HomographicSpoofing ActiveSupport ].select { Object.const_defined?(it) }
      loaded << :App if MailScore.const_defined?(:App)
      loaded << :regexp_timeout if Regexp.timeout
      print loaded.inspect
    RUBY

    output = IO.popen([ RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script ], &:read)
    assert_equal "[]", output
  end

  def test_the_client_defines_nothing_under_mailscore_but_itself
    script = 'require "mailscore/client"; print MailScore.constants.sort.inspect'

    output = IO.popen([ RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script ], &:read)
    assert_equal "[:Client]", output
  end

  def test_a_url_that_is_not_http_with_a_host_and_no_user_is_an_argument_error
    [ nil, "", "mailscore:8080", "ftp://127.0.0.1:#{@stub.port}", "http:///mailscore", "http://user:password@127.0.0.1:#{@stub.port}",
      "http://mail score:8080" ].each do |url|
      assert_raises(ArgumentError, url.inspect) { MailScore::Client.new(url:) }
    end

    assert_empty @stub.requests
  end

  def test_an_ipv6_literal_url_reaches_the_server
    stub = Stub.new("::1")
    client(stub.port, url: "http://[::1]:#{stub.port}").stats

    assert_equal "/stats", stub.requests.last.path
  ensure
    stub&.close
  end

  def test_inspect_shows_the_host_but_never_the_tokens
    assert_equal "#<MailScore::Client host=127.0.0.1:#{@stub.port} read_token=[FILTERED] write_token=[FILTERED]>", @client.inspect
    assert_equal "#<MailScore::Client host=[::1]:8080 read_token=nil write_token=nil>", MailScore::Client.new(url: "http://[::1]:8080", read_token: nil).inspect
  end

  def test_with_no_arguments_the_url_and_tokens_come_from_env
    with_env "MAILSCORE_URL" => "http://127.0.0.1:#{@stub.port}", "MAILSCORE_READ_TOKEN" => "env-read", "MAILSCORE_WRITE_TOKEN" => "env-write" do
      client = MailScore::Client.new
      client.stats
      client.spam!(MESSAGE)
    end

    assert_equal [ [ "Bearer env-read" ], [ "Bearer env-write" ] ], @stub.requests.map { it["Authorization"] }
  end

  def test_without_env_the_client_defaults_to_localhost_with_short_timeouts
    with_env "MAILSCORE_URL" => nil, "MAILSCORE_READ_TOKEN" => nil, "MAILSCORE_WRITE_TOKEN" => nil do
      client = MailScore::Client.new

      assert_equal [ URI("http://localhost:8080"), nil, nil, 1, 10, 11 ],
        %i[ @uri @read_token @write_token @open_timeout @read_timeout @deadline ].map { client.instance_variable_get(it) }
    end
  end

  def test_explicit_options_override_env
    with_env "MAILSCORE_URL" => "http://127.0.0.1:#{closed_port}", "MAILSCORE_READ_TOKEN" => "env-read", "MAILSCORE_WRITE_TOKEN" => "env-write" do
      client = MailScore::Client.new(url: "http://127.0.0.1:#{@stub.port}", read_token: "read-token", write_token: "write-token")
      client.stats
      client.spam!(MESSAGE)
    end

    assert_equal [ [ "Bearer read-token" ], [ "Bearer write-token" ] ], @stub.requests.map { it["Authorization"] }
  end

  def test_the_write_token_falls_back_to_the_read_token
    with_env "MAILSCORE_URL" => "http://127.0.0.1:#{@stub.port}", "MAILSCORE_READ_TOKEN" => "env-read", "MAILSCORE_WRITE_TOKEN" => nil do
      MailScore::Client.new.spam!(MESSAGE)
      MailScore::Client.new(read_token: "only-token").ham!(MESSAGE)
    end

    assert_equal [ [ "Bearer env-read" ], [ "Bearer only-token" ] ], @stub.requests.map { it["Authorization"] }
  end

  def test_check_sends_the_envelope_as_headers_with_the_read_token
    @stub.answer 200, JSON.generate(action: "add header", score: 7.1, complete: true,
      symbols: [ { name: "HOSTNAME_UNKNOWN", weight: 1.5, detail: "no PTR for 203.0.113.9" } ])

    result = @client.check(MESSAGE, ip: "203.0.113.9", helo: "mx.example.com", hostname: "unknown", from: "<>",
      rcpt: [ "someone@example.org" ], deliver_to: "box@example.org", user: "alice", tls_version: "TLSv1.3",
      tls_cipher: "TLS_AES_256_GCM_SHA384", queue_id: "4Q1abc")

    request = @stub.requests.last
    assert_equal [ "POST", "/check" ], [ request.method, request.path ]
    assert_equal [ "Bearer read-token" ], request["Authorization"]
    assert_equal [ "message/rfc822" ], request["Content-Type"]
    assert_equal MESSAGE, request.body
    { "IP" => "203.0.113.9", "Helo" => "mx.example.com", "Hostname" => "unknown", "From" => "<>", "Rcpt" => "someone@example.org",
      "Deliver-To" => "box@example.org", "User" => "alice", "TLS-Version" => "TLSv1.3", "TLS-Cipher" => "TLS_AES_256_GCM_SHA384",
      "Queue-Id" => "4Q1abc" }.each { |name, value| assert_equal [ value ], request[name], name }

    assert_equal :add_header, result.action
    assert_equal 7.1, result.score
    assert result.complete?
    assert_equal [ MailScore::Client::Result::Symbol.new(name: "HOSTNAME_UNKNOWN", weight: 1.5, detail: "no PTR for 203.0.113.9") ], result.symbols
    assert_nil result.smtp_reply
    assert_nil result.subject
  end

  def test_check_reads_each_symbols_description_when_the_server_sends_one
    @stub.answer 200, JSON.generate(action: "no action", score: 2.5, complete: true, symbols: [
      { name: "HOSTNAME_UNKNOWN", weight: 2.5, detail: "203.0.113.9", description: "Sending server has no verified host name" },
      { name: "DATE_MISSING", weight: 1.0 } ])

    assert_equal [ "Sending server has no verified host name", nil ], @client.check(MESSAGE).symbols.map(&:description)
  end

  def test_check_sends_no_header_for_a_keyword_left_out
    @stub.answer 200, JSON.generate(action: "no action", score: 0, complete: true, symbols: [])

    @client.check(MESSAGE, ip: "203.0.113.9")

    request = @stub.requests.last
    assert_equal [ "203.0.113.9" ], request["IP"]
    %w[ Helo Hostname From Rcpt Deliver-To User TLS-Version TLS-Cipher Queue-Id ].each { |name| assert_empty request[name], name }
  end

  def test_check_sends_every_recipient
    @stub.answer 200, JSON.generate(action: "no action", score: 0, complete: true, symbols: [])

    @client.check(MESSAGE, rcpt: [ "one@example.org", "two@example.org" ])

    # Net::HTTP folds repeated fields into one, as Rack does on the server.
    assert_equal [ "one@example.org, two@example.org" ], @stub.requests.last["Rcpt"]
  end

  def test_check_refuses_an_envelope_value_that_is_not_one_line_of_text
    [ { helo: "mx\r\nX-Injected: 1" }, { helo: "mx\nX-Injected: 1" }, { helo: "mx\0" }, { helo: "mx\x7f" }, { user: "\u0085" },
      { from: "\xff\xfe".dup.force_encoding("UTF-8") }, { helo: "a" * 70_000 }, { ip: 203 }, { helo: [ "mx" ] },
      { rcpt: { "a" => "b" } }, { rcpt: [ "one@example.org", nil ] }, { rcpt: "\"a,b\"@example.org" },
      { rcpt: [ "one@example.org", "two@example.org, three@example.org" ] } ].each do |envelope|
      assert_raises(MailScore::Client::Error, envelope.inspect) { @client.check(MESSAGE, **envelope) }
    end

    assert_empty @stub.requests
  end

  def test_check_sends_an_address_in_utf8
    @stub.answer 200, JSON.generate(action: "no action", score: 0, complete: true, symbols: [])

    @client.check(MESSAGE, from: "josé@example.com", rcpt: "zoë@example.org")

    request = @stub.requests.last
    assert_equal [ [ "josé@example.com".b ], [ "zoë@example.org".b ] ], [ request["From"], request["Rcpt"] ].map { it.map(&:b) }
  end

  def test_check_returns_the_smtp_reply_and_subject
    @stub.answer 200, JSON.generate(action: "soft reject", score: 4.2, complete: false, symbols: [],
      smtp_reply: { code: 451, enhanced: "4.7.1", text: "Try again later" })
    result = @client.check(MESSAGE)

    assert_equal :soft_reject, result.action
    refute result.complete?
    assert_equal MailScore::Client::Result::SmtpReply.new(code: 451, enhanced: "4.7.1", text: "Try again later"), result.smtp_reply

    @stub.answer 200, JSON.generate(action: "rewrite subject", score: 6, complete: true, symbols: [], subject: "[SPAM] Hello")
    assert_equal "[SPAM] Hello", @client.check(MESSAGE).subject
  end

  def test_check_raises_on_an_unknown_action_or_a_missing_field
    @stub.answer 200, JSON.generate(action: "greylist", score: 4, complete: true, symbols: [])
    assert_raises(MailScore::Client::Error) { @client.check(MESSAGE) }

    @stub.answer 200, JSON.generate(action: "reject", score: 15, complete: true)
    assert_raises(MailScore::Client::Error) { @client.check(MESSAGE) }
  end

  def test_check_raises_when_complete_is_not_a_boolean_or_a_score_not_a_number
    [ { score: "lots", complete: true, symbols: [] }, { score: 0, complete: "false", symbols: [] }, { score: 0, complete: nil, symbols: [] },
      { score: 0, complete: true, symbols: [ { name: "X", weight: "1.5" } ] } ].each do |fields|
      @stub.answer 200, JSON.generate(action: "no action", **fields)
      assert_raises(MailScore::Client::Error, fields.inspect) { @client.check(MESSAGE) }
    end
  end

  def test_check_raises_when_a_symbols_detail_or_description_is_not_text
    [ { name: "X", weight: 1.5, detail: 42 }, { name: "X", weight: 1.5, description: [ "No PTR" ] } ].each do |symbol|
      @stub.answer 200, JSON.generate(action: "no action", score: 1.5, complete: true, symbols: [ symbol ])
      assert_raises(MailScore::Client::Error, symbol.inspect) { @client.check(MESSAGE) }
    end
  end

  def test_check_reads_a_null_or_absent_detail_and_description_as_nil
    @stub.answer 200, JSON.generate(action: "no action", score: 2.5, complete: true, symbols: [
      { name: "X", weight: 1.5, detail: nil, description: nil }, { name: "Y", weight: 1.0 } ])

    assert_equal [ [ nil, nil ], [ nil, nil ] ], @client.check(MESSAGE).symbols.map { [ it.detail, it.description ] }
  end

  def test_check_leaves_out_an_smtp_reply_that_could_not_go_back_as_it_is
    reply = { code: 550, enhanced: "5.7.1", text: "Rejected as spam" }
    @stub.answer 200, JSON.generate(action: "reject", score: 20, complete: true, symbols: [], smtp_reply: reply)
    assert_equal MailScore::Client::Result::SmtpReply.new(**reply), @client.check(MESSAGE).smtp_reply

    [ [ "reject", { code: 250, enhanced: "2.0.0", text: "OK" } ], [ "reject", { code: 451, enhanced: "4.7.1", text: "Later" } ],
      [ "reject", { code: 550, enhanced: "4.7.1", text: "Spam" } ], [ "reject", { code: "550", enhanced: "5.7.1", text: "Spam" } ],
      [ "reject", { code: 550, enhanced: "5.7", text: "Spam" } ], [ "reject", { code: 550, enhanced: "5.7.1", text: "OK\r\n250 queued" } ],
      [ "reject", { code: 550, enhanced: "5.7.1", text: "" } ], [ "reject", { code: 550, enhanced: "5.7.1", text: "a" * 201 } ],
      [ "reject", { code: 550, enhanced: "5.7.1", text: "Rejeté" } ], [ "soft reject", { code: 550, enhanced: "5.7.1", text: "Spam" } ],
      [ "no action", reply ], [ "reject", "550 5.7.1 Spam" ] ].each do |action, smtp_reply|
      @stub.answer 200, JSON.generate(action:, score: 20, complete: true, symbols: [], smtp_reply:)
      assert_nil @client.check(MESSAGE).smtp_reply, [ action, smtp_reply ].inspect
    end
  end

  def test_check_leaves_out_a_subject_with_a_line_break
    [ "x\r\nBcc: victim@example.com", "x\nBcc: victim@example.com", 7 ].each do |subject|
      @stub.answer 200, JSON.generate(action: "rewrite subject", score: 7, complete: true, symbols: [], subject:)
      assert_nil @client.check(MESSAGE).subject, subject.inspect
    end
  end

  def test_learning_uses_the_write_token_and_tells_new_from_already_learned
    @stub.answer 200, JSON.generate(learned: true)
    assert_equal true, @client.spam!(MESSAGE)
    assert_equal [ "POST", "/learn/spam", [ "Bearer write-token" ] ], @stub.requests.last.then { [ it.method, it.path, it["Authorization"] ] }

    @stub.answer 208, JSON.generate(error: "already_learned")
    assert_equal false, @client.ham!(MESSAGE)
    assert_equal "/learn/ham", @stub.requests.last.path
  end

  def test_learning_a_message_too_short_to_learn_is_false
    @stub.answer 204, ""
    assert_equal false, @client.spam!(MESSAGE)
    assert_equal false, @client.ham!(MESSAGE)
  end

  def test_fuzzy_add_and_delete_send_the_flag_with_the_write_token
    @stub.answer 200, JSON.generate(hashes: 3)

    assert_equal({ "hashes" => 3 }, @client.fuzzy_add(MESSAGE, flag: "spam"))
    assert_equal({ "hashes" => 3 }, @client.fuzzy_delete(MESSAGE, flag: "spam"))

    @stub.requests.zip(%w[ /fuzzy/add /fuzzy/delete ]).each do |request, path|
      assert_equal [ path, [ "spam" ], [ "Bearer write-token" ], MESSAGE ], [ request.path, request["Flag"], request["Authorization"], request.body ]
    end
  end

  def test_fuzzy_add_sends_a_weight_when_given
    @stub.answer 200, JSON.generate(hashes: 3)
    @client.fuzzy_add(MESSAGE, flag: "spam", weight: 10)
    @client.fuzzy_add(MESSAGE, flag: "spam")

    assert_equal [ [ "10" ], [] ], @stub.requests.map { it["Weight"] }
  end

  def test_fuzzy_check_uses_the_read_token
    matches = { "matches" => [ { "flag" => "spam", "count" => 41, "similarity" => 0.92 } ] }
    @stub.answer 200, JSON.generate(matches)

    assert_equal matches, @client.fuzzy_check(MESSAGE)
    assert_equal [ "/fuzzy/check", [ "Bearer read-token" ] ], @stub.requests.last.then { [ it.path, it["Authorization"] ] }
  end

  def test_reads_return_the_parsed_json_with_the_read_token
    @stub.answer 200, JSON.generate(status: "ok", version: "0.1.0")
    assert_equal({ "status" => "ok", "version" => "0.1.0" }, @client.health)

    @stub.answer 200, JSON.generate(unauthorized: 2)
    assert_equal({ "unauthorized" => 2 }, @client.stats)

    @stub.answer 200, JSON.generate([ { name: "HOSTNAME_UNKNOWN", weight: 1.5, description: "No PTR" } ])
    assert_equal "HOSTNAME_UNKNOWN", @client.symbols.first["name"]

    assert_equal %w[ /health /stats /symbols ], @stub.requests.map(&:path)
    assert @stub.requests.all? { it.method == "GET" && it["Authorization"] == [ "Bearer read-token" ] }
  end

  def test_a_url_with_a_path_prefixes_every_request
    client(@stub.port, url: "http://127.0.0.1:#{@stub.port}/mailscore/").stats

    assert_equal "/mailscore/stats", @stub.requests.last.path
  end

  def test_a_non_2xx_answer_raises_with_its_status_and_error_code
    @stub.answer 503, JSON.generate(error: "unavailable")
    error = assert_raises(MailScore::Client::Error) { @client.health }
    assert_equal [ 503, "unavailable" ], [ error.status, error.code ]

    @stub.answer 401, JSON.generate(error: "unauthorized")
    error = assert_raises(MailScore::Client::Error) { @client.check(MESSAGE) }
    assert_equal [ 401, "unauthorized" ], [ error.status, error.code ]

    @stub.answer 502, "Bad Gateway", type: "text/html"
    error = assert_raises(MailScore::Client::Error) { @client.spam!(MESSAGE) }
    assert_equal [ 502, nil ], [ error.status, error.code ]
  end

  def test_an_error_code_that_is_not_a_short_snake_case_word_is_left_out
    [ '{"error":"x\\nFAKE LOG LINE"}', '{"error":{"a":1}}', '"an error"', %({"error":"#{"a" * 65}"}), "{\"error\":\"\xff\"}".b ].each do |body|
      @stub.answer 500, body

      error = assert_raises(MailScore::Client::Error) { @client.stats }
      assert_equal [ 500, nil, "500" ], [ error.status, error.code, error.message ], body.inspect
    end
  end

  def test_an_error_message_is_bounded
    assert_equal 200, MailScore::Client::Error.new("x" * 1000).message.length
  end

  def test_a_body_that_is_not_json_raises
    @stub.answer 200, "<html>"

    error = assert_raises(MailScore::Client::Error) { @client.stats }
    assert_equal 200, error.status
  end

  def test_a_timeout_raises_unreachable
    @stub.answer 200, "{}", delay: 1

    assert_raises(MailScore::Client::Unreachable) { client(@stub.port, read_timeout: 0.1).stats }
  end

  def test_an_answer_that_is_not_http_raises_an_error
    [ "garbage\r\n\r\n", "HTTP/1.1 200 OK\r\nno colon\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: lots\r\n\r\n{}" ].each do |answer|
      @stub.answer_raw { it.write answer }

      error = assert_raises(MailScore::Client::Error, answer.inspect) { @client.check(MESSAGE) }
      assert_equal "response is not HTTP", error.message
    end
  end

  def test_a_certificate_that_does_not_verify_raises_unreachable
    key = OpenSSL::PKey::EC.generate("prime256v1")
    certificate = OpenSSL::X509::Certificate.new
    certificate.version, certificate.serial = 2, 1
    certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
    certificate.public_key = key
    certificate.not_before, certificate.not_after = Time.now - 60, Time.now + 60
    certificate.sign(key, "SHA256")

    server = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", 0), OpenSSL::SSL::SSLContext.new.tap { it.add_certificate(certificate, key) })
    thread = Thread.new { server.accept.close rescue nil }

    assert_raises(MailScore::Client::Unreachable) { client(nil, url: "https://127.0.0.1:#{server.to_io.addr[1]}").stats }
  ensure
    thread&.kill
    server&.close
  end

  def test_a_server_answering_a_byte_at_a_time_raises_unreachable_at_the_deadline
    slow_status = proc { |socket| 40.times { socket.write "H"; sleep 0.05 } }
    slow_body = proc { |socket| socket.write "HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n"; 40.times { socket.write " "; sleep 0.05 } }

    [ slow_status, slow_body ].each do |answer|
      @stub.answer_raw(&answer)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(MailScore::Client::Unreachable) { client(@stub.port, deadline: 0.5).check(MESSAGE) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
      assert_equal false, client(@stub.port, deadline: 0.5).ping
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    end
  end

  def test_a_gzip_answer_is_never_inflated
    @client.stats
    assert_equal [ "identity" ], @stub.requests.last["Accept-Encoding"]

    [ Zlib.gzip("[" + "0," * 5_000_000 + "0]"), "not gzip at all" ].each do |body|
      @stub.answer_raw { it.write "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}" }

      error = assert_raises(MailScore::Client::Error) { @client.stats }
      assert_equal "response is not JSON", error.message
    end
  end

  def test_an_answer_over_a_megabyte_raises_an_error
    @stub.answer_raw do |socket|
      socket.write "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
      loop { socket.write "10000\r\n#{"a" * 0x10000}\r\n" }
    end

    error = assert_raises(MailScore::Client::Error) { @client.check(MESSAGE) }
    assert_equal [ MailScore::Client::Error, 200, "response body over 1048576 bytes" ], [ error.class, error.status, error.message ]
    assert_equal false, @client.ping
  end

  def test_an_error_answer_over_four_kilobytes_raises_without_a_code
    @stub.answer 500, JSON.generate(error: "unavailable", detail: "a" * 5000)

    error = assert_raises(MailScore::Client::Error) { @client.stats }
    assert_equal [ 500, nil, "response body over 4096 bytes" ], [ error.status, error.code, error.message ]
  end

  def test_a_refused_connection_raises_unreachable_which_is_an_error
    error = assert_raises(MailScore::Client::Unreachable) { client(closed_port).health }

    assert_kind_of MailScore::Client::Error, error
    assert_nil error.status
  end

  def test_a_proxy_in_the_environment_is_never_used
    proxy = Stub.new
    with_env "http_proxy" => "http://127.0.0.1:#{proxy.port}" do
      assert_raises(MailScore::Client::Unreachable) { client(@stub.port, url: "http://mailscore.invalid:#{@stub.port}").stats }
    end

    assert_empty proxy.requests
  ensure
    proxy.close
  end

  def test_ping_is_true_on_pong_without_a_token
    @stub.answer 200, "pong", type: "text/plain"

    assert_equal true, @client.ping
    assert_equal [ "GET", "/ping", [] ], @stub.requests.last.then { [ it.method, it.path, it["Authorization"] ] }
  end

  def test_ping_is_false_on_anything_else_and_never_raises
    @stub.answer 503, JSON.generate(error: "unavailable")
    assert_equal false, @client.ping

    @stub.answer 200, "pang", type: "text/plain"
    assert_equal false, @client.ping

    assert_equal false, client(closed_port).ping

    @stub.answer 200, "pong", type: "text/plain", delay: 1
    assert_equal false, client(@stub.port, read_timeout: 0.1).ping

    @stub.answer_raw { it.write "garbage\r\n\r\n" }
    assert_equal false, @client.ping
  end

  def test_ping_raises_a_bug_in_the_client
    @client.define_singleton_method(:exchange) { |*| raise NoMethodError, "a bug" }

    assert_raises(NoMethodError) { @client.ping }
  end

  private
    def client(port, url: "http://127.0.0.1:#{port}", read_timeout: 1, deadline: 2)
      MailScore::Client.new(url:, read_token: "read-token", write_token: "write-token", open_timeout: 1, read_timeout:, deadline:)
    end

    def with_env(values)
      saved = values.keys.to_h { [ it, ENV[it] ] }
      ENV.update(values)
      yield
    ensure
      ENV.update(saved)
    end

    def closed_port
      TCPServer.open("127.0.0.1", 0) { it.addr[1] }
    end
end
