import AppKit
import SwiftUI

/// Windows 11 25H2 Start: search box, Pinned (expandable), Recommended, All (Category / Grid / List),
/// and the account + folders + power bar at the bottom. Typing anywhere searches.
struct StartView: View {
    @ObservedObject private var model = StartModel.shared
    @ObservedObject private var ctl = StartController.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
            if model.query.isEmpty {
                StartHome()
            } else {
                StartSearchResults()
            }
            StartBottomBar()
        }
        .background(Theme.flyoutTint(scheme))
        .background(VisualEffect(material: .hudWindow, cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border(scheme), lineWidth: 1))
        .foregroundStyle(Theme.text(scheme))
        .font(Theme.font(12))
        .onChange(of: ctl.focusToken) { _, _ in searchFocused = true }
        .onKeyPress(.escape) {
            if !model.query.isEmpty { model.query = "" } else { StartController.shared.hide() }
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.secondaryText(scheme))
            TextField("Search for apps, settings, and documents", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.font(14))
                .focused($searchFocused)
                .onSubmit { if let s = model.selection { model.open(s) } }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(Theme.control(scheme)))
        .overlay(Capsule().strokeBorder(searchFocused ? Theme.accent : Theme.border(scheme), lineWidth: searchFocused ? 1.5 : 1))
    }
}

// MARK: Home (no query)

struct StartHome: View {
    @ObservedObject private var model = StartModel.shared
    @ObservedObject private var ctl = StartController.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme
    @State private var pinnedExpanded = false
    @State private var openCategory: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 0).id("top")
                    pinnedSection
                    if settings.startShowRecommended && !recommended.isEmpty { recommendedSection }
                    allSection
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
            .onChange(of: ctl.resetToken) { _, _ in
                pinnedExpanded = false
                openCategory = nil
                proxy.scrollTo("top", anchor: .top)
            }
        }
    }

    // Pinned: 8 columns, 2 rows until "Show all".
    private var pinned: [StartModel.AppEntry] { settings.startPinned.compactMap(model.app) }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Pinned", button: pinned.count > 16 ? (pinnedExpanded ? "Show less" : "Show all") : nil) {
                withAnimation(.easeOut(duration: 0.2)) { pinnedExpanded.toggle() }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 3), count: 8), spacing: 6) {
                ForEach(pinnedExpanded ? pinned : Array(pinned.prefix(16))) { app in
                    StartTile(app: app, pinnedContext: true)
                }
            }
            if pinned.isEmpty {
                Text("Right-click an app in All and choose Pin to Start.")
                    .foregroundStyle(Theme.secondaryText(scheme))
            }
        }
    }

    // Recommended: recently added apps + recent files, two columns.
    private enum Rec: Identifiable {
        case app(StartModel.AppEntry), file(StartModel.FileEntry)
        var id: String { switch self { case .app(let a): return "a" + a.id; case .file(let f): return f.id } }
    }
    private var recommended: [Rec] {
        var out: [Rec] = []
        if settings.startShowRecentlyAdded { out += model.recentlyAdded.map(Rec.app) }
        if settings.startShowRecommendedFiles { out += model.recentFiles.map(Rec.file) }
        return Array(out.prefix(6))
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Recommended", button: nil) {}
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 4) {
                ForEach(recommended) { r in
                    switch r {
                    case .app(let a):
                        RecommendedRow(icon: model.icon(a), title: a.name, subtitle: "Recently added") { model.launch(a); ctl.hide() }
                    case .file(let f):
                        RecommendedRow(icon: model.icon(file: f.url), title: f.name,
                                       subtitle: f.date.formatted(.relative(presentation: .named))) {
                            ctl.hide(); NSWorkspace.shared.open(f.url)
                        }
                        .contextMenu {
                            Button("Open file location") { model.reveal(f.url) }
                        }
                    }
                }
            }
        }
    }

    // All: Category / Grid / List (25H2).
    private var allSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("All").font(Theme.font(14, .semibold))
                Spacer()
                Menu {
                    Picker("View", selection: $settings.startAllView) {
                        ForEach(StartAllView.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("View: \(settings.startAllView.label)").font(Theme.font(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            switch settings.startAllView {
            case .category: categoryView
            case .grid:
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 3), count: 8), spacing: 6) {
                    ForEach(model.apps) { StartTile(app: $0, pinnedContext: false) }
                }
            case .list: listView
            }
        }
    }

    private var categoryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = openCategory, let group = model.categories.first(where: { $0.name == name }) {
                Button { withAnimation(.easeOut(duration: 0.15)) { openCategory = nil } } label: {
                    Label(name, systemImage: "chevron.left").font(Theme.font(13, .semibold))
                }
                .buttonStyle(.plain)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 3), count: 8), spacing: 6) {
                    ForEach(group.apps) { StartTile(app: $0, pinnedContext: false) }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(model.categories, id: \.name) { group in
                        CategoryTile(name: group.name, apps: group.apps) {
                            withAnimation(.easeOut(duration: 0.15)) { openCategory = group.name }
                        }
                    }
                }
            }
        }
    }

    private var listView: some View {
        let groups = Dictionary(grouping: model.apps) { a -> String in
            let c = a.name.prefix(1).uppercased()
            return c.rangeOfCharacter(from: .letters) != nil ? c : "#"
        }
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(groups.keys.sorted(), id: \.self) { letter in
                Text(letter).font(Theme.font(13, .semibold)).padding(.top, 8).padding(.leading, 8)
                ForEach(groups[letter]!) { app in
                    ListAppRow(app: app)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(Theme.font(14, .semibold))
            Spacer()
            if let button {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(button)
                        Image(systemName: pinnedExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }
                    .font(Theme.font(12))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.control(scheme)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// App icon + name; right-click offers the Windows options.
struct StartTile: View {
    let app: StartModel.AppEntry
    let pinnedContext: Bool
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: StartModel.shared.icon(app)).resizable().interpolation(.high).frame(width: 32, height: 32)
            Text(app.name).font(Theme.font(11)).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
        }
        .frame(width: 78, height: 80)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { StartModel.shared.launch(app); StartController.shared.hide() }
        .contextMenu { StartAppMenu(app: app, pinnedContext: pinnedContext) }
        .help(app.name)
    }
}

struct StartAppMenu: View {
    let app: StartModel.AppEntry
    let pinnedContext: Bool
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        let pinnedToStart = settings.startPinned.contains(app.id)
        Button(pinnedToStart ? "Unpin from Start" : "Pin to Start") { settings.toggleStartPin(app.id) }
        if pinnedContext && pinnedToStart {
            Button("Move to front") { settings.moveStartPin(app.id, toFront: true) }
            Button("Move to end") { settings.moveStartPin(app.id, toFront: false) }
        }
        Button(settings.pinned.contains(app.id) ? "Unpin from taskbar" : "Pin to taskbar") { settings.togglePin(app.id) }
        Divider()
        Button("Open file location") { StartModel.shared.reveal(app.url) }
    }
}

