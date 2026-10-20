// Mochi's panel: what opens from the menu bar or a right-click on Mochi. A dark card in the style of AI Usage's popover,
// split into tabs so nothing is a wall of menu items: Claude (usage, sessions), Today (your stats, quick logging),
// Play (things Mochi can do, costumes) and Settings.
import AppKit
import CoreText
import SwiftUI

// MARK: - Look

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

enum PanelTheme {
    static let bg = Color(hex: 0x0F0F0F)
    static let surface = Color(hex: 0x181818)
    static let border = Color(hex: 0x242424)
    static let dim = Color(hex: 0x2A2A2A)
    static let text = Color(hex: 0xE6E6E6)
    static let muted = Color(hex: 0x6A6A6A)
    static let mochi = Color(hex: 0xE5714B)
    static let claude = Color(hex: 0xCC785C)
    static let yellow = Color(hex: 0xD4A843)
    static let red = Color(hex: 0xC95C5C)
    static let green = Color(hex: 0x4DB876)
    static let radius: CGFloat = 12

    /// Usage colour: Claude's own until you're getting close, then a warning that reads the same everywhere.
    static func tier(_ pct: Double) -> Color { pct >= 90 ? red : pct >= 70 ? yellow : claude }

    /// Jersey 15, the pixel font Mochi's speech bubble uses, for the panel's title.
    static let pixelFontLoaded: Bool = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("web/fonts/Jersey15.ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: "Jersey15-Regular", size: 12) != nil
    }()
    static func pixel(_ size: CGFloat) -> Font {
        guard pixelFontLoaded, let f = NSFont(name: "Jersey15-Regular", size: size) else { return .system(size: size * 0.8, weight: .semibold) }
        return Font(f as CTFont)
    }
}

// MARK: - What the panel shows, and what it can ask for

struct PanelSession: Identifiable {
    let id: String
    let project: String
    let line: String
    let needsYou: Bool
    let busy: Bool
}

struct PanelState {
    var mood = "chilling"
    var stats: [String: Any] = [:]
    var visible = true
    var quiet = false
    var roam = true
    var appAware = true
    var emoji = false
    var login = false
    var scale: Double = 3
    var bar = "usage"
    var follow = true
    var narrate = true
    var connected = false
    var listening = true
    var five: UsageWindow?
    var week: UsageWindow?
    var usageAt: Date?
    var sessions: [PanelSession] = []
}

enum PanelAction {
    case pet(String), size(Double), roam, appAware, emoji, quiet, login, corner, visible
    case connect, follow, narrate, bar(String), focus(String), quit, close
}

final class PanelModel: ObservableObject {
    @Published var s = PanelState()
    @Published var tab = UserDefaults.standard.string(forKey: "panelTab") ?? "claude" {
        didSet { UserDefaults.standard.set(tab, forKey: "panelTab"); resized() }
    }
    var act: (PanelAction) -> Void = { _ in }
    var resized: () -> Void = {}
}

// MARK: - The panel

struct PanelView: View {
    @ObservedObject var model: PanelModel
    private var s: PanelState { model.s }

