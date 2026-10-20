// Claude Code: what it's doing right now, from its hooks, and how much of your plan you've used, from its status line.
// Claude Code runs a tiny shell script on each event, which hands the event to Mochi over a socket on 127.0.0.1, so nothing
// leaves your Mac. "Connect Claude Code" adds those scripts to ~/.claude/settings.json; "Disconnect" takes them back out.
import AppKit
import JavaScriptCore
import Network

/// One Claude Code session: a terminal tab, editor panel or desktop app chat running Claude Code.
struct ClaudeSession {
    let id: String
    var cwd = ""
    var app: pid_t = 0                  // the app it's running in (Terminal, VS Code, Claude...), for jumping to it
    var busy = false
    var busySince = 0.0
    var tool = ""                       // what it's doing, one of ClaudeCode.activity's names
    var toolName = ""
    var detail = ""                     // the file, command or search it's working on
    var running = 0                     // tools started and not finished yet
    var toolUntil = 0.0
    var need: String?                   // waiting on you: "permission", "question" or "input"
    var needTool = ""
    var needAt = 0.0
    var errorUntil = 0.0
    var errDetail = ""
    var doneUntil = 0.0
    var greetUntil = 0.0
    var compactAt = 0.0
    var agents: [String: Double] = [:]  // sub-agents working, by id → when we last heard from one
    var spawns = 0
    var todos: (done: Int, total: Int) = (0, 0)
    var ctx: Double?                    // how full its context window is, %
    var last = 0.0
    var project: String { cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent }
    var helpers: Int { max(agents.count, spawns) }
}

/// One of your plan's usage windows: how much is used, and when it starts over.
struct UsageWindow { var pct: Double; var resets: Date? }

final class ClaudeCode {
    static let port: UInt16 = 47833
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                         "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]

    var sessions: [String: ClaudeSession] = [:]
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var usageAt: Date?
    var onChange: (() -> Void)?
    var listening = false
    private var listener: NWListener?
    private let dataDir: URL
    private let defaults = UserDefaults.standard

