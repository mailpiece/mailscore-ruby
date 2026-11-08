# mailscore-ruby

Ruby client for [mailscore's HTTP API](https://github.com/mailpiece/mailscore/blob/main/docs/api.md), on Net::HTTP with no other dependencies.

## Installation

```ruby
gem "mailscore-ruby", github: "mailpiece/mailscore-ruby"
```

Requires Ruby 3.4 or later. Without Bundler, `require "mailscore-ruby"`.

## Usage

With no arguments, the client reads the same ENV as the server:

```ruby
client = MailScore::Client.new
```

- `url`: `MAILSCORE_URL`, else `http://localhost:8080`
- `read_token`: `MAILSCORE_READ_TOKEN`
- `write_token`: `MAILSCORE_WRITE_TOKEN`, else the read token
- `open_timeout`: 1 second, `read_timeout`: 10 seconds
- `deadline`: the two timeouts added, 11 seconds

Any of them can be given instead:

```ruby
client = MailScore::Client.new(url: "http://mailscore:8080", read_token: "read", write_token: "write",
  open_timeout: 2, read_timeout: 30, deadline: 30)
```

The timeouts bound each connect and each read, so a server answering a byte at a time would never trip them; the deadline bounds the whole call, and past it the call raises `MailScore::Client::Unreachable`. The client asks for answers uncompressed and never inflates one, and an answer over 1 MB, or 4 KB for an error, raises `MailScore::Client::Error`.

The url is `http` or `https` with a host and no user or password; any other raises `ArgumentError`. A url with a path, such as `http://proxy/mailscore/`, prefixes every request. The client connects to that url directly: it ignores `http_proxy` and the like in the environment, so the tokens and messages go nowhere else. A missing token is not an error until a call gets the server's `401`.

### Check a message

```ruby
result = client.check(source, ip: "203.0.113.9", from: "alice@example.com", rcpt: [ "bob@example.org" ])

result.action     # => :no_action
result.score      # => 2.5
result.complete?  # => true
result.symbols    # => [ #<data MailScore::Client::Result::Symbol name="HOSTNAME_UNKNOWN", weight=2.5, detail="203.0.113.9",
                  #      description="Sending server has no verified host name"> ]
result.smtp_reply # => nil
result.subject    # => nil
result.headers    # => [ [ "X-Spam-Flag", "NO" ], [ "X-Spam-Score", "2.5" ], ... ]
```

Every keyword is optional and becomes the request header of the same name: `ip`, `helo`, `hostname`, `reverse_dns_status`, `unconfirmed_hostname`, `from`, `rcpt`, `deliver_to`, `user`, `tls_version`, `tls_cipher` and `queue_id`. One left out sends no header. Each value is a string of at most 1024 bytes with no control characters, such as a line break; anything else raises `MailScore::Client::Error` before the request is sent. `rcpt:` takes a string or an array of strings: the client adds a `Rcpt` field per address, Net::HTTP sends them as one comma-separated `Rcpt` header, and the server splits it, so an address with a comma in it raises too. `reverse_dns_status` is how your reverse DNS lookup went, `confirmed`, `unconfirmed`, `none` or `temporary_failure`, and `unconfirmed_hostname` the PTR name that did not resolve back; a server that predates them ignores them.

`action` is `:no_action`, `:add_header`, `:rewrite_subject`, `:soft_reject` or `:reject`. `smtp_reply` has `code`, `enhanced` and `text` with `:soft_reject` and `:reject`, `subject` is set with `:rewrite_subject`, and `complete?` is false when the scan ran past its budget. Each symbol's `description` is the short label the server gives it, or nil from a server before 0.1.1. `headers` are the spam header fields, as `[ name, value ]` pairs in order, to prepend to the message you hand on after removing any `X-Spam-` field the sender wrote; a server that predates them gives none.

The answer is checked before it reaches you, so a reply or subject can be handed back to the SMTP client as it is. `smtp_reply` is nil unless its `code` is a 4xx for `:soft_reject` or a 5xx for `:reject`, `enhanced` has the same class, as in `5.7.1`, and `text` is 1 to 200 printable ASCII characters. `subject` is nil when it holds a line break, and a header is left out unless its name is a field name and its value one line of text. A `score` or weight that is not a number, or a `complete` that is not true or false, raises `MailScore::Client::Error`.

### Learn spam and ham

```ruby
client.spam!(source) # => true
client.ham!(source)  # => true
```

Both use the write token. True when learned (`200`), false when already learned as that class (`208`) or too short to learn (`204`).

### Fuzzy hashes

```ruby
client.fuzzy_add(source, flag: "spam")             # => { "hashes" => 3 }
client.fuzzy_add(source, flag: "spam", weight: 10) # => { "hashes" => 3 }
client.fuzzy_delete(source, flag: "spam")          # => { "hashes" => 3 }
client.fuzzy_check(source)                         # => { "matches" => [ { "flag" => "spam", "count" => 41, "similarity" => 0.92 } ] }
```

Add and delete use the write token, check the read token. `weight` is added to each hash's count; without it, the server adds 1.

### Ping and reads

```ruby
client.ping    # => true
client.health  # => { "status" => "ok", "version" => "0.1.0" }
client.stats   # => { ... }
client.symbols # => [ { "name" => "HOSTNAME_UNKNOWN", "weight" => 2.5, "description" => "The sending server has no verified host name" }, ... ]
```

`ping` sends no token and is true only on a `200` with `pong`. On anything else, including a server it cannot reach or a broken answer, it is false; it never raises for a server problem. The reads use the read token and return the parsed JSON.

## Errors

Every call but `ping` raises `MailScore::Client::Error` on a non-2xx answer, with its `status` and error `code`, or on an answer that is not HTTP or a body that is not the JSON promised:

```ruby
begin
  client.check(source)
rescue MailScore::Client::Unreachable
  # a timeout or a refused connection
rescue MailScore::Client::Error => error
  error.status # => 401
  error.code   # => "unauthorized"
end
```

`code` is the body's `error` when it is lowercase letters and underscores, at most 64 of them, and nil otherwise.

`MailScore::Client::Unreachable` is a `MailScore::Client::Error`, raised on a timeout or a failed connection, including a TLS certificate that does not verify, with no status. Whether to accept mail that could not be scored is the caller's choice.

## License

mailscore-ruby is released under the [MIT License](LICENSE).