    static let tabs: [(id: String, icon: String, title: String)] = [
        ("claude", "sparkle", "Claude"), ("today", "sun.max", "Today"), ("play", "pawprint", "Play"), ("settings", "gearshape", "Settings"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(PanelTheme.border)
            tabBar
            Divider().overlay(PanelTheme.border)
            Group {
                switch model.tab {
                case "today": TodayTab(model: model)
                case "play": PlayTab(model: model)
                case "settings": SettingsTab(model: model)
                default: ClaudeTab(model: model)
                }
            }
            .padding(.horizontal, 13)
            .padding(.bottom, 13)
        }
        .frame(width: 320)
        .background(PanelTheme.bg)
        .foregroundStyle(PanelTheme.text)
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: PanelTheme.radius).strokeBorder(PanelTheme.border, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 9) {
            MochiGlyph().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("Mochi").font(PanelTheme.pixel(20)).foregroundStyle(PanelTheme.text)
                Text("is \(s.mood)").font(.system(size: 10)).foregroundStyle(PanelTheme.muted).lineLimit(1)
            }
            Spacer()
            IconButton(systemName: s.visible ? "eye" : "eye.slash") { model.act(.visible) }
                .help(s.visible ? "Hide Mochi" : "Show Mochi")
            IconButton(systemName: "xmark") { model.act(.close) }.help("Close")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.tabs, id: \.id) { t in
                Button { model.tab = t.id } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 10, weight: .semibold))
                        Text(t.title).font(.system(size: 11, weight: .medium))
                        if t.id == "claude", let dot = claudeDot { Circle().fill(dot).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(model.tab == t.id ? PanelTheme.text : PanelTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.tab == t.id ? PanelTheme.surface : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.tab == t.id ? PanelTheme.border : .clear, lineWidth: 1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    /// A dot on the Claude tab: red when a session needs you, orange while one is working.
    private var claudeDot: Color? {
        if s.sessions.contains(where: \.needsYou) { return PanelTheme.red }
        if s.sessions.contains(where: \.busy) { return PanelTheme.claude }
        return nil
    }
}

// MARK: - Claude

struct ClaudeTab: View {
    @ObservedObject var model: PanelModel
    private var s: PanelState { model.s }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !s.connected && s.five == nil {
                EmptyState(title: "Mochi isn't connected to Claude Code yet.",
                           hint: "Connect it and Mochi acts out what Claude is doing, and your usage shows up here.",
                           action: ("Connect Claude Code", { model.act(.connect) }))
            } else {
                if s.five != nil || s.week != nil {
                    VStack(alignment: .leading, spacing: 13) {
                        if let w = s.five { UsageGauge(label: "5-hour", window: w) }
                        if let w = s.week { UsageGauge(label: "Weekly", window: w) }
                    }
                    .padding(.top, 13)
                    if let at = s.usageAt {
                        Text("updated \(RelativeDateTimeFormatter().localizedString(for: at, relativeTo: Date()))")
                            .font(.system(size: 10)).foregroundStyle(PanelTheme.muted).padding(.top, 9)
                    }
                } else {
                    Text("Your usage shows up here after your next Claude Code message.")
                        .font(.system(size: 11)).foregroundStyle(PanelTheme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 13)
                }
                PanelSection(title: "Sessions") {
                    if s.sessions.isEmpty {
                        Text(s.connected ? "No Claude Code sessions right now." : "Reconnect Claude Code to follow your sessions.")
                            .font(.system(size: 11)).foregroundStyle(PanelTheme.muted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(s.sessions) { session in
                                Button { model.act(.focus(session.id)) } label: { SessionRow(session: session) }
                                    .buttonStyle(.plain)
                                    .help("Switch to it")
                                if session.id != s.sessions.last?.id { Rectangle().fill(PanelTheme.border).frame(height: 1) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: PanelSession
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.needsYou ? PanelTheme.red : session.busy ? PanelTheme.claude : PanelTheme.dim).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(session.line).font(.system(size: 10.5))
                    .foregroundStyle(session.needsYou ? PanelTheme.red : PanelTheme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward.app").font(.system(size: 10)).foregroundStyle(PanelTheme.muted).opacity(hover ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover ? PanelTheme.surface : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// One usage window: big number, thin bar, when it resets.
struct UsageGauge: View {
    let label: String
    let window: UsageWindow

    var body: some View {
        let pct = min(max(window.pct, 0), 100)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Caption(label)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(pct.rounded()))").font(.system(size: 30, weight: .bold)).tracking(-1.5).monospacedDigit()
                    Text("%").font(.system(size: 14, weight: .medium)).opacity(0.55)
                }
                .foregroundStyle(PanelTheme.tier(pct))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PanelTheme.dim)
                    Capsule().fill(PanelTheme.tier(pct)).frame(width: geo.size.width * pct / 100)
                }
            }
            .frame(height: 3)
            if let r = window.resets {
                Text("Resets \(UsageBadge.when(r))").font(.system(size: 10)).foregroundStyle(PanelTheme.muted)
            }
        }
    }
}

// MARK: - Today

struct TodayTab: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let st = model.s.stats
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Today") {
                ChipGrid(chips: [
                    ("At the computer", "\(st["active"] ?? "–")"), ("Sitting for", "\(st["sitting"] ?? "–")"),
                    ("Water", "\(st["water"] ?? 0)"), ("Coffee", "\(st["coffee"] ?? 0)"),
                    ("Energy drinks", "\(st["energy"] ?? 0)"), ("Breaks", "\(st["breaks"] ?? 0)"),
                ])
            }
            PanelSection(title: "Log it") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    Tile(icon: "drop", title: "Drank water") { model.act(.pet("water")) }
                    Tile(icon: "cup.and.saucer", title: "Got coffee") { model.act(.pet("coffee")) }
                    Tile(icon: "bolt", title: "Energy drink") { model.act(.pet("energy")) }
                    Tile(icon: "figure.walk", title: "Going for a walk") { model.act(.pet("walk")) }
                }
            }
        }
    }
}

