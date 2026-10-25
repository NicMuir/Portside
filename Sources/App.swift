import SwiftUI
import AppKit
import ServiceManagement

@MainActor final class Store: ObservableObject {
    @Published var snap = Snapshot()
    @Published var installed: [String] = []
    private var timer: Timer?

    init(live: Bool = true) {
        guard live else { return }
        refresh()
        Task.detached { let i = installedAI(); await MainActor.run { self.installed = i } } // ponytail: once at launch; installs are rare
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in self.refresh() } }
    }

    func refresh() {
        Task.detached { let s = snapshot(); await MainActor.run { self.snap = s } }
    }
}

// MARK: - Actions

func openPort(_ port: Int) { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) }
func copyURL(_ port: Int) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("http://localhost:\(port)", forType: .string) }
func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

// MARK: - UI

struct Chip: View {
    let text: String
    var color = Color.accentColor
    var body: some View {
        Text(verbatim: text).font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
}

struct GroupRow: View {
    let group: Group
    let refresh: @MainActor () -> Void
    @State private var hover = false
    @State private var confirmKill = false
    private var pids: [Int32] { Array(Set(group.ports.map(\.pid))) }

    var body: some View {
        HStack(spacing: 5) {
            Text(group.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            ForEach(group.ports.prefix(hover ? 2 : 3), id: \.self) { l in
                Chip(text: "\(l.port)")
                    .onTapGesture { openPort(l.port) }
                    .contextMenu {
                        Button("Open in browser") { openPort(l.port) }
                        Button("Copy URL") { copyURL(l.port) }
                        Divider()
                        Button("Kill \(l.cmd) (pid \(l.pid))") { kill(l.pid, SIGTERM); refreshSoon() }
                    }
                    .help("http://localhost:\(l.port) · \(l.cmd) pid \(l.pid)")
            }
            if group.ports.count > (hover ? 2 : 3) {
                Menu {
                    ForEach(group.ports.dropFirst(hover ? 2 : 3), id: \.self) { l in Button("Open :\(l.port)  (\(l.cmd))") { openPort(l.port) } }
                } label: { Chip(text: "+\(group.ports.count - (hover ? 2 : 3))") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if !group.agents.isEmpty && !hover {
                Chip(text: Dictionary(grouping: group.agents, by: \.name).sorted { $0.key < $1.key }
                    .map { $1.count > 1 ? "\($0) ×\($1.count)" : $0 }.joined(separator: " "), color: .purple)
            }
            if hover { actions }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0; if !$0 { confirmKill = false } }
    }

    @ViewBuilder var actions: some View {
        if let first = group.ports.first {
            icon("doc.on.doc", "Copy http://localhost:\(first.port)") { copyURL(first.port) }
        }
        if let path = group.path { icon("folder", "Reveal \(path)") { reveal(path) } }
        if !pids.isEmpty {
            if confirmKill {
                Button("Kill \(pids.count == 1 ? "it" : "\(pids.count)")?") { pids.forEach { kill($0, SIGTERM) }; refreshSoon() }
                    .buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 12, weight: .medium))
            } else {
                icon("xmark.circle", "Stop \(Set(group.ports.map(\.cmd)).joined(separator: ", ")) (SIGTERM)") { confirmKill = true }
            }
        }
    }

    func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name) }.buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }

    func refreshSoon() {
        confirmKill = false
        Task { try? await Task.sleep(for: .milliseconds(600)); refresh() }
    }
}

struct Sections: View {
    let snap: Snapshot
    let installed: [String]
    let refresh: @MainActor () -> Void
    @State private var showOther = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Projects", "click a port to open")
            if snap.projects.isEmpty { Text("No dev servers or agents in your projects").foregroundStyle(.secondary).padding(.horizontal, 16) }
            ForEach(snap.projects) { GroupRow(group: $0, refresh: refresh) }

            if !snap.services.isEmpty {
                Divider().padding(.vertical, 6)
                header("Services", "\(snap.services.count)")
                ForEach(snap.services) { GroupRow(group: $0, refresh: refresh) }
            }
            if !snap.other.isEmpty {
                Button { showOther.toggle() } label: {
                    HStack {
                        Image(systemName: showOther ? "chevron.down" : "chevron.right").frame(width: 10)
                        Text("Apps and system ports")
                        Spacer()
                        Text("\(snap.other.count)").foregroundStyle(.tertiary)
                    }.foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 4)
                if showOther { ForEach(snap.other) { GroupRow(group: $0, refresh: refresh) } }
            }

