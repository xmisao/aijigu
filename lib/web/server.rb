#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal HTTP server using only Ruby standard library (no gems).
# Uses WEBrick which ships with Ruby and requires no external dependencies.

require "socket"
require "json"
require "open3"
require "securerandom"
require "digest"

module Aijigu
  module Web
    class Server
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 8080
      SESSION_COOKIE_NAME = "aijigu_session"
      SESSION_TTL = 24 * 60 * 60 # 24 hours

      def initialize(host: nil, port: nil)
        @host = host || ENV.fetch("AIJIGU_WEB_HOST", DEFAULT_HOST)
        @port = (port || ENV.fetch("AIJIGU_WEB_PORT", DEFAULT_PORT)).to_i
        @aijigu_bin = File.expand_path("../../bin/aijigu", __dir__)
        @draft = ""
        @submissions = {}
        @submissions_mutex = Mutex.new
        @sessions = {}
        @sessions_mutex = Mutex.new
        @auth_username = ENV["AIJIGU_WEB_USERNAME"]
        @auth_password = ENV["AIJIGU_WEB_PASSWORD"]
      end

      def start
        server = TCPServer.new(@host, @port)
        $stdout.puts "aijigu web server listening on http://#{@host}:#{@port}"
        $stdout.flush

        loop do
          client = server.accept
          Thread.new(client) do |c|
            handle_request(c)
          rescue => e
            $stderr.puts "Error handling request: #{e.message}"
          end
        rescue => e
          $stderr.puts "Error accepting connection: #{e.message}"
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

        # Authentication check
        if auth_required?
          # Login endpoint is always accessible
          if method == "POST" && path == "/auth/login"
            handle_login(client, headers)
            return
          end

          if method == "POST" && path == "/auth/logout"
            handle_logout(client, headers)
            return
          end

          cookies = parse_cookies(headers)
          unless valid_session?(cookies[SESSION_COOKIE_NAME])
            if method == "GET" && path == "/"
              serve_login_page(client)
            else
              write_json_response(client, 401, { error: "Authentication required" })
            end
            return
          end
        end

        if method == "GET" && path == "/"
          serve_root(client)
        elsif method == "GET" && path == "/api/direction/list"
          handle_direction_list(client)
        elsif method == "GET" && path&.start_with?("/api/direction/show")
          handle_direction_show(client, path)
        elsif method == "POST" && path == "/api/direction/add"
          handle_direction_add(client, headers)
        elsif method == "GET" && path&.start_with?("/api/submission/status")
          handle_submission_status(client, path)
        elsif method == "GET" && path == "/api/direction/active"
          handle_direction_active(client)
        elsif method == "GET" && path == "/api/direction/draft"
          handle_draft_get(client)
        elsif method == "PUT" && path == "/api/direction/draft"
          handle_draft_put(client, headers)
        elsif method == "DELETE" && path == "/api/direction/draft"
          handle_draft_delete(client)
        else
          serve_not_found(client)
        end
      ensure
        client.close rescue nil
      end

      def handle_direction_list(client)
        dir = direction_dir
        completed_dir = File.join(dir, "completed")

        pending = list_directions(dir, completed: false)
        completed = list_directions(completed_dir, completed: true)

        write_json_response(client, 200, { pending: pending, completed: completed })
      end

      def handle_direction_active(client)
        active_dir = File.join(direction_dir, ".active")
        active = []

        if File.directory?(active_dir)
          Dir.glob(File.join(active_dir, "*.json")).each do |path|
            begin
              data = JSON.parse(File.read(path))
              pid = data["pid"]
              # Clean up stale entries where the process no longer exists
              if pid && !process_alive?(pid)
                File.delete(path) rescue nil
                next
              end
              active << data
            rescue JSON::ParserError, Errno::ENOENT
              next
            end
          end
        end

        write_json_response(client, 200, { active: active })
      end

      def process_alive?(pid)
        Process.kill(0, pid.to_i)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def handle_direction_show(client, path)
        # Parse query string for id parameter
        _, query = path.split("?", 2)
        params = {}
        if query
          query.split("&").each do |pair|
            key, value = pair.split("=", 2)
            params[key] = value
          end
        end

        id = params["id"]
        unless id && id.match?(/\A\d+\z/)
          write_json_response(client, 400, { error: "Missing or invalid id parameter" })
          return
        end

        dir = direction_dir
        # Search pending first, then completed
        match = Dir.glob(File.join(dir, "#{id}-*.md")).first
        match ||= Dir.glob(File.join(dir, "completed", "#{id}-*.md")).first

        unless match
          write_json_response(client, 404, { error: "Direction not found" })
          return
        end

        content = File.read(match) rescue ""
        basename = File.basename(match, ".md")
        m = basename.match(/\A(\d+)-(.+)\z/)
        title = m ? m[2] : basename

        write_json_response(client, 200, { id: id.to_i, title: title, content: content })
      end

      def direction_dir
        env_dir = ENV["AIJIGU_DIRECTION_DIR"]
        if env_dir && !env_dir.empty?
          File.expand_path(env_dir, File.expand_path("../..", __dir__))
        else
          File.expand_path("../../.directions", __dir__)
        end
      end

      def list_directions(dir, completed:)
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "[0-9]*-*.md")).filter_map do |path|
          basename = File.basename(path, ".md")
          match = basename.match(/\A(\d+)-(.+)\z/)
          next unless match

          id = match[1].to_i
          title = match[2]
          content = File.read(path).strip rescue ""
          # Take only lines before work notes (--- delimiter)
          summary = content.lines.first&.strip || ""

          { id: id, title: title, filename: File.basename(path), completed: completed, summary: summary,
            mtime: File.mtime(path).to_f }
        end.sort_by { |d| completed ? -d[:mtime] : d[:id] }
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

        # Create submission and process asynchronously
        submission_id = SecureRandom.hex(8)
        @submissions_mutex.synchronize do
          @submissions[submission_id] = { id: submission_id, status: "pending", instruction: instruction }
        end

        Thread.new do
          output, status = Open3.capture2(@aijigu_bin, "direction", "add", "-m", instruction)
          @submissions_mutex.synchronize do
            if status.success?
              @submissions[submission_id][:status] = "created"
              @submissions[submission_id][:filename] = output.strip
            else
              @submissions[submission_id][:status] = "error"
              @submissions[submission_id][:error] = "Failed to create direction"
            end
          end
        end

        write_json_response(client, 202, { submission_id: submission_id })
      end

      def handle_submission_status(client, path)
        _, query = path.split("?", 2)
        params = {}
        if query
          query.split("&").each do |pair|
            key, value = pair.split("=", 2)
            params[key] = value
          end
        end

        id = params["id"]
        unless id
          write_json_response(client, 400, { error: "Missing id parameter" })
          return
        end

        submission = @submissions_mutex.synchronize { @submissions[id]&.dup }
        if submission
          # Don't send instruction text back in status polls
          submission.delete(:instruction)
          write_json_response(client, 200, submission)
        else
          write_json_response(client, 404, { error: "Submission not found" })
        end
      end

      def handle_draft_get(client)
        write_json_response(client, 200, { draft: @draft })
      end

      def handle_draft_put(client, headers)
        content_length = headers["content-length"]&.to_i || 0
        body = content_length > 0 ? client.read(content_length) : ""

        begin
          data = JSON.parse(body)
        rescue JSON::ParserError
          write_json_response(client, 400, { error: "Invalid JSON" })
          return
        end

        @draft = data["draft"] || ""
        write_json_response(client, 200, { status: "saved" })
      end

      def handle_draft_delete(client)
        @draft = ""
        write_json_response(client, 200, { status: "cleared" })
      end

      # --- Authentication ---

      def auth_required?
        @auth_username && !@auth_username.empty? && @auth_password && !@auth_password.empty?
      end

      def parse_cookies(headers)
        cookies = {}
        cookie_header = headers["cookie"]
        return cookies unless cookie_header
        cookie_header.split(";").each do |pair|
          key, value = pair.strip.split("=", 2)
          cookies[key] = value if key && value
        end
        cookies
      end

      def valid_session?(session_id)
        return false unless session_id
        @sessions_mutex.synchronize do
          session = @sessions[session_id]
          return false unless session
          if Time.now > session[:expires_at]
            @sessions.delete(session_id)
            return false
          end
          true
        end
      end

      def create_session
        session_id = SecureRandom.hex(32)
        @sessions_mutex.synchronize do
          cleanup_expired_sessions_locked
          @sessions[session_id] = { expires_at: Time.now + SESSION_TTL }
        end
        session_id
      end

      def cleanup_expired_sessions_locked
        now = Time.now
        @sessions.delete_if { |_, v| now > v[:expires_at] }
      end

      def credentials_match?(username, password)
        secure_compare(username.to_s, @auth_username) & secure_compare(password.to_s, @auth_password)
      end

      def secure_compare(a, b)
        return false if a.nil? || b.nil?
        a_digest = Digest::SHA256.digest(a)
        b_digest = Digest::SHA256.digest(b)
        result = 0
        a_digest.bytes.zip(b_digest.bytes) { |x, y| result |= x ^ y }
        result == 0
      end

      def url_decode(str)
        str.gsub("+", " ").gsub(/%([0-9A-Fa-f]{2})/) { [$1.to_i(16)].pack("C") }
      end

      def parse_form_body(body)
        params = {}
        return params unless body
        body.split("&").each do |pair|
          key, value = pair.split("=", 2)
          params[url_decode(key)] = url_decode(value || "")
        end
        params
      end

      def handle_login(client, headers)
        content_length = headers["content-length"]&.to_i || 0
        body = content_length > 0 ? client.read(content_length) : ""

        params = parse_form_body(body)
        username = params["username"]
        password = params["password"]

        if credentials_match?(username, password)
          session_id = create_session
          cookie = "#{SESSION_COOKIE_NAME}=#{session_id}; Path=/; HttpOnly; SameSite=Strict; Max-Age=#{SESSION_TTL}"
          write_redirect(client, "/", set_cookie: cookie)
        else
          serve_login_page(client, error: true)
        end
      end

      def handle_logout(client, headers)
        cookies = parse_cookies(headers)
        session_id = cookies[SESSION_COOKIE_NAME]
        if session_id
          @sessions_mutex.synchronize { @sessions.delete(session_id) }
        end
        cookie = "#{SESSION_COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        write_redirect(client, "/", set_cookie: cookie)
      end

      def serve_login_page(client, error: false)
        body = login_html(error: error)
        write_response(client, 200, "OK", body)
      end

      def login_html(error: false)
        error_html = error ? '<div class="login-error">Invalid username or password</div>' : ""
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Login - AI Jig Utility</title>
            <style>
              *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                background: #f5f5f5;
                color: #333;
                min-height: 100vh;
                display: flex;
                align-items: center;
                justify-content: center;
              }
              .login-box {
                background: #fff;
                border: 1px solid #ccc;
                border-radius: 8px;
                padding: 2rem;
                width: 100%;
                max-width: 360px;
              }
              .login-box h1 {
                font-size: 1.25rem;
                font-weight: 600;
                color: #555;
                margin-bottom: 1.5rem;
                text-align: center;
              }
              .login-field {
                margin-bottom: 1rem;
              }
              .login-field label {
                display: block;
                font-size: 0.9rem;
                font-weight: 500;
                color: #555;
                margin-bottom: 0.3rem;
              }
              .login-field input {
                width: 100%;
                padding: 0.6rem 0.8rem;
                font-family: inherit;
                font-size: 1rem;
                border: 1px solid #ccc;
                border-radius: 6px;
                outline: none;
                transition: border-color 0.15s;
              }
              .login-field input:focus { border-color: #888; }
              .login-submit {
                width: 100%;
                padding: 0.6rem;
                font-family: inherit;
                font-size: 1rem;
                font-weight: 500;
                border: 1px solid #ccc;
                border-radius: 6px;
                background: #fff;
                color: #333;
                cursor: pointer;
                transition: background 0.15s, border-color 0.15s;
                margin-top: 0.5rem;
              }
              .login-submit:hover { background: #eee; border-color: #888; }
              .login-error {
                background: #fbe9e7;
                color: #c62828;
                border: 1px solid #ef9a9a;
                border-radius: 6px;
                padding: 0.6rem 1rem;
                font-size: 0.9rem;
                margin-bottom: 1rem;
              }
            </style>
          </head>
          <body>
            <div class="login-box">
              <h1>AI Jig Utility</h1>
              #{error_html}
              <form method="POST" action="/auth/login">
                <div class="login-field">
                  <label for="username">Username</label>
                  <input type="text" id="username" name="username" required autofocus>
                </div>
                <div class="login-field">
                  <label for="password">Password</label>
                  <input type="password" id="password" name="password" required>
                </div>
                <button type="submit" class="login-submit">Login</button>
              </form>
            </div>
          </body>
          </html>
        HTML
      end

      def serve_root(client)
        dir_label = File.basename(File.dirname(direction_dir))
        body = root_html(show_logout: auth_required?, dir_label: dir_label)
        write_response(client, 200, "OK", body)
      end

      def root_html(show_logout: false, dir_label: nil)
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{dir_label ? "#{dir_label} - " : ""}AI Jig Utility</title>
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
                padding: 1rem 1rem 0;
              }
              h1 {
                font-size: 1.25rem;
                font-weight: 600;
                margin-bottom: 1rem;
                color: #555;
              }
              .dir-label {
                font-size: 0.75rem;
                color: #bbb;
                font-weight: 400;
                margin-left: 0.5rem;
              }
              .header-row {
                display: flex;
                justify-content: space-between;
                align-items: center;
                margin-bottom: 1rem;
              }
              .header-row h1 { margin-bottom: 0; }
              .logout-btn {
                padding: 0.3rem 0.8rem;
                font-family: inherit;
                font-size: 0.85rem;
                border: 1px solid #ccc;
                border-radius: 6px;
                background: #fff;
                color: #888;
                cursor: pointer;
                transition: background 0.15s, border-color 0.15s, color 0.15s;
              }
              .logout-btn:hover { background: #eee; border-color: #888; color: #333; }
              .container {
                width: 100%;
                max-width: 720px;
                flex-shrink: 0;
              }
              textarea {
                width: 100%;
                min-height: 120px;
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
              .directions {
                width: 100%;
              }
              .directions h2 {
                font-size: 1rem;
                font-weight: 600;
                color: #555;
                margin-bottom: 0.5rem;
                cursor: pointer;
                user-select: none;
              }
              .directions h2::before {
                content: '\u25b6';
                display: inline-block;
                margin-right: 0.4rem;
                font-size: 0.7rem;
                transition: transform 0.15s;
              }
              .directions h2.expanded::before {
                transform: rotate(90deg);
              }
              .directions h2:hover { color: #333; }
              .direction-list {
                list-style: none;
                border: 1px solid #ccc;
                border-radius: 6px;
                background: #fff;
                overflow: hidden;
              }
              .direction-list:empty::after {
                content: "No directions";
                display: block;
                padding: 0.75rem 1rem;
                color: #aaa;
                font-size: 0.9rem;
              }
              .direction-item {
                padding: 0.6rem 1rem;
                border-bottom: 1px solid #eee;
                font-size: 0.9rem;
                display: flex;
                align-items: baseline;
                gap: 0.5rem;
              }
              .direction-item:last-child { border-bottom: none; }
              .direction-id {
                color: #888;
                font-size: 0.8rem;
                min-width: 2rem;
              }
              .direction-title { color: #333; }
              .direction-summary {
                color: #888;
                font-size: 0.8rem;
                margin-left: auto;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                max-width: 40%;
              }
              .direction-item { cursor: pointer; }
              .direction-item:hover { background: #f0f0f0; }
              .direction-item.active {
                background: #fff8e1;
                border-left: 3px solid #f9a825;
              }
              .direction-item.active:hover { background: #fff3c4; }
              .direction-item.active .direction-title { font-weight: 600; }
              .direction-item.active .direction-id::after {
                content: '';
                display: inline-block;
                width: 0.5rem;
                height: 0.5rem;
                background: #f9a825;
                border-radius: 50%;
                margin-left: 0.3rem;
                animation: pulse 1.5s ease-in-out infinite;
                vertical-align: middle;
              }
              @keyframes pulse {
                0%, 100% { opacity: 1; }
                50% { opacity: 0.3; }
              }
              .direction-item.selected { background: #e3f2fd; }
              .direction-item.selected:hover { background: #d0e8fc; }
              .direction-item.active.selected { background: #fff3c4; border-left: 3px solid #f9a825; }
              .direction-detail {
                flex: 1;
                border: 1px solid #ccc;
                border-radius: 6px;
                background: #fff;
                overflow: hidden;
                display: flex;
                flex-direction: column;
              }
              .direction-detail-header {
                display: flex;
                justify-content: space-between;
                align-items: center;
                padding: 0.6rem 1rem;
                border-bottom: 1px solid #eee;
                background: #fafafa;
              }
              .direction-detail-header span {
                font-size: 0.95rem;
                font-weight: 600;
                color: #333;
              }
              .direction-detail-close {
                background: none;
                border: none;
                font-size: 1.2rem;
                color: #888;
                cursor: pointer;
                padding: 0 0.25rem;
                line-height: 1;
              }
              .direction-detail-close:hover { color: #333; }
              .direction-detail-body {
                padding: 1rem;
                font-size: 0.9rem;
                line-height: 1.7;
                white-space: pre-wrap;
                word-wrap: break-word;
                color: #333;
                flex: 1;
                overflow-y: auto;
              }
              .submissions {
                margin-top: 0.75rem;
                display: flex;
                flex-direction: column;
                gap: 0.5rem;
              }
              .submission-item {
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding: 0.5rem 0.75rem;
                border-radius: 6px;
                font-size: 0.85rem;
                border: 1px solid #ccc;
                background: #fff;
              }
              .submission-pending {
                border-color: #90caf9;
                background: #e3f2fd;
              }
              .submission-created {
                border-color: #a5d6a7;
                background: #e8f5e9;
              }
              .submission-error {
                border-color: #ef9a9a;
                background: #fbe9e7;
              }
              .submission-content {
                display: flex;
                flex-direction: column;
                gap: 0.15rem;
                min-width: 0;
                flex: 1;
              }
              .submission-preview {
                color: #555;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
              }
              .submission-status { font-size: 0.8rem; }
              .submission-status.pending { color: #1565c0; }
              .submission-status.success { color: #2e7d32; }
              .submission-status.error { color: #c62828; }
              .submission-actions {
                display: flex;
                align-items: center;
                gap: 0.4rem;
                margin-left: 0.5rem;
                flex-shrink: 0;
              }
              .submission-action {
                padding: 0.2rem 0.6rem;
                font-size: 0.8rem;
                border-radius: 4px;
                border: 1px solid #ccc;
                background: #fff;
                cursor: pointer;
              }
              .submission-action:hover { background: #eee; border-color: #888; }
              .submission-dismiss {
                background: none;
                border: none;
                font-size: 1.1rem;
                color: #888;
                cursor: pointer;
                padding: 0 0.2rem;
                line-height: 1;
              }
              .submission-dismiss:hover { color: #333; }
              @keyframes spin { to { transform: rotate(360deg); } }
              .spinner {
                display: inline-block;
                width: 0.7rem;
                height: 0.7rem;
                border: 2px solid #90caf9;
                border-top-color: #1565c0;
                border-radius: 50%;
                animation: spin 0.8s linear infinite;
                vertical-align: middle;
                margin-right: 0.3rem;
              }
              .pane-container {
                display: flex;
                width: 100%;
                max-width: 1200px;
                flex: 1;
                min-height: 0;
                margin-top: 1rem;
                gap: 1rem;
                padding-bottom: 1rem;
              }
              .left-pane {
                width: 340px;
                flex-shrink: 0;
                overflow-y: auto;
                display: flex;
                flex-direction: column;
                gap: 1rem;
              }
              .right-pane {
                flex: 1;
                min-width: 0;
                display: flex;
                flex-direction: column;
              }
              .right-pane-placeholder {
                flex: 1;
                display: flex;
                align-items: center;
                justify-content: center;
                color: #aaa;
                font-size: 0.9rem;
                border: 1px dashed #ddd;
                border-radius: 6px;
                background: #fafafa;
              }
            </style>
          </head>
          <body>
            <div class="container">
              <div class="header-row">
                <h1>AI Jig Utility#{dir_label ? "<span class=\"dir-label\">#{dir_label}</span>" : ""}</h1>
                #{show_logout ? '<form method="POST" action="/auth/logout" style="margin:0;"><button type="submit" class="logout-btn">Logout</button></form>' : ''}
              </div>
              <textarea id="instruction" placeholder="Enter instruction..." autofocus></textarea>
              <div class="actions">
                <button id="submit" type="button">Submit</button>
              </div>
              <div id="notice" class="notice"></div>
              <div id="submissions" class="submissions" style="display:none;"></div>
            </div>
            <div class="pane-container">
              <div class="left-pane">
                <div class="directions">
                  <h2 id="pending-toggle" class="expanded">Pending</h2>
                  <ul id="pending-list" class="direction-list"></ul>
                </div>
                <div class="directions">
                  <h2 id="completed-toggle">Completed</h2>
                  <ul id="completed-list" class="direction-list" style="display:none;"></ul>
                </div>
              </div>
              <div class="right-pane">
                <div id="direction-detail" class="direction-detail" style="display:none;">
                  <div class="direction-detail-header">
                    <span id="direction-detail-title"></span>
                    <button class="direction-detail-close" id="direction-detail-close" type="button">&times;</button>
                  </div>
                  <div class="direction-detail-body" id="direction-detail-body"></div>
                </div>
                <div id="right-pane-placeholder" class="right-pane-placeholder">Select a direction to view details</div>
              </div>
            </div>
            <script>
              const textarea = document.getElementById('instruction');
              const submitBtn = document.getElementById('submit');
              const notice = document.getElementById('notice');
              const submissionsEl = document.getElementById('submissions');
              let lastSavedDraft = '';
              let submissions = [];
              let pollingInterval = null;
              let selectedDirectionId = null;
              let activeDirectionIds = new Set();

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

                // Clear textarea immediately so user can keep writing
                textarea.value = '';
                lastSavedDraft = '';
                fetch('/api/direction/draft', { method: 'DELETE' });
                textarea.focus();
                clearNotice();

                try {
                  const res = await fetch('/api/direction/add', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ instruction: text })
                  });
                  const data = await res.json();

                  if (res.ok && data.submission_id) {
                    addSubmission(data.submission_id, text);
                  } else {
                    addLocalError(text, data.error || 'An error occurred');
                  }
                } catch (e) {
                  addLocalError(text, 'A network error occurred');
                }
              }

              function addSubmission(id, instruction) {
                submissions.push({ id: id, instruction: instruction, status: 'pending', startTime: Date.now() });
                renderSubmissions();
                startPolling();
              }

              function addLocalError(instruction, error) {
                submissions.push({ id: 'local-' + Date.now(), instruction: instruction, status: 'error', error: error });
                renderSubmissions();
              }

              function startPolling() {
                if (pollingInterval) return;
                pollingInterval = setInterval(pollSubmissions, 2000);
              }

              function stopPollingIfDone() {
                if (!submissions.some(function(s) { return s.status === 'pending'; })) {
                  if (pollingInterval) { clearInterval(pollingInterval); pollingInterval = null; }
                }
              }

              async function pollSubmissions() {
                var pending = submissions.filter(function(s) { return s.status === 'pending'; });
                for (var i = 0; i < pending.length; i++) {
                  var sub = pending[i];
                  // Timeout after 5 minutes
                  if (Date.now() - sub.startTime > 300000) {
                    sub.status = 'error';
                    sub.error = 'Timed out';
                    renderSubmissions();
                    continue;
                  }
                  try {
                    var res = await fetch('/api/submission/status?id=' + sub.id);
                    var data = await res.json();
                    if (data.status === 'created') {
                      sub.status = 'created';
                      sub.filename = data.filename;
                      loadDirections();
                      scheduleAutoDismiss(sub.id);
                    } else if (data.status === 'error') {
                      sub.status = 'error';
                      sub.error = data.error || 'Failed to create direction';
                    }
                  } catch (e) {
                    // Keep polling on network errors
                  }
                }
                renderSubmissions();
                stopPollingIfDone();
              }

              function scheduleAutoDismiss(id) {
                setTimeout(function() { dismissSubmission(id); }, 8000);
              }

              function dismissSubmission(id) {
                submissions = submissions.filter(function(s) { return s.id !== id; });
                renderSubmissions();
              }

              function retrySubmission(id) {
                var sub = submissions.find(function(s) { return s.id === id; });
                if (sub) {
                  textarea.value = sub.instruction;
                  textarea.focus();
                  dismissSubmission(id);
                }
              }

              function renderSubmissions() {
                if (submissions.length === 0) {
                  submissionsEl.style.display = 'none';
                  return;
                }
                submissionsEl.style.display = '';
                submissionsEl.innerHTML = '';

                submissions.forEach(function(sub) {
                  var div = document.createElement('div');
                  div.className = 'submission-item submission-' + sub.status;

                  var preview = sub.instruction.split('\\n')[0];
                  if (preview.length > 80) preview = preview.substring(0, 80) + '...';

                  var statusHtml = '';
                  var actionsHtml = '';
                  if (sub.status === 'pending') {
                    statusHtml = '<span class="submission-status pending"><span class="spinner"></span>Submitting...</span>';
                  } else if (sub.status === 'created') {
                    statusHtml = '<span class="submission-status success">Created: ' + escapeHtml(sub.filename || '') + '</span>';
                  } else {
                    statusHtml = '<span class="submission-status error">' + escapeHtml(sub.error || 'Error') + '</span>';
                    actionsHtml = '<button class="submission-action" data-retry="' + escapeHtml(sub.id) + '">Retry</button>';
                  }

                  div.innerHTML =
                    '<div class="submission-content">' +
                      '<span class="submission-preview">' + escapeHtml(preview) + '</span>' +
                      statusHtml +
                    '</div>' +
                    '<div class="submission-actions">' +
                      actionsHtml +
                      '<button class="submission-dismiss" data-dismiss="' + escapeHtml(sub.id) + '">&times;</button>' +
                    '</div>';

                  submissionsEl.appendChild(div);
                });

                // Attach event listeners
                submissionsEl.querySelectorAll('[data-retry]').forEach(function(btn) {
                  btn.addEventListener('click', function() { retrySubmission(btn.getAttribute('data-retry')); });
                });
                submissionsEl.querySelectorAll('[data-dismiss]').forEach(function(btn) {
                  btn.addEventListener('click', function() { dismissSubmission(btn.getAttribute('data-dismiss')); });
                });
              }

              submitBtn.addEventListener('click', submit);
              textarea.addEventListener('keydown', function(e) {
                if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
                  e.preventDefault();
                  submit();
                }
              });

              const pendingList = document.getElementById('pending-list');
              const completedList = document.getElementById('completed-list');
              const pendingToggle = document.getElementById('pending-toggle');
              const completedToggle = document.getElementById('completed-toggle');

              function renderDirections(list, directions, showActive) {
                list.innerHTML = '';
                directions.forEach(function(d) {
                  const li = document.createElement('li');
                  li.className = 'direction-item';
                  if (showActive && activeDirectionIds.has(d.id)) li.classList.add('active');
                  li.innerHTML =
                    '<span class="direction-id">#' + d.id + '</span>' +
                    '<span class="direction-title">' + escapeHtml(d.title) + '</span>' +
                    '<span class="direction-summary">' + escapeHtml(d.summary) + '</span>';
                  if (d.id === selectedDirectionId) li.classList.add('selected');
                  li.addEventListener('click', function() { showDirection(d.id); });
                  list.appendChild(li);
                });
              }

              function escapeHtml(str) {
                var d = document.createElement('div');
                d.textContent = str;
                return d.innerHTML;
              }

              function toggleList(heading, el) {
                el.style.display = el.style.display === 'none' ? '' : 'none';
                heading.classList.toggle('expanded');
              }

              pendingToggle.addEventListener('click', function() { toggleList(pendingToggle, pendingList); });
              completedToggle.addEventListener('click', function() { toggleList(completedToggle, completedList); });

              const detailPanel = document.getElementById('direction-detail');
              const detailTitle = document.getElementById('direction-detail-title');
              const detailBody = document.getElementById('direction-detail-body');
              const detailClose = document.getElementById('direction-detail-close');

              async function showDirection(id) {
                selectedDirectionId = id;
                document.querySelectorAll('.direction-item').forEach(function(el) { el.classList.remove('selected'); });
                document.querySelectorAll('.direction-item').forEach(function(el) {
                  if (el.querySelector('.direction-id') && el.querySelector('.direction-id').textContent === '#' + id) {
                    el.classList.add('selected');
                  }
                });
                try {
                  const res = await fetch('/api/direction/show?id=' + id);
                  const data = await res.json();
                  if (res.ok) {
                    detailTitle.textContent = '#' + data.id + ' ' + data.title;
                    detailBody.textContent = data.content;
                    detailPanel.style.display = '';
                    document.getElementById('right-pane-placeholder').style.display = 'none';
                  } else {
                    showNotice(data.error || 'An error occurred', 'error');
                  }
                } catch (e) {
                  showNotice('A network error occurred', 'error');
                }
              }

              detailClose.addEventListener('click', function() {
                detailPanel.style.display = 'none';
                document.getElementById('right-pane-placeholder').style.display = '';
                selectedDirectionId = null;
                document.querySelectorAll('.direction-item').forEach(function(el) { el.classList.remove('selected'); });
              });

              async function loadDirections() {
                try {
                  const res = await fetch('/api/direction/list');
                  const data = await res.json();
                  renderDirections(pendingList, data.pending || [], true);
                  renderDirections(completedList, data.completed || [], false);
                } catch (e) {
                  // Silently ignore load errors
                }
              }

              async function loadActiveDirections() {
                try {
                  const res = await fetch('/api/direction/active');
                  const data = await res.json();
                  const newActive = new Set((data.active || []).map(function(a) { return a.id; }));
                  if (setsEqual(activeDirectionIds, newActive)) return;
                  activeDirectionIds = newActive;
                  // Re-render direction lists to update highlighting
                  loadDirections();
                } catch (e) {
                  // Silently ignore
                }
              }

              function setsEqual(a, b) {
                if (a.size !== b.size) return false;
                for (const v of a) { if (!b.has(v)) return false; }
                return true;
              }

              async function loadDraft() {
                try {
                  const res = await fetch('/api/direction/draft');
                  const data = await res.json();
                  if (res.ok && data.draft) {
                    textarea.value = data.draft;
                    lastSavedDraft = data.draft;
                  }
                } catch (e) {
                  // Silently ignore
                }
              }

              async function saveDraft() {
                const current = textarea.value;
                if (current === lastSavedDraft) return;
                lastSavedDraft = current;
                try {
                  await fetch('/api/direction/draft', {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ draft: current })
                  });
                } catch (e) {
                  // Silently ignore
                }
              }

              setInterval(saveDraft, 3000);

              loadDraft();
              loadDirections();
              loadActiveDirections();
              setInterval(loadDirections, 10000);
              setInterval(loadActiveDirections, 3000);
            </script>
          </body>
          </html>
        HTML
      end

      def serve_not_found(client)
        write_response(client, 404, "Not Found", "Not Found\n")
      end

      def write_json_response(client, status, data)
        reason = { 200 => "OK", 201 => "Created", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", 500 => "Internal Server Error" }[status] || "OK"
        body = JSON.generate(data)
        write_response(client, status, reason, body, content_type: "application/json; charset=utf-8")
      end

      def write_redirect(client, location, set_cookie: nil)
        client.print "HTTP/1.1 302 Found\r\n"
        client.print "Location: #{location}\r\n"
        client.print "Set-Cookie: #{set_cookie}\r\n" if set_cookie
        client.print "Content-Length: 0\r\n"
        client.print "Connection: close\r\n"
        client.print "\r\n"
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
  require "optparse"

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: aijigu web start [options]"
    opts.on("-p", "--port PORT", Integer, "Port number (default: #{Aijigu::Web::Server::DEFAULT_PORT})") { |v| options[:port] = v }
    opts.on("-b", "--bind HOST", "Bind address (default: #{Aijigu::Web::Server::DEFAULT_HOST})") { |v| options[:host] = v }
  end.parse!

  Aijigu::Web::Server.new(**options).start
end
