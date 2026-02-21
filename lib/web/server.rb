#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal HTTP server using only Ruby standard library (no gems).
# Uses WEBrick which ships with Ruby and requires no external dependencies.

require "socket"
require "json"
require "open3"
require "securerandom"

module Aijigu
  module Web
    class Server
      DEFAULT_HOST = "127.0.0.1"
      DEFAULT_PORT = 8080

      def initialize(host: nil, port: nil)
        @host = host || ENV.fetch("AIJIGU_WEB_HOST", DEFAULT_HOST)
        @port = (port || ENV.fetch("AIJIGU_WEB_PORT", DEFAULT_PORT)).to_i
        @aijigu_bin = File.expand_path("../../bin/aijigu", __dir__)
        @draft = ""
        @submissions = {}
        @submissions_mutex = Mutex.new
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

          { id: id, title: title, filename: File.basename(path), completed: completed, summary: summary }
        end.sort_by { |d| d[:id] }
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

      def serve_root(client)
        body = root_html
        write_response(client, 200, "OK", body)
      end

      def root_html
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
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
              .directions {
                margin-top: 2rem;
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
              .direction-detail {
                margin-top: 1rem;
                border: 1px solid #ccc;
                border-radius: 6px;
                background: #fff;
                overflow: hidden;
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
            </style>
          </head>
          <body>
            <div class="container">
              <h1>aijigu</h1>
              <textarea id="instruction" placeholder="Enter instruction..." autofocus></textarea>
              <div class="actions">
                <button id="submit" type="button">Submit</button>
              </div>
              <div id="notice" class="notice"></div>
              <div id="submissions" class="submissions" style="display:none;"></div>
              <div class="directions">
                <h2 id="pending-toggle" class="expanded">Pending</h2>
                <ul id="pending-list" class="direction-list"></ul>
              </div>
              <div class="directions">
                <h2 id="completed-toggle">Completed</h2>
                <ul id="completed-list" class="direction-list" style="display:none;"></ul>
              </div>
              <div id="direction-detail" class="direction-detail" style="display:none;">
                <div class="direction-detail-header">
                  <span id="direction-detail-title"></span>
                  <button class="direction-detail-close" id="direction-detail-close" type="button">&times;</button>
                </div>
                <div class="direction-detail-body" id="direction-detail-body"></div>
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

              function renderDirections(list, directions) {
                list.innerHTML = '';
                directions.forEach(function(d) {
                  const li = document.createElement('li');
                  li.className = 'direction-item';
                  li.innerHTML =
                    '<span class="direction-id">#' + d.id + '</span>' +
                    '<span class="direction-title">' + escapeHtml(d.title) + '</span>' +
                    '<span class="direction-summary">' + escapeHtml(d.summary) + '</span>';
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
                try {
                  const res = await fetch('/api/direction/show?id=' + id);
                  const data = await res.json();
                  if (res.ok) {
                    detailTitle.textContent = '#' + data.id + ' ' + data.title;
                    detailBody.textContent = data.content;
                    detailPanel.style.display = '';
                  } else {
                    showNotice(data.error || 'An error occurred', 'error');
                  }
                } catch (e) {
                  showNotice('A network error occurred', 'error');
                }
              }

              detailClose.addEventListener('click', function() {
                detailPanel.style.display = 'none';
              });

              async function loadDirections() {
                try {
                  const res = await fetch('/api/direction/list');
                  const data = await res.json();
                  renderDirections(pendingList, data.pending || []);
                  renderDirections(completedList, data.completed || []);
                } catch (e) {
                  // Silently ignore load errors
                }
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
              setInterval(loadDirections, 10000);
            </script>
          </body>
          </html>
        HTML
      end

      def serve_not_found(client)
        write_response(client, 404, "Not Found", "Not Found\n")
      end

      def write_json_response(client, status, data)
        reason = { 200 => "OK", 201 => "Created", 202 => "Accepted", 400 => "Bad Request", 404 => "Not Found", 500 => "Internal Server Error" }[status] || "OK"
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
  require "optparse"

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: aijigu web start [options]"
    opts.on("-p", "--port PORT", Integer, "Port number (default: #{Aijigu::Web::Server::DEFAULT_PORT})") { |v| options[:port] = v }
    opts.on("-b", "--bind HOST", "Bind address (default: #{Aijigu::Web::Server::DEFAULT_HOST})") { |v| options[:host] = v }
  end.parse!

  Aijigu::Web::Server.new(**options).start
end
