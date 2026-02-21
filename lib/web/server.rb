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
        body = root_html
        write_response(client, 200, "OK", body)
      end

      def root_html
        <<~HTML
          <!DOCTYPE html>
          <html lang="ja">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>aijigu</title>
            <style>
              *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                background: #f5f5f5;
                color: #333;
                min-height: 100vh;
                display: flex;
                flex-direction: column;
                align-items: center;
                padding: 2rem 1rem;
              }
              h1 {
                font-size: 1.25rem;
                font-weight: 600;
                margin-bottom: 1rem;
                color: #555;
              }
              .container {
                width: 100%;
                max-width: 720px;
              }
              textarea {
                width: 100%;
                min-height: 60vh;
                padding: 1rem;
                font-family: inherit;
                font-size: 1rem;
                line-height: 1.7;
                border: 1px solid #ccc;
                border-radius: 6px;
                background: #fff;
                color: #333;
                resize: vertical;
                outline: none;
                transition: border-color 0.15s;
              }
              textarea:focus {
                border-color: #888;
              }
              textarea::placeholder {
                color: #aaa;
              }
            </style>
          </head>
          <body>
            <div class="container">
              <h1>aijigu</h1>
              <textarea placeholder="指示を入力..." autofocus></textarea>
            </div>
          </body>
          </html>
        HTML
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