    init(dataDir: URL) {
        self.dataDir = dataDir
        if let u = defaults.dictionary(forKey: "claudeUsage") {
            fiveHour = Self.window(u["five"])
            weekly = Self.window(u["seven"])
            usageAt = (u["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        }
    }

    // MARK: listening

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else { return NSLog("[mochi] claude: could not listen on %d", Self.port) }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: self?.listening = true
                case .failed(let e): self?.listening = false; NSLog("[mochi] claude: listener failed: %@", "\(e)")
                default: break
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    /// A tiny HTTP server: one POST per connection, from the hook scripts.
    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        var buf = Data()
        func done(_ ok: Bool) {
            let reply = ok ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" : "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
            c.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
        }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, finished, error in
                guard let self else { return c.cancel() }
                if let chunk { buf.append(chunk) }
                if buf.count > 32 << 20 || error != nil { return c.cancel() }
                if let head = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buf[..<head.lowerBound], as: UTF8.self)
                    let lines = header.components(separatedBy: "\r\n")
                    var fields: [String: String] = [:]
                    for line in lines.dropFirst() {
                        guard let i = line.firstIndex(of: ":") else { continue }
                        fields[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                    }
                    let length = Int(fields["content-length"] ?? "") ?? 0
                    let body = buf[head.upperBound...]
                    if body.count >= length {
                        // the custom header means a web page can't post here: browsers won't send it cross-site without asking first
                        guard fields["x-mochi"] == "1", let path = lines.first?.split(separator: " ").dropFirst().first else { return done(false) }
                        let json = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:]
                        let pid = pid_t(fields["x-claude-pid"] ?? "") ?? 0
                        switch path {
                        case "/hook": self.onHook(json, pid: pid)
                        case "/status": self.onStatus(json)
                        case "/ping": break
                        default: return done(false)
                        }
                        return done(true)
                    }
                }
                if finished { return c.cancel() }
                read()
            }
        }
        read()
    }

    // MARK: what Claude is up to

    /// The kind of work a tool call is, which picks Mochi's pose.
    static func activity(_ tool: String, _ input: [String: Any]) -> String {
        let command = input["command"] as? String ?? ""
        switch tool {
        case "Read", "NotebookRead": return "reading"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "writing"
        case "Grep", "Glob", "LS": return "searchCode"
        case "WebSearch", "WebFetch": return "searchWeb"
        case "Task", "Agent": return "agents"
        case "TodoWrite", "TaskCreate", "TaskUpdate": return "plan"
        case "Bash", "BashOutput":
            if command.range(of: #"\bgit\s+(commit|push)\b"#, options: .regularExpression) != nil { return "committing" }
            if command.range(of: #"\b(test|tests|jest|vitest|pytest|mocha|playwright|rspec|xcodebuild test|swift test|go test|cargo test)\b"#, options: .regularExpression) != nil { return "testing" }
            if command.range(of: #"\b(run dev|npm start|yarn dev|pnpm dev|vite|next dev|http-server|serve|runserver|rails s)\b"#, options: .regularExpression) != nil { return "server" }
            return "command"
        default: return "tool"
        }
    }

    /// The bit worth saying out loud: a file name, a command, a search.
    static func detail(_ tool: String, _ input: [String: Any]) -> String {
        func short(_ s: String, _ n: Int) -> String {
            let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return t.count > n ? String(t.prefix(n - 1)) + "…" : t
        }
        if let f = (input["file_path"] ?? input["notebook_path"]) as? String { return (f as NSString).lastPathComponent }
        if tool == "WebFetch", let u = input["url"] as? String { return URL(string: u)?.host ?? short(u, 40) }
        for key in ["description", "pattern", "query", "command", "subject"] {
            if let s = input[key] as? String, !s.isEmpty { return short(s, 44) }
        }
        if let p = input["path"] as? String { return (p as NSString).lastPathComponent }
        return tool.hasPrefix("mcp__") ? short(tool.components(separatedBy: "__").dropFirst().joined(separator: " "), 40) : ""
    }

    private func onHook(_ e: [String: Any], pid: pid_t) {
        let event = e["hook_event_name"] as? String ?? ""
        let id = e["session_id"] as? String ?? "default"
        let now = Date().timeIntervalSince1970
        if event == "SessionEnd" { sessions[id] = nil; return changed() }
        var s = sessions[id] ?? ClaudeSession(id: id)
        s.last = now
        if let cwd = e["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if s.app == 0, pid > 0, let app = Self.app(owning: pid) { s.app = app.processIdentifier }
        let tool = e["tool_name"] as? String ?? ""
        let input = e["tool_input"] as? [String: Any] ?? [:]

        // a sub-agent's own tool calls: just keep track that it's still at it
        if let agent = e["agent_id"] as? String, !agent.isEmpty, event != "SubagentStart" {
            if event == "SubagentStop" { s.agents[agent] = nil; s.spawns = max(0, s.spawns - 1) } else { s.agents[agent] = now }
            sessions[id] = s
            return changed()
        }
        if !["Notification", "PermissionRequest"].contains(event) { s.need = nil }
        if !["PreCompact"].contains(event) { s.compactAt = 0 }
        switch event {
        case "SessionStart":
            s.greetUntil = e["source"] as? String == "startup" ? now + 5 : 0
        case "UserPromptSubmit":
            s.busy = true; s.busySince = now; s.doneUntil = 0; s.errorUntil = 0
        case "PreToolUse":
            s.busy = true
            s.running += 1
            s.tool = Self.activity(tool, input)
            s.toolName = tool
            s.detail = Self.detail(tool, input)
            s.toolUntil = .infinity
            if tool == "Task" || tool == "Agent" { s.spawns += 1 }
            if let todos = input["todos"] as? [[String: Any]] {
                s.todos = (todos.filter { $0["status"] as? String == "completed" }.count, todos.count)
            }
        case "PostToolUse", "PostToolUseFailure":
            s.running = max(0, s.running - 1)
            s.toolUntil = now + 2.5
            if tool == "Task" || tool == "Agent" { s.spawns = max(0, s.spawns - 1) }
            if event == "PostToolUseFailure" && e["is_interrupt"] as? Bool != true {
                s.errorUntil = now + 4
                s.errDetail = Self.detail(tool, input)
            }
        case "PermissionRequest":
            s.need = "permission"; s.needTool = tool; s.needAt = now
        case "Notification":
            switch e["notification_type"] as? String ?? "" {
            case "permission_prompt":
                if s.need == nil { s.need = "permission"; s.needAt = now }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                s.need = "question"; s.needAt = now
            default: break   // "waiting for your input" after it's done, logins, and so on: nothing to act out
            }
        case "Stop":
            s.busy = false; s.running = 0; s.spawns = 0; s.agents = [:]; s.toolUntil = 0; s.doneUntil = now + 6
        case "StopFailure":
            s.busy = false; s.running = 0; s.spawns = 0; s.agents = [:]; s.toolUntil = 0; s.errorUntil = now + 6; s.errDetail = ""
        case "SubagentStart":
            if let agent = e["agent_id"] as? String { s.agents[agent] = now }
        case "SubagentStop":
            if let agent = e["agent_id"] as? String { s.agents[agent] = nil }
        case "PreCompact":
            s.compactAt = now
        default:
            break
        }
        sessions[id] = s
        changed()
    }

    private func onStatus(_ j: [String: Any]) {
        if let r = j["rate_limits"] as? [String: Any] {
            // each update is the whole picture: a window it leaves out has reset, so don't keep an old number for it
            fiveHour = Self.window(r["five_hour"])
            weekly = Self.window(r["seven_day"])
            usageAt = Date()
            var saved: [String: Any] = ["at": usageAt!.timeIntervalSince1970]
            if let w = fiveHour { saved["five"] = ["used_percentage": w.pct, "resets_at": w.resets?.timeIntervalSince1970 ?? 0] }
            if let w = weekly { saved["seven"] = ["used_percentage": w.pct, "resets_at": w.resets?.timeIntervalSince1970 ?? 0] }
            defaults.set(saved, forKey: "claudeUsage")
        }
        if let id = j["session_id"] as? String, var s = sessions[id] {
            s.ctx = (j["context_window"] as? [String: Any])?["used_percentage"] as? Double
            sessions[id] = s
        }
        changed()
    }

    static func window(_ any: Any?) -> UsageWindow? {
        guard let w = any as? [String: Any], let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        let at = (w["resets_at"] as? NSNumber)?.doubleValue ?? 0
        return UsageWindow(pct: pct, resets: at > 0 ? Date(timeIntervalSince1970: at > 1e12 ? at / 1000 : at) : nil)
    }

    /// A usage window as it stands now: one whose reset time has passed has started over.
    func current(_ w: UsageWindow?) -> UsageWindow? {
        guard var w else { return nil }
        if let r = w.resets, r < Date() { w.pct = 0; w.resets = nil }
        return w
    }

    private func changed() { onChange?() }

    /// Lets go of sessions that went quiet: a closed terminal never says goodbye.
    func prune() {
        let now = Date().timeIntervalSince1970
        for (id, var s) in sessions {
            if now - s.last > 3 * 3600 { sessions[id] = nil; continue }
            if s.busy && now - s.last > (s.running > 0 ? 30 * 60 : 5 * 60) { s.busy = false; s.running = 0; s.spawns = 0; s.toolUntil = 0 }
            if s.need != nil && now - s.needAt > 30 * 60 { s.need = nil }
            s.agents = s.agents.filter { now - $0.value < 3 * 60 }
            sessions[id] = s
        }
    }

    /// The one thing worth showing right now, across every session, most urgent first.
    func summary() -> (state: String, session: ClaudeSession?) {
        let now = Date().timeIntervalSince1970
        let list = sessions.values.sorted { $0.last > $1.last }
        if let s = list.filter({ $0.need != nil }).max(by: { $0.needAt < $1.needAt }) { return ("waiting", s) }
        if let s = list.first(where: { now < $0.errorUntil }) { return ("error", s) }
        if let s = list.first(where: { $0.compactAt > 0 && now - $0.compactAt < 90 }) { return ("compacting", s) }
        if let s = list.first(where: { $0.busy && $0.helpers > 0 }) { return ("agents", s) }
        if let s = list.first(where: { !$0.tool.isEmpty && ($0.running > 0 || now < $0.toolUntil) }) { return (s.tool, s) }
        if let s = list.first(where: { $0.busy }) { return ((s.ctx ?? 0) >= 85 ? "contextFull" : "thinking", s) }
        if let s = list.first(where: { now < $0.doneUntil }) { return ("done", s) }
        if let s = list.first(where: { now < $0.greetUntil }) { return ("hello", s) }
        return ("", nil)
    }

    /// What the page gets: enough for Mochi to act it out and say a word about it.
    func payload() -> [String: Any] {
        let (state, s) = summary()
        var d: [String: Any] = ["state": state, "sessions": sessions.count, "busy": sessions.values.filter { $0.busy }.count]
        if let s {
            d["project"] = s.project
            d["tool"] = s.toolName
            d["detail"] = state == "error" ? s.errDetail : s.detail
            d["need"] = s.need ?? ""
            d["needTool"] = s.needTool
            d["helpers"] = s.helpers
            if s.todos.total > 0 { d["todo"] = [s.todos.done, s.todos.total] }
            if let c = s.ctx { d["ctx"] = c }
        }
        return d
    }

    // MARK: jumping to a session's window

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let p = info.kp_eproc.e_ppid
        return p > 1 ? p : nil
    }

    /// The app a process belongs to: walk up its parents until one is an app with a window.
    static func app(owning pid: pid_t) -> NSRunningApplication? {
        var p: pid_t? = pid
        for _ in 0..<40 {
            guard let cur = p else { break }
            if let a = NSRunningApplication(processIdentifier: cur), a.activationPolicy == .regular { return a }
            p = parent(of: cur)
        }
        return nil
    }

    func focus(_ session: ClaudeSession?) {
        guard let s = session ?? summary().session ?? sessions.values.max(by: { $0.last < $1.last }),
              let app = NSRunningApplication(processIdentifier: s.app) else { return }
        app.activate()
    }

    // MARK: connecting to Claude Code

    lazy var settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    var hookScript: URL { dataDir.appendingPathComponent("claude-hook.sh") }
    var statusScript: URL { dataDir.appendingPathComponent("claude-status.sh") }
    var originalStatus: URL { dataDir.appendingPathComponent("claude-status-original.json") }
    var hasClaudeCode: Bool { FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path) }

    var connected: Bool {
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return text.contains("Mochi/claude-hook.sh")
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Adds Mochi's hooks and status line to Claude Code's settings, or takes them out again. Everything else is left alone,
    /// in the same order, and the file is backed up first. A status line you already had keeps showing: Mochi's passes it through.
    func connect(_ on: Bool) throws {
        let fm = FileManager.default
        let text = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? "{}"
        if on { try writeScripts() }
        // done in JavaScript so the file keeps its key order and formatting
        let ctx = JSContext()!
        ctx.evaluateScript(Self.configureJS)
        let hook = Self.quote(hookScript.path), status = Self.quote(statusScript.path)
        let original = (try? String(contentsOf: originalStatus, encoding: .utf8)) ?? ""
        let r = ctx.objectForKeyedSubscript("configure").call(withArguments: [text, on, hook, status, Self.events, original])
        if let err = ctx.exception?.toString() ?? r?.objectForKeyedSubscript("error")?.toString(), err != "undefined" {
            throw NSError(domain: "Mochi", code: 1, userInfo: [NSLocalizedDescriptionKey: err])
        }
        guard let out = r?.objectForKeyedSubscript("text")?.toString() else { return }
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.mochi-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        try out.write(to: settingsURL, atomically: true, encoding: .utf8)
        if on, let saved = r?.objectForKeyedSubscript("original")?.toString(), saved != "undefined", !saved.isEmpty {
            try saved.write(to: originalStatus, atomically: true, encoding: .utf8)
        }
        if !on { try? fm.removeItem(at: originalStatus) }
    }

    private func writeScripts() throws {
        let url = "http://127.0.0.1:\(Self.port)"
        let hook = """
        #!/bin/sh
        # Mochi's Claude Code hook: hands each event to Mochi, on this Mac only. Never slows down or fails Claude.
        curl -s -m 2 -o /dev/null -H 'X-Mochi: 1' -H "X-Claude-Pid: $PPID" -H 'Content-Type: application/json' --data-binary @- \(url)/hook 2>/dev/null
        exit 0

        """
        let status = """
        #!/bin/sh
        # Mochi's Claude Code status line: tells Mochi your usage limits, then shows your own status line if you had one.
        input=$(cat)
        printf '%s' "$input" | curl -s -m 1 -o /dev/null -H 'X-Mochi: 1' -H 'Content-Type: application/json' --data-binary @- \(url)/status 2>/dev/null
        cmd=$(/usr/bin/plutil -extract command raw -o - \(Self.quote(originalStatus.path)) 2>/dev/null)
        [ -n "$cmd" ] && printf '%s' "$input" | /bin/sh -c "$cmd"
        exit 0

        """
        for (script, text) in [(hookScript, hook), (statusScript, status)] {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
    }

    private static let configureJS = #"""
    function configure(text, on, hook, status, events, original) {
      var s = text.trim() ? JSON.parse(text) : {};
      if (!s || typeof s !== 'object' || Array.isArray(s)) return { error: 'Claude Code settings must be a JSON object.' };
      var mine = function (h) { return h && typeof h.command === 'string' && h.command.indexOf('Mochi/claude-') !== -1; };
      var hooks = s.hooks && typeof s.hooks === 'object' ? s.hooks : {};
      events.forEach(function (ev) {
        var groups = (hooks[ev] || []).map(function (g) { return Object.assign({}, g, { hooks: (g.hooks || []).filter(function (h) { return !mine(h); }) }); })
          .filter(function (g) { return g.hooks.length; });
        if (on) groups.push({ hooks: [{ type: 'command', command: hook, async: true }] });
        if (groups.length) hooks[ev] = groups; else delete hooks[ev];
      });
      if (Object.keys(hooks).length) s.hooks = hooks; else delete s.hooks;
      var saved;
      if (on) {
        if (s.statusLine && !mine(s.statusLine)) saved = JSON.stringify(s.statusLine);
        var line = Object.assign({}, s.statusLine && !mine(s.statusLine) ? s.statusLine : (original ? JSON.parse(original) : {}), { type: 'command', command: status });
        s.statusLine = line;
      } else if (mine(s.statusLine)) {
        if (original) s.statusLine = JSON.parse(original); else delete s.statusLine;
      }
      return { text: JSON.stringify(s, null, 2) + '\n', original: saved };
    }
    """#
}