            Divider().padding(.vertical, 6)
            header("AI", "running")
            let running = Dictionary(grouping: snap.agents, by: \.name).sorted { $0.value.count > $1.value.count }
            ForEach(running, id: \.key) { name, list in
                aiRow(agentNames[name] ?? name, Set(list.map(\.host)).sorted().joined(separator: ", "), "\(list.count) running")
            }
            if let n = snap.ollamaModels { aiRow("Ollama", n == 0 ? "no models loaded" : n == 1 ? "1 model loaded" : "\(n) models loaded", "serving") }
            if running.isEmpty && snap.ollamaModels == nil { Text("No agents running").foregroundStyle(.secondary).padding(.horizontal, 16) }
            let idle = installed.filter { !running.map(\.key).contains($0) && !($0 == "ollama" && snap.ollamaModels != nil) }
            if !idle.isEmpty {
                Text("Installed: " + idle.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 4)
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 6)
    }

    func header(_ title: String, _ trailing: String) -> some View {
        HStack { Text(title); Spacer(); Text(trailing) }
            .font(.system(size: 11)).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 2)
    }

    func aiRow(_ name: String, _ detail: String, _ badge: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Chip(text: badge, color: .purple)
        }.padding(.horizontal, 16).padding(.vertical, 3)
    }
}

struct Header: View {
    let snap: Snapshot
    let refresh: @MainActor () -> Void
    var body: some View {
        let ports = snap.projects.reduce(0) { $0 + $1.ports.count }
        HStack {
            Text("\(ports) dev \(ports == 1 ? "port" : "ports") · \(snap.agents.count) \(snap.agents.count == 1 ? "agent" : "agents")")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh")
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    @State private var contentHeight: CGFloat = 300
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Header(snap: store.snap, refresh: store.refresh)
            Divider()
            ScrollView {
                Sections(snap: store.snap, installed: store.installed, refresh: store.refresh)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 600))
            Divider()
            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear { store.refresh() }
    }
}

/// Template image so the icon and count both render (MenuBarExtra drops images embedded in Text)
/// and adapt to light/dark menu bars.
@MainActor func menuBarImage(_ agents: Int) -> NSImage {
    let r = ImageRenderer(content: HStack(spacing: 3) {
        Image(systemName: "network")
        Text(verbatim: "\(agents)").monospacedDigit()
    }.font(.system(size: 13, weight: .medium)))
    r.scale = 2
    let img = r.nsImage ?? NSImage()
    img.isTemplate = true
    return img
}

struct AppIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.19, blue: 0.26), Color(red: 0.06, green: 0.07, blue: 0.10)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: "network").font(.system(size: 470, weight: .medium))
                .foregroundStyle(Color(red: 0.42, green: 0.74, blue: 1.0)))
            .frame(width: 824, height: 824)
            .frame(width: 1024, height: 1024)
    }
}

@MainActor func writePNG(_ view: some View, scale: CGFloat, to path: String) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    let png = r.nsImage.flatMap { NSBitmapImageRep(data: $0.tiffRepresentation!)?.representation(using: .png, properties: [:]) }
    try! png!.write(to: URL(fileURLWithPath: path))
}

