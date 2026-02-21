#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal HTTP server using only Ruby standard library (no gems).
# Uses WEBrick which ships with Ruby and requires no external dependencies.

require "socket"
require "json"

module Aijigu
  module Web
    class Server
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 8080

      def initialize(host: nil, port: nil)
        @host = host || ENV.fetch("AIJIGU_WEB_HOST", DEFAULT_HOST)
        @port = (port || ENV.fetch("AIJIGU_WEB_PORT", DEFAULT_PORT)).to_i
        @aijigu_bin = File.expand_path("../../bin/aijigu", __dir__)
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

        # Parse headers
        headers = {}
        while (line = client.gets)
          break if line.strip.empty?
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip if key && value
        end

        if method == "GET" && path == "/"
          serve_root(client)
        elsif method == "POST" && path == "/api/direction/add"
          handle_direction_add(client, headers)
        else
          serve_not_found(client)
        end
      ensure
        client.close rescue nil
      end

      def handle_direction_add(client, headers)
        content_length = headers["content-length"]&.to_i || 0
        body = client.read(content_length) if content_length > 0

        unless body && !body.strip.empty?
          write_json_response(client, 400, { error: "Empty instruction" })
          return
        end

        begin
          data = JSON.parse(body)
        rescue JSON::ParserError
          write_json_response(client, 400, { error: "Invalid JSON" })
          return
        end

        instruction = data["instruction"]&.strip
        if instruction.nil? || instruction.empty?
          write_json_response(client, 400, { error: "Empty instruction" })
          return
        end

        # Run direction add in a background process
        pid = spawn(@aijigu_bin, "direction", "add", "-m", instruction,
                    out: "/dev/null", err: "/dev/null")
        Process.detach(pid)

        write_json_response(client, 202, { status: "accepted", message: "Direction add started" })
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
              textarea:focus { border-color: #888; }
              textarea::placeholder { color: #aaa; }
              textarea:disabled { background: #f0f0f0; color: #999; }
              .actions {
                display: flex;
                justify-content: flex-end;
                margin-top: 0.75rem;
              }
              button {
                padding: 0.5rem 1.5rem;
                font-family: inherit;
                font-size: 0.95rem;
                font-weight: 500;
                border: 1px solid #ccc;
                border-radius: 6px;
                background: #fff;
                color: #333;
                cursor: pointer;
                transition: background 0.15s, border-color 0.15s;
              }
              button:hover { background: #eee; border-color: #888; }
              button:disabled { cursor: not-allowed; opacity: 0.5; }
              .notice {
                margin-top: 0.75rem;
                padding: 0.6rem 1rem;
                border-radius: 6px;
                font-size: 0.9rem;
                display: none;
              }
              .notice.success { display: block; background: #e8f5e9; color: #2e7d32; border: 1px solid #a5d6a7; }
              .notice.error { display: block; background: #fbe9e7; color: #c62828; border: 1px solid #ef9a9a; }
            </style>
          </head>
          <body>
            <div class="container">
              <h1>aijigu</h1>
              <textarea id="instruction" placeholder="指示を入力..." autofocus></textarea>
              <div class="actions">
                <button id="submit" type="button">送信</button>
              </div>
              <div id="notice" class="notice"></div>
            </div>
            <script>
              const textarea = document.getElementById('instruction');
              const submitBtn = document.getElementById('submit');
              const notice = document.getElementById('notice');

              function showNotice(msg, type) {
                notice.textContent = msg;
                notice.className = 'notice ' + type;
              }

              function clearNotice() {
                notice.textContent = '';
                notice.className = 'notice';
              }

              async function submit() {
                const text = textarea.value.trim();
                if (!text) return;

                clearNotice();
                submitBtn.disabled = true;
                textarea.disabled = true;

                try {
                  const res = await fetch('/api/direction/add', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ instruction: text })
                  });
                  const data = await res.json();

                  if (res.ok) {
                    showNotice('タスク化を受け付けました', 'success');
                    textarea.value = '';
                  } else {
                    showNotice(data.error || 'エラーが発生しました', 'error');
                  }
                } catch (e) {
                  showNotice('通信エラーが発生しました', 'error');
                }

                submitBtn.disabled = false;
                textarea.disabled = false;
                textarea.focus();
              }

              submitBtn.addEventListener('click', submit);
              textarea.addEventListener('keydown', function(e) {
                if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
                  e.preventDefault();
                  submit();
                }
              });
            </script>
          </body>
          </html>
        HTML
      end

      def serve_not_found(client)
        write_response(client, 404, "Not Found", "Not Found\n")
      end

      def write_json_response(client, status, data)
        reason = { 200 => "OK", 202 => "Accepted", 400 => "Bad Request", 500 => "Internal Server Error" }[status] || "OK"
        body = JSON.generate(data)
        write_response(client, status, reason, body, content_type: "application/json; charset=utf-8")
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