struct ListAppRow: View {
    let app: StartModel.AppEntry
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: StartModel.shared.icon(app)).resizable().frame(width: 24, height: 24)
            Text(app.name).font(Theme.font(13))
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { StartModel.shared.launch(app); StartController.shared.hide() }
        .contextMenu { StartAppMenu(app: app, pinnedContext: false) }
    }
}

/// 25H2 category tile: three big icons plus a small cluster for the rest.
struct CategoryTile: View {
    let name: String
    let apps: [StartModel.AppEntry]
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.fixed(40)), GridItem(.fixed(40))], spacing: 8) {
                ForEach(Array(apps.prefix(3))) { a in
                    Image(nsImage: StartModel.shared.icon(a)).resizable().frame(width: 36, height: 36)
                        .onTapGesture { StartModel.shared.launch(a); StartController.shared.hide() }
                        .help(a.name)
                }
                if apps.count > 3 {
                    LazyVGrid(columns: [GridItem(.fixed(16), spacing: 2), GridItem(.fixed(16), spacing: 2)], spacing: 2) {
                        ForEach(Array(apps.dropFirst(3).prefix(4))) { a in
                            Image(nsImage: StartModel.shared.icon(a)).resizable().frame(width: 16, height: 16)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .onTapGesture(perform: open)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.hover(scheme).opacity(1.6) : Theme.control(scheme)))
            .onHover { hovering = $0 }
            Text(name).font(Theme.font(12)).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

struct RecommendedRow: View {
    let icon: NSImage
    let title: String
    let subtitle: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(12)).lineLimit(1)
                Text(subtitle).font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: Search results

struct StartSearchResults: View {
    @ObservedObject private var model = StartModel.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.results.isEmpty {
                        Text("No results for \u{201C}\(model.query)\u{201D}").foregroundStyle(Theme.secondaryText(scheme))
                            .padding(.top, 20)
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { i, r in
                        if i == 0 { header("Best match") }
                        else if r.kind != model.results[i - 1].kind || i == 1 { header(groupTitle(r)) }
                        ResultRow(result: r, selected: model.selection == r)
                    }
                }
            }
            .frame(width: 330)

            if let sel = model.selection {
                VStack(spacing: 10) {
                    resultIcon(sel).resizable().frame(width: 64, height: 64).padding(.top, 24)
                    Text(sel.name).font(Theme.font(16, .semibold)).multilineTextAlignment(.center)
                    Text(sel.kind).foregroundStyle(Theme.secondaryText(scheme))
                    Divider().padding(.vertical, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        action("Open", "arrow.up.forward.app") { model.open(sel) }
                        switch sel {
                        case .app(let a):
                            action(AppSettings.shared.startPinned.contains(a.id) ? "Unpin from Start" : "Pin to Start", "pin") {
                                AppSettings.shared.toggleStartPin(a.id)
                            }
                            action(AppSettings.shared.pinned.contains(a.id) ? "Unpin from taskbar" : "Pin to taskbar", "dock.rectangle") {
                                AppSettings.shared.togglePin(a.id)
                            }
                            action("Open file location", "folder") { model.reveal(a.url) }
                        case .file(let f):
                            action("Open file location", "folder") { model.reveal(f.url) }
                            Text(f.url.deletingLastPathComponent().path).font(Theme.font(11))
                                .foregroundStyle(Theme.secondaryText(scheme)).lineLimit(2).padding(.top, 6)
                        case .setting:
                            EmptyView()
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.control(scheme)))
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func groupTitle(_ r: StartModel.Result) -> String {
        switch r { case .app: return "Apps"; case .file: return "Documents"; case .setting: return "Settings" }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(Theme.font(12, .semibold)).padding(.top, 10).padding(.bottom, 4).padding(.leading, 8)
    }

    private func action(_ title: String, _ symbol: String, _ f: @escaping () -> Void) -> some View {
        ActionRow(title: title, symbol: symbol, action: f)
    }
}

@MainActor func resultIcon(_ r: StartModel.Result) -> Image {
    switch r {
    case .app(let a): return Image(nsImage: StartModel.shared.icon(a))
    case .file(let f): return Image(nsImage: StartModel.shared.icon(file: f.url))
    case .setting:
        return Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app"))
    }
}

struct ResultRow: View {
    let result: StartModel.Result
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5).fill(selected ? Theme.accent : .clear).frame(width: 3, height: 18)
            resultIcon(result).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name).font(Theme.font(13)).lineLimit(1)
                Text(result.kind).font(Theme.font(11)).foregroundStyle(Theme.secondaryText(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected || hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0; if $0 { StartModel.shared.selection = result } }
        .onTapGesture { StartModel.shared.open(result) }
    }
}

struct ActionRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            Text(title).font(Theme.font(13))
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: Bottom bar

struct StartBottomBar: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            // Custom buttons, not SwiftUI Menu: on macOS a Menu label is drawn by AppKit, which
            // ignores SwiftUI sizing (the account photo appeared at full size) and escapes clipping.
            TaskbarButtonChrome(width: nil, height: 44,
                                onLeft: { rect in PowerActions.popUp(PowerActions.accountMenu(), above: rect) }) {
                HStack(spacing: 10) {
                    if let img = PowerActions.userImage {
                        Image(nsImage: img).resizable().interpolation(.high).frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 28))
                    }
                    Text(PowerActions.userName).font(Theme.font(12)).lineLimit(1)
                }
                .padding(.horizontal, 10)
            }
            .fixedSize()
            .padding(.leading, 40)

            Spacer(minLength: 8)

            ForEach(StartFolder.allCases.filter { settings.startFolders.contains($0.rawValue) }) { f in
                BarIcon(symbol: f.symbol, help: f.label) { PowerActions.openFolder(f) }
            }
            TaskbarButtonChrome(width: 36, height: 36,
                                onLeft: { rect in PowerActions.popUp(PowerActions.powerMenu(), above: rect) }) {
                Image(systemName: "power").font(.system(size: 15))
            }
            .help("Power")
            .padding(.trailing, 40)
        }
        .frame(height: 64)
        .background(Theme.flyoutFooter(scheme))
        .overlay(alignment: .top) { Rectangle().fill(Theme.border(scheme)).frame(height: 1) }
    }
}

struct BarIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 15))
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Theme.hover(scheme) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(help)
    }
}