// MARK: - Play

struct PlayTab: View {
    @ObservedObject var model: PanelModel
    static let costumes: [(String, String)] = [("Wizard", "wizard"), ("Detective", "detective"), ("Chef", "chef"), ("Headphones", "focus"),
                                               ("Sunglasses", "shades"), ("TV head", "tv"), ("Party", "party")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Mochi, please…") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    Tile(icon: "hands.clap", title: "Cheer me on") { model.act(.pet("cheer")) }
                    Tile(icon: "chart.bar", title: "How am I doing?") { model.act(.pet("stats")) }
                    Tile(icon: "soccerball", title: "Play ball") { model.act(.pet("ball")) }
                    Tile(icon: "leaf", title: "Water the plant") { model.act(.pet("plant")) }
                    Tile(icon: "macwindow", title: "Sit on my window") { model.act(.pet("perch")) }
                    Tile(icon: "map", title: "Go explore") { model.act(.pet("explore")) }
                }
            }
            PanelSection(title: "Dress up") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(Self.costumes, id: \.1) { title, id in
                        Button(title) { model.act(.pet("wear:" + id)) }.buttonStyle(ChipButtonStyle())
                    }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject var model: PanelModel
    private var s: PanelState { model.s }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Mochi") {
                VStack(spacing: 2) {
                    Row("Size") {
                        Segmented(options: [("Tiny", 2), ("Small", 3), ("Medium", 4), ("Large", 6)].map { ($0.0, "\($0.1)") }, selected: "\(Int(s.scale))") {
                            model.act(.size(Double($0) ?? 3))
                        }
                    }
                    ToggleRow("Roam around", on: s.roam) { model.act(.roam) }
                    ToggleRow("React to apps & calls", on: s.appAware) { model.act(.appAware) }
                    ToggleRow("Quiet for an hour", on: s.quiet) { model.act(.quiet) }
                    ToggleRow("Open at login", on: s.login) { model.act(.login) }
                    Row("Lost Mochi?") { Button("Move to corner") { model.act(.corner) }.buttonStyle(PillButtonStyle()) }
                }
            }
            PanelSection(title: "Claude Code") {
                VStack(spacing: 2) {
                    Row(s.connected ? "Connected" : s.listening ? "Not connected" : "Can't listen on port \(ClaudeCode.port)", dot: s.connected ? PanelTheme.green : PanelTheme.dim) {
                        Button(s.connected ? "Disconnect" : "Connect") { model.act(.connect) }.buttonStyle(PillButtonStyle())
                    }
                    ToggleRow("Act out what Claude is doing", on: s.follow) { model.act(.follow) }
                    ToggleRow("Say what Claude is doing", on: s.narrate) { model.act(.narrate) }
                }
            }
            PanelSection(title: "Look") {
                VStack(spacing: 2) {
                    Row("Menu bar") {
                        Segmented(options: [("Usage", "usage"), ("Icon", "icon"), ("Hidden", "hidden")], selected: s.bar) { model.act(.bar($0)) }
                    }
                    ToggleRow("Use emoji", on: s.emoji) { model.act(.emoji) }
                }
            }
            HStack {
                Spacer()
                Button("Quit Mochi") { model.act(.quit) }.buttonStyle(PillButtonStyle(tint: PanelTheme.red))
            }
            .padding(.top, 14)
        }
    }
}

// MARK: - Pieces

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.9).foregroundStyle(PanelTheme.muted)
    }
}

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var dot: Color?
    @ViewBuilder let trailing: Trailing
    init(_ title: String, dot: Color? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.dot = dot
        self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 7) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 26)
    }
}

struct ToggleRow: View {
    let title: String
    let on: Bool
    let flip: () -> Void
    init(_ title: String, on: Bool, flip: @escaping () -> Void) {
        self.title = title
        self.on = on
        self.flip = flip
    }
    var body: some View {
        Button(action: flip) {
            Row(title) { Switch(on: on) }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Switch: View {
    let on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? PanelTheme.mochi : PanelTheme.dim).frame(width: 28, height: 16)
            Circle().fill(on ? Color.white : PanelTheme.muted).frame(width: 12, height: 12).padding(2)
        }
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

struct Segmented: View {
    let options: [(String, String)]
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { title, value in
                Button { pick(value) } label: {
                    Text(title).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected == value ? PanelTheme.text : PanelTheme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected == value ? PanelTheme.dim : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(PanelTheme.surface).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PanelTheme.border, lineWidth: 1)))
    }
}

