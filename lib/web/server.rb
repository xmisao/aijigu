#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal HTTP server using only Ruby standard library (no gems).
# Uses WEBrick which ships with Ruby and requires no external dependencies.

require "socket"

module Aijigu
  module Web
    class Server
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 8080

      def initialize(host: nil, port: nil)
        @host = host || ENV.fetch("AIJIGU_WEB_HOST", DEFAULT_HOST)
        @port = (port || ENV.fetch("AIJIGU_WEB_PORT", DEFAULT_PORT)).to_i
      end

      def start
        server = TCPServer.new(@host, @port)
        $stdout.puts "aijigu web server listening on http://#{@host}:#{@port}"
        $stdout.flush

        loop do
          client = server.accept
          handle_request(client)
        rescue => e
          $stderr.puts "Error handling request: #{e.message}"
        end
      ensure
        server&.close
      end

      private

      def handle_request(client)
        request_line = client.gets
        return client.close unless request_line

        method, path, = request_line.split(" ", 3)

        # Consume remaining headers
        while (line = client.gets)
          break if line.strip.empty?
        end

        if method == "GET" && path == "/"
          serve_root(client)
        else
          serve_not_found(client)
        end
      ensure
        client.close rescue nil
      end

      def serve_root(client)
        body = "<!DOCTYPE html>\n<html>\n<head><meta charset=\"utf-8\"></head>\n<body>\n</body>\n</html>\n"
        write_response(client, 200, "OK", body)
      end

      def serve_not_found(client)
        write_response(client, 404, "Not Found", "Not Found\n")
      end

      def write_response(client, status, reason, body, content_type: "text/html; charset=utf-8")
        client.print "HTTP/1.1 #{status} #{reason}\r\n"
        client.print "Content-Type: #{content_type}\r\n"
        client.print "Content-Length: #{body.bytesize}\r\n"
        client.print "Connection: close\r\n"
        client.print "\r\n"
        client.print body
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  Aijigu::Web::Server.new.start
end
