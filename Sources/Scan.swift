import Foundation

// ponytail: name heuristics — add an entry when a new agent CLI or service shows up.
let agentNames = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "aider": "Aider", "opencode": "opencode",
                  "goose": "Goose", "amp": "Amp", "cursor-agent": "Cursor Agent", "copilot": "Copilot CLI", "qwen": "Qwen Code", "crush": "Crush"]
// ponytail: beam.smp/epmd assumed RabbitMQ; an Elixir app with a project cwd still lands under Projects.
let serviceNames = ["mariadbd": "MariaDB", "mysqld": "MySQL", "postgres": "Postgres", "redis-server": "Redis", "com.docker.backend": "Docker",
                    "beam.smp": "RabbitMQ", "epmd": "RabbitMQ", "mailpit": "Mailpit", "php-fpm": "PHP-FPM", "ollama": "Ollama",
                    "mongod": "MongoDB", "nginx": "nginx", "httpd": "Apache", "memcached": "Memcached", "caddy": "Caddy", "minio": "MinIO"]
let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]
let cliNames = ["claude", "codex", "gemini", "aider", "ollama", "opencode", "goose", "amp", "cursor-agent", "copilot", "qwen", "crush", "llm"]
let appNames = ["Claude", "ChatGPT", "Cursor", "Windsurf", "Ollama", "LM Studio", "Msty", "Jan"]

struct Listener: Hashable { let port: Int; let pid: Int32; let cmd: String }
struct Agent: Hashable { let pid: Int32; let name: String; let host: String; let project: String? }
struct Group: Identifiable { let id: String; let title: String; var path: String?; var ports: [Listener] = []; var agents: [Agent] = [] }
struct Snapshot { var projects: [Group] = [], services: [Group] = [], other: [Group] = [], agents: [Agent] = [], ollamaModels: Int? = nil }


func run(_ path: String, _ args: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice // rc-file prompts (e.g. "update? [Y/n]") get EOF instead of hanging
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func base(_ path: some StringProtocol) -> String { (String(path) as NSString).lastPathComponent }

/// Splits off the first n-1 whitespace-separated fields; the last field keeps its spaces.
func fields(_ s: Substring, _ n: Int) -> [String] {
    var rest = s, out = [String]()
    for _ in 1..<n {
        rest = rest.drop(while: \.isWhitespace)
        let f = rest.prefix(while: { !$0.isWhitespace })
        out.append(String(f))
        rest = rest.dropFirst(f.count)
    }
    out.append(String(rest.drop(while: \.isWhitespace)))
    return out
}

/// Git root if inside a repo, else the folder. nil outside ~, in ~/Library or dot-dirs (system/app processes).
func projectRoot(_ cwd: String) -> String? {
    let home = NSHomeDirectory()
    guard cwd.hasPrefix(home + "/"), !cwd.hasPrefix(home + "/Library"), !cwd.contains("/.") else { return nil }
    var url = URL(fileURLWithPath: cwd)
    while url.path != home {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
        url.deleteLastPathComponent()
    }
    return cwd
}

func cwds(_ pids: [Int32]) -> [Int32: String] {
    guard !pids.isEmpty else { return [:] }
    var out = [Int32: String](), pid: Int32 = 0
    for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-Fn"]).split(separator: "\n") {
        if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
        else if line.hasPrefix("n") { out[pid] = String(line.dropFirst()) }
    }
    return out
}