/// A square-ish button with an icon over a label.
struct Tile: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(PanelTheme.mochi).frame(width: 16)
                Text(title).font(.system(size: 11.5)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? PanelTheme.dim : PanelTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PanelTheme.border, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ChipGrid: View {
    let chips: [(String, String)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(chips, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased()).font(.system(size: 9)).tracking(0.5).foregroundStyle(PanelTheme.muted).lineLimit(1)
                    Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(PanelTheme.surface).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PanelTheme.border, lineWidth: 1)))
            }
        }
    }
}

struct EmptyState: View {
    let title: String
    var hint: String?
    var action: (String, () -> Void)?
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 12)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(PanelTheme.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.0, action: action.1).buttonStyle(PillButtonStyle(tint: PanelTheme.mochi)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 22)
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 11, weight: .medium)).foregroundStyle(PanelTheme.muted)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(PanelTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PillButtonStyle: ButtonStyle {
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint == PanelTheme.mochi ? Color.white : tint ?? PanelTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint == PanelTheme.mochi ? PanelTheme.mochi.opacity(configuration.isPressed ? 0.8 : 1) : configuration.isPressed ? PanelTheme.dim : PanelTheme.surface)
                .overlay(Capsule().strokeBorder(tint == PanelTheme.mochi ? .clear : PanelTheme.border, lineWidth: 1)))
            .contentShape(Capsule())
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? PanelTheme.dim : PanelTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PanelTheme.border, lineWidth: 1)))
            .contentShape(Rectangle())
    }
}

/// Mochi in pixels, for the panel's header.
struct MochiGlyph: View {
    static let rows = ["..........", ".########.", "##########", "##e####e##", "##e####e##", "##########", "##########", ".########.", ".#.#..#.#.", ".#.#..#.#."]
    var body: some View {
        Canvas { ctx, size in
            let px = min(size.width, size.height) / 10
            for (y, row) in Self.rows.enumerated() {
                for (x, c) in row.enumerated() where c != "." {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px)), with: .color(c == "e" ? Color(hex: 0x1F1A1C) : PanelTheme.mochi))
                }
            }
        }
    }
}

// MARK: - The window it lives in

/// A borderless floating panel, not an NSPopover or NSMenu: no system chrome, no arrow, just the card.
final class PanelController {
    let model = PanelModel()
    private var window: NSPanel?
    private var host: NSHostingView<PanelView>?
    private var monitors: [Any] = []
    private var timer: Timer?
    var refresh: () -> PanelState = { PanelState() }
    var isOpen: Bool { window?.isVisible == true }

    /// Opens hanging under the menu bar icon, or next to a point (where you right-clicked Mochi).
    func show(under button: NSStatusBarButton? = nil, at point: NSPoint? = nil) {
        close()
        model.s = refresh()
        let host = NSHostingView(rootView: PanelView(model: model))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.animationBehavior = .utilityWindow
        w.setFrameOrigin(origin(size, button, point))
        w.orderFrontRegardless()
        window = w
        self.host = host
        model.resized = { [weak self] in self?.fit() }

        // nothing closes a borderless panel by itself: a click anywhere else does
        let outside: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.window !== self.window else { return }
            if let b = button, e.window === b.window { return }   // the menu bar icon toggles it itself
            self.close()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { outside($0); return $0 }) { monitors.append(m) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
    }

    /// New numbers, and maybe a new height.
    func update() {
        guard window != nil else { return }
        model.s = refresh()
        fit()
    }

    /// Grows or shrinks to fit what's showing, keeping the top edge where it is.
    func fit() {
        DispatchQueue.main.async { [weak self] in
            guard let w = self?.window, let host = self?.host else { return }
            let size = host.fittingSize
            guard abs(size.height - w.frame.height) > 0.5 else { return }
            w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        host = nil
    }

    private func origin(_ size: NSSize, _ button: NSStatusBarButton?, _ point: NSPoint?) -> NSPoint {
        var p: NSPoint
        var screen = NSScreen.main
        if let button, let bw = button.window {
            let r = bw.convertToScreen(button.convert(button.bounds, to: nil))
            p = NSPoint(x: r.midX - size.width / 2, y: r.minY - 6 - size.height)
            screen = bw.screen ?? screen
        } else {
            let at = point ?? NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(at) } ?? screen
            p = NSPoint(x: at.x + 8, y: at.y - size.height + 20)
        }
        if let v = screen?.visibleFrame {
            p.x = min(max(p.x, v.minX + 8), v.maxX - size.width - 8)
            p.y = min(max(p.y, v.minY + 8), v.maxY - size.height - 4)
        }
        return p
    }
}