/// The panel hanging under a fake menu bar, for the README.
struct Showcase<Panel: View>: View {
    let panel: Panel
    let agents: Int
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 16) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(nsImage: menuBarImage(agents)).renderingMode(.template)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                Text("Fri 9:41")
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 18).frame(maxWidth: .infinity, alignment: .trailing).frame(height: 30)
            .background(.black.opacity(0.28))
            panel
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .padding(.trailing, 44)
        }
        .padding(.bottom, 56)
        .frame(width: 580)
        .background(LinearGradient(colors: [Color(red: 0.20, green: 0.32, blue: 0.62), Color(red: 0.52, green: 0.34, blue: 0.66)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

extension Snapshot {
    /// Made-up projects so screenshots don't leak anyone's real ones.
    static var demo: Snapshot {
        var pid: Int32 = 1000
        func agent(_ name: String, _ host: String, _ project: String?) -> Agent {
            pid += 1
            return Agent(pid: pid, name: name, host: host, project: project)
        }
        func group(_ title: String, _ ports: [Int], cmd: String = "node", agents: [Agent] = [], project: Bool = true) -> Group {
            pid += 1
            return Group(id: title, title: title, path: project ? "/Users/you/code/\(title)" : nil,
                         ports: ports.map { Listener(port: $0, pid: pid, cmd: cmd) }, agents: agents)
        }
        let agents = [agent("claude", "Desktop", "acme-web"), agent("claude", "terminal", "acme-api"), agent("codex", "VS Code", "acme-api"),
                      agent("claude", "Desktop", "infra"), agent("claude", "Desktop", "infra"), agent("gemini", "terminal", "docs-site")]
        func of(_ p: String) -> [Agent] { agents.filter { $0.project == p } }
        var s = Snapshot()
        s.agents = agents
        s.projects = [group("acme-web", [3000], agents: of("acme-web")), group("docs-site", [4321], agents: of("docs-site")),
                      group("design-system", [6006]), group("acme-api", [8080, 8081, 9229], agents: of("acme-api")),
                      group("mobile-app", [19000, 19001]), group("infra", [], agents: of("infra"))]
        s.services = [group("Mailpit", [1025, 8025], cmd: "mailpit", project: false), group("Ollama", [11434], cmd: "ollama", project: false),
                      group("Postgres", [5432], cmd: "postgres", project: false), group("Redis", [6379], cmd: "redis-server", project: false)]
        s.other = [group("ControlCenter", [5000, 7000], cmd: "ControlCenter", project: false),
                   group("rapportd", [49152], cmd: "rapportd", project: false), group("Spotify", [57621], cmd: "Spotify", project: false)]
        s.ollamaModels = 1
        return s
    }
}

struct PortsideApp: App {
    @StateObject var store = Store()

    var body: some Scene {
        MenuBarExtra {
            Panel(store: store)
        } label: {
            Image(nsImage: menuBarImage(store.snap.agents.count))
                .accessibilityLabel("Portside, \(store.snap.agents.count) agents running")
        }
        .menuBarExtraStyle(.window)
    }
}

@main enum Main {
    static func main() {
        let args = CommandLine.arguments
        func arg(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

        // `--dump` prints the data, `--render <png>` draws the panel: both double as smoke checks.
        // `--iconset <dir>` writes the app icon PNGs for build.sh.
        if args.contains("--dump") {
            assert(fields(" 12  3 /a b/c", 3) == ["12", "3", "/a b/c"])
            assert(projectRoot("/") == nil && projectRoot("/opt/homebrew") == nil)
            let s = snapshot()
            for (label, groups) in [("project", s.projects), ("service", s.services), ("other", s.other)] {
                for g in groups { print(label, g.title, g.ports.map { ":\($0.port)" }.joined(separator: " "), g.agents.map(\.name).joined(separator: ",")) }
            }
            s.agents.forEach { print("agent", $0.name, $0.host, $0.project.map(base) ?? "—") }
            print("ollama models", s.ollamaModels.map(String.init) ?? "—")
            print("installed", installedAI().joined(separator: ", "))
        } else if let out = arg("--render") {
            // `--demo` swaps in sample data and frames it under a fake menu bar: the README screenshot.
            MainActor.assumeIsolated {
                let demo = args.contains("--demo")
                let s = demo ? Snapshot.demo : snapshot()
                let panel = VStack(spacing: 0) {
                    Header(snap: s, refresh: {})
                    Divider()
                    Sections(snap: s, installed: demo ? ["opencode", "ChatGPT.app", "Cursor.app"] : installedAI(), refresh: {})
                }.frame(width: 380).background(Color(nsColor: .windowBackgroundColor))
                if demo { writePNG(Showcase(panel: panel, agents: s.agents.count), scale: 2, to: out) }
                else { writePNG(panel, scale: 2, to: out) }
                let bar = menuBarImage(s.agents.count)
                assert(bar.size.width > 20, "menu bar image lost its icon")
                writePNG(Image(nsImage: bar).padding(4).background(.white), scale: 2, to: out.replacingOccurrences(of: ".png", with: "-menubar.png"))
            }
        } else if let dir = arg("--iconset") {
            MainActor.assumeIsolated {
                for pt in [16, 32, 128, 256, 512] {
                    writePNG(AppIcon(), scale: CGFloat(pt) / 1024, to: "\(dir)/icon_\(pt)x\(pt).png")
                    writePNG(AppIcon(), scale: CGFloat(pt * 2) / 1024, to: "\(dir)/icon_\(pt)x\(pt)@2x.png")
                }
            }
        } else {
            PortsideApp.main()
        }
    }
}