func listeningPorts() -> [Listener] {
    var rows = [Listener](), seen = Set<String>(), pid: Int32 = 0, cmd = ""
    for line in run("/usr/sbin/lsof", ["+c", "0", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-Fpcn"]).split(separator: "\n") {
        switch line.first {
        case "p": pid = Int32(line.dropFirst()) ?? 0
        case "c": cmd = String(line.dropFirst())
        case "n":
            // keyed by cmd, not pid: worker pools (php-fpm) share one port
            if let port = Int(line.split(separator: ":").last ?? ""), seen.insert("\(cmd):\(port)").inserted {
                rows.append(Listener(port: port, pid: pid, cmd: cmd))
            }
        default: break
        }
    }
    return rows
}

func runningAgents() -> [(pid: Int32, name: String, host: String)] {
    var procs = [Int32: (ppid: Int32, exe: String)](), args = [Int32: String]()
    for line in run("/bin/ps", ["-axo", "pid=,ppid=,comm="]).split(separator: "\n") {
        let f = fields(line, 3)
        if let pid = Int32(f[0]), let ppid = Int32(f[1]) { procs[pid] = (ppid, f[2]) }
    }
    for line in run("/bin/ps", ["-axo", "pid=,args="]).split(separator: "\n") {
        let f = fields(line, 2)
        if let pid = Int32(f[0]) { args[pid] = f[1] }
    }
    // node/bun/python CLIs: the agent name is the script, e.g. `node /opt/homebrew/bin/gemini`
    func name(_ pid: Int32) -> String? {
        guard let exe = procs[pid]?.exe else { return nil }
        let b = base(exe)
        guard interpreters.contains(b) else { return b }
        return args[pid]?.split(separator: " ").dropFirst().first { !$0.hasPrefix("-") }.map(base)
    }
    return procs.compactMap { pid, p in
        guard let n = name(pid), agentNames[n] != nil, name(p.ppid) != n else { return nil } // skip same-agent children
        let host = p.exe.contains("/.vscode/") ? "VS Code" : p.exe.contains("/.cursor/") ? "Cursor"
            : p.exe.contains("Application Support/Claude/") ? "Desktop" : "terminal"
        return (pid, n, host)
    }
}

func installedAI() -> [String] {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    // -i so PATH from .zshrc applies; output filtered since rc files may print noise
    let out = run(shell, ["-ilc", "for c in \(cliNames.joined(separator: " ")); do command -v $c >/dev/null && echo $c; done"])
    let clis = out.split(separator: "\n").map(String.init).filter(cliNames.contains)
    let apps = appNames.filter { n in ["/Applications", NSHomeDirectory() + "/Applications"].contains { FileManager.default.fileExists(atPath: "\($0)/\(n).app") } }
    return clis + apps.map { $0 + ".app" }
}

func snapshot() -> Snapshot {
    let ls = listeningPorts(), ag = runningAgents()
    let dirs = cwds(Array(Set(ls.map(\.pid) + ag.map(\.pid))))
    var s = Snapshot()
    s.agents = ag.map { Agent(pid: $0.pid, name: $0.name, host: $0.host, project: dirs[$0.pid].flatMap(projectRoot)) }

    var projects = [String: Group](), services = [String: Group](), other = [String: Group]()
    for l in ls {
        if let root = dirs[l.pid].flatMap(projectRoot) { projects[root, default: Group(id: root, title: base(root), path: root)].ports.append(l) }
        else if let name = serviceNames[l.cmd] { services[name, default: Group(id: name, title: name)].ports.append(l) }
        else { other[l.cmd, default: Group(id: l.cmd, title: l.cmd)].ports.append(l) }
    }
    for a in s.agents { if let root = a.project { projects[root, default: Group(id: root, title: base(root), path: root)].agents.append(a) } }

    func sorted(_ d: [String: Group]) -> [Group] {
        d.values.map { var g = $0; g.ports.sort { $0.port < $1.port }; return g }
            .sorted { ($0.ports.first?.port ?? .max, $0.title) < ($1.ports.first?.port ?? .max, $1.title) }
    }
    s.projects = sorted(projects)
    s.services = services.values.map { var g = $0; g.ports.sort { $0.port < $1.port }; return g }.sorted { $0.title < $1.title }
    s.other = sorted(other)

    if let port = ls.first(where: { $0.cmd == "ollama" })?.port,
       let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/api/ps")!),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        s.ollamaModels = (json["models"] as? [Any])?.count
    }
    return s
}

