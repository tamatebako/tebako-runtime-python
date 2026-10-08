# frozen_string_literal: true

require "spec_helper"

require "socket"

RSpec.describe TebakoPythonBuilder::BuildHelpers do
  # A loopback HTTP server answering one queued response per connection,
  # in order; the request log is the observable record (the retry budget
  # is proven by the request count, not by a mock).
  class StubHttpServer
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve }
    end

    def url(path = "resource")
      "http://127.0.0.1:#{@server.addr[1]}/#{path}"
    end

    def stop
      @server.close
      @thread.join(5)
    end

    private

    def serve
      @responses.each do |status, body, headers|
        client = @server.accept
        @requests << client.gets
        nil while (line = client.gets) && line != "\r\n"
        client.write "HTTP/1.1 #{status}\r\n"
        client.write "Content-Length: #{body.bytesize}\r\n"
        headers.each { |name, value| client.write "#{name}: #{value}\r\n" }
        client.write "Connection: close\r\n\r\n"
        client.write body
        client.close
      end
    rescue IOError, SystemCallError
      # The server socket was closed mid-queue (a failed expectation left
      # responses unserved) — the spec's assertions carry the diagnosis.
    end
  end

  before { stub_const("#{described_class}::READ_URL_BACKOFF_BASE", 0) }

  describe ".read_url" do
    it "returns the body on a first-try success" do
      server = StubHttpServer.new([["200 OK", "payload", {}]])
      expect(described_class.read_url(server.url, code: 1)).to eq("payload")
      expect(server.requests.size).to eq(1)
    ensure
      server.stop
    end

    it "retries a 429 and returns the next attempt's body" do
      server = StubHttpServer.new([["429 Too Many Requests", "rate limited", {}], ["200 OK", "payload", {}]])
      expect do
        expect(described_class.read_url(server.url, code: 1)).to eq("payload")
      end.to output(%r{attempt 1/3 failed fetching #{Regexp.escape(server.url)}: 429}).to_stderr
      expect(server.requests.size).to eq(2)
    ensure
      server.stop
    end

    it "follows a redirect within the redirect bound" do
      server = StubHttpServer.new([["302 Found", "", { "Location" => "final" }], ["200 OK", "payload", {}]])
      expect(described_class.read_url(server.url, code: 1)).to eq("payload")
      expect(server.requests.size).to eq(2)
    ensure
      server.stop
    end

    it "fails closed on a permanent 404 without retrying" do
      server = StubHttpServer.new([["404 Not Found", "nope", {}]])
      expect { described_class.read_url(server.url, code: 1) }
        .to raise_error(TebakoPythonBuilder::Error, %r{404 Not Found fetching #{Regexp.escape(server.url)}})
      expect(server.requests.size).to eq(1)
    ensure
      server.stop
    end

    it "exhausts the budget on persistent 503s, naming the url" do
      server = StubHttpServer.new(Array.new(3, ["503 Service Unavailable", "down", {}]))
      expect do
        expect { described_class.read_url(server.url, code: 1) }
          .to raise_error(TebakoPythonBuilder::Error, %r{503 Service Unavailable fetching #{Regexp.escape(server.url)}})
      end.to output(/attempt 1\/3 .*attempt 2\/3/m).to_stderr
      expect(server.requests.size).to eq(3)
    ensure
      server.stop
    end

    it "retries a refused connection, then raises the transport error named" do
      refused = TCPServer.new("127.0.0.1", 0)
      port = refused.addr[1]
      refused.close
      url = "http://127.0.0.1:#{port}/resource"
      expect do
        expect { described_class.read_url(url, code: 1) }
          .to raise_error(TebakoPythonBuilder::Error, /Errno::ECONNREFUSED.*#{Regexp.escape(url)}/)
      end.to output(/attempt 1\/3 .*attempt 2\/3/m).to_stderr
    end
  end
end
