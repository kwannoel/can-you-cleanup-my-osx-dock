import AppKit
import SwiftUI

struct DockItem: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let filePath: String
    let dockExtra: Bool

    var displayPath: String {
        filePath.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? filePath
    }
}

enum DockDecision: String, Codable {
    case keep
    case remove
}

struct StoredDecision: Codable, Identifiable {
    let item: DockItem
    let decision: DockDecision
    let decidedAt: Date

    var id: String { item.id }
}

final class DecisionStore {
    private let fileURL: URL
    private(set) var decisions: [String: StoredDecision] = [:]

    init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = supportDirectory.appendingPathComponent("DockSwipe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("decisions.json")
        load()
    }

    func set(_ decision: DockDecision, for item: DockItem) {
        decisions[item.id] = StoredDecision(item: item, decision: decision, decidedAt: Date())
        save()
    }

    func clear(_ item: DockItem) {
        decisions.removeValue(forKey: item.id)
        save()
    }

    func reset() {
        decisions.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoded = try? JSONDecoder().decode([String: StoredDecision].self, from: data)
        decisions = decoded ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(decisions) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

enum DockReader {
    static func loadPersistentAppEntries() -> [[String: Any]] {
        guard let dockDefaults = UserDefaults(suiteName: "com.apple.dock"),
              let apps = dockDefaults.array(forKey: "persistent-apps") as? [[String: Any]] else {
            return []
        }
        return apps
    }

    static func stableIdentifier(for entry: [String: Any]) -> String? {
        guard let tileData = entry["tile-data"] as? [String: Any] else { return nil }
        let bundleID = tileData["bundle-identifier"] as? String ?? ""
        let fileData = tileData["file-data"] as? [String: Any]
        let fileURL = fileData?["_CFURLString"] as? String ?? ""
        return bundleID.isEmpty ? fileURL : bundleID
    }

    static func loadPersistentApps() -> [DockItem] {
        let apps = loadPersistentAppEntries()
        guard !apps.isEmpty else {
            return sampleItems
        }

        let items: [DockItem] = apps.compactMap { entry in
            guard let tileData = entry["tile-data"] as? [String: Any] else { return nil }
            let name = tileData["file-label"] as? String ?? "Unknown App"
            let bundleID = tileData["bundle-identifier"] as? String ?? name
            let dockExtra = (tileData["dock-extra"] as? Int ?? 0) == 1
            let fileData = tileData["file-data"] as? [String: Any]
            let fileURL = fileData?["_CFURLString"] as? String ?? ""
            let stableID = bundleID.isEmpty ? fileURL : bundleID

            return DockItem(
                id: stableID,
                name: name,
                bundleIdentifier: bundleID,
                filePath: fileURL,
                dockExtra: dockExtra
            )
        }

        return items.isEmpty ? sampleItems : items
    }

    private static let sampleItems = [
        DockItem(id: "com.apple.Safari", name: "Safari", bundleIdentifier: "com.apple.Safari", filePath: "/System/Applications/Safari.app", dockExtra: false),
        DockItem(id: "com.apple.mail", name: "Mail", bundleIdentifier: "com.apple.mail", filePath: "/System/Applications/Mail.app", dockExtra: false),
        DockItem(id: "com.apple.iWork.Pages", name: "Pages", bundleIdentifier: "com.apple.iWork.Pages", filePath: "/Applications/Pages.app", dockExtra: false)
    ]
}

@MainActor
final class DockSwipeModel: ObservableObject {
    enum ApplyState: Equatable {
        case idle
        case applying
        case applied(removedCount: Int)
        case failed(message: String)
    }

    @Published private(set) var items: [DockItem]
    @Published private(set) var decisions: [String: StoredDecision]
    @Published var activeIndex: Int
    @Published var cardOffset: CGSize = .zero
    @Published var cardRotation: Double = 0
    @Published private(set) var lastDecision: DockDecision = .keep
    @Published private(set) var applyState: ApplyState = .idle

    private let store = DecisionStore()
    private var history: [DockItem] = []

    init() {
        let loadedItems = DockReader.loadPersistentApps()
        let loadedDecisions = store.decisions
        items = loadedItems
        decisions = loadedDecisions
        activeIndex = loadedItems.firstIndex { loadedDecisions[$0.id] == nil } ?? 0
    }

    var activeItem: DockItem? {
        guard activeIndex < items.count else { return nil }
        return items[activeIndex]
    }

    var keptItems: [DockItem] {
        decisions.values
            .filter { $0.decision == .keep }
            .sorted { $0.decidedAt < $1.decidedAt }
            .map(\.item)
    }

    var removeItems: [DockItem] {
        decisions.values
            .filter { $0.decision == .remove }
            .sorted { $0.decidedAt < $1.decidedAt }
            .map(\.item)
    }

    var progressText: String {
        "\(min(decisions.count, items.count)) / \(items.count)"
    }

    func decide(_ decision: DockDecision) {
        guard let item = activeItem else { return }
        history.append(item)
        lastDecision = decision

        store.set(decision, for: item)
        decisions = store.decisions

        withAnimation(.easeOut(duration: 0.2)) {
            self.advance()
        }
    }

    func undo() {
        guard let item = history.popLast() else { return }
        store.clear(item)
        decisions = store.decisions
        activeIndex = items.firstIndex(of: item) ?? activeIndex

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            cardOffset = .zero
            cardRotation = 0
        }
    }

    func resetDecisions() {
        history.removeAll()
        store.reset()
        decisions = store.decisions
        activeIndex = 0
        cardOffset = .zero
        cardRotation = 0
        applyState = .idle
    }

    func applyCleanup() {
        guard applyState != .applying else { return }
        let removeIDs = Set(removeItems.map(\.id))
        guard !removeIDs.isEmpty else {
            applyState = .applied(removedCount: 0)
            return
        }

        applyState = .applying

        let existingEntries = DockReader.loadPersistentAppEntries()
        guard !existingEntries.isEmpty else {
            applyState = .failed(message: "Could not read current Dock entries.")
            return
        }

        let filteredEntries = existingEntries.filter { entry in
            guard let stableID = DockReader.stableIdentifier(for: entry) else { return true }
            return !removeIDs.contains(stableID)
        }

        guard let dockDefaults = UserDefaults(suiteName: "com.apple.dock") else {
            applyState = .failed(message: "Could not access Dock preferences.")
            return
        }

        dockDefaults.set(filteredEntries, forKey: "persistent-apps")
        dockDefaults.synchronize()

        let removedCount = existingEntries.count - filteredEntries.count
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
        task.waitUntilExit()

        if task.terminationStatus == 0 {
            applyState = .applied(removedCount: removedCount)
            items = DockReader.loadPersistentApps()
            activeIndex = items.count
        } else {
            applyState = .failed(message: "Dock restart failed. Changes may require manual relaunch.")
        }
    }

    private func advance() {
        if let nextIndex = items.indices.first(where: { $0 > activeIndex && decisions[items[$0].id] == nil }) {
            activeIndex = nextIndex
        } else {
            activeIndex = items.count
        }

        cardOffset = .zero
        cardRotation = 0
    }
}

struct DockSwipeView: View {
    @StateObject private var model = DockSwipeModel()

    var body: some View {
        KeyboardReader(
            onKeep: { model.decide(.keep) },
            onRemove: { model.decide(.remove) },
            onUndo: { model.undo() }
        ) {
            ZStack {
                AppTheme.background.ignoresSafeArea()
                HStack(spacing: 0) {
                    mainStage
                    decisionRail
                }
            }
        }
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 620, idealHeight: 700)
    }

    private var mainStage: some View {
        VStack(spacing: 22) {
            topBar

            Spacer(minLength: 12)

            ZStack {
                ForEach(backgroundCards.indices, id: \.self) { index in
                    DockCard(item: backgroundCards[index], decision: model.decisions[backgroundCards[index].id]?.decision)
                        .scaleEffect(0.94 - CGFloat(index) * 0.035)
                        .offset(y: CGFloat(index + 1) * 18)
                        .opacity(0.42 - Double(index) * 0.12)
                        .allowsHitTesting(false)
                }

                if let item = model.activeItem {
                    DockCard(item: item, decision: model.decisions[item.id]?.decision)
                        .id(item.id)
                        .offset(model.cardOffset)
                        .rotationEffect(.degrees(model.cardRotation))
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    model.cardOffset = value.translation
                                    let rawTilt = Double(value.translation.width / 160)
                                    model.cardRotation = max(-4, min(4, rawTilt))
                                }
                                .onEnded { value in
                                    if value.translation.width > 130 {
                                        model.decide(.keep)
                                    } else if value.translation.width < -130 {
                                        model.decide(.remove)
                                    } else {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                                            model.cardOffset = .zero
                                            model.cardRotation = 0
                                        }
                                    }
                                }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: model.lastDecision == .keep ? .trailing : .leading).combined(with: .opacity)
                            )
                        )
                } else {
                    DoneView(
                        kept: model.keptItems.count,
                        removed: model.removeItems.count,
                        applyState: model.applyState,
                        onApply: { model.applyCleanup() }
                    )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 430)

            actionBar

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DockSwipe")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Choose what deserves a permanent spot.")
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Text(model.progressText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(AppTheme.chip, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(AppTheme.strokeStrong, lineWidth: 1)
                }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    model.decide(.remove)
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
                .keyboardShortcut("j", modifiers: [])
                .buttonStyle(DecisionButtonStyle(tint: AppTheme.remove))

                Button {
                    model.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: [.command])
                .buttonStyle(QuietButtonStyle())

                Button {
                    model.decide(.keep)
                } label: {
                    Label("Keep", systemImage: "checkmark")
                }
                .keyboardShortcut("k", modifiers: [])
                .buttonStyle(DecisionButtonStyle(tint: AppTheme.keep))
            }
            .controlSize(.large)

            Text("Shortcuts: J remove  K keep  Command-Z undo")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textMuted)
        }
    }

    private var decisionRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Remembered")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button("Reset") {
                    model.resetDecisions()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.textSecondary)
            }

            DecisionList(title: "Keep", items: model.keptItems, tint: AppTheme.keep)
            DecisionList(title: "Remove", items: model.removeItems, tint: AppTheme.remove)

            Spacer()
        }
        .padding(24)
        .frame(width: 300)
        .background(AppTheme.panel)
        .overlay {
            Rectangle()
                .fill(AppTheme.strokeSoft)
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var backgroundCards: [DockItem] {
        guard model.activeIndex + 1 < model.items.count else { return [] }
        return Array(model.items[(model.activeIndex + 1)..<min(model.items.count, model.activeIndex + 4)])
    }
}

struct DockCard: View {
    let item: DockItem
    let decision: DockDecision?

    var body: some View {
        VStack(spacing: 22) {
            AppIconView(path: item.displayPath, size: 132)
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.36), radius: 24, y: 12)

            VStack(spacing: 8) {
                Text(item.name)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(AppTheme.textPrimary)

                Text(item.bundleIdentifier)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(spacing: 10) {
                if item.dockExtra {
                    TagView(text: "suggested by macOS", color: AppTheme.gold)
                }
                if let decision {
                    TagView(text: decision.rawValue, color: decision == .keep ? AppTheme.keep : AppTheme.remove)
                }
            }

            Text(item.displayPath)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textMuted)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 38)
                .padding(.horizontal, 8)
        }
        .padding(32)
        .frame(width: 470, height: 390)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.strokeStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 30, y: 18)
    }
}

struct AppIconView: NSViewRepresentable {
    let path: String
    let size: CGFloat

    init(path: String, size: CGFloat = 132) {
        self.path = path
        self.size = size
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        let resolvedPath = path.hasPrefix("/") ? path : URL(string: path)?.path ?? path
        let icon = NSWorkspace.shared.icon(forFile: resolvedPath)
        icon.size = NSSize(width: size, height: size)
        imageView.image = icon
    }
}

struct DecisionList: View {
    let title: String
    let items: [DockItem]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text("Nothing yet")
                            .foregroundStyle(AppTheme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(items) { item in
                            HStack(spacing: 9) {
                                AppIconView(path: item.displayPath, size: 22)
                                    .frame(width: 22, height: 22)
                                Text(item.name)
                                    .lineLimit(1)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(AppTheme.rowFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }
}

struct DoneView: View {
    let kept: Int
    let removed: Int
    let applyState: DockSwipeModel.ApplyState
    let onApply: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(AppTheme.keep)
            Text("Dock sorted")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
            Text("\(kept) kept, \(removed) marked for removal.")
                .foregroundStyle(AppTheme.textSecondary)
            Button {
                onApply()
            } label: {
                Label(buttonTitle, systemImage: buttonIcon)
            }
            .buttonStyle(DecisionButtonStyle(tint: AppTheme.keep))
            .disabled(isApplyDisabled)

            if case .failed(let message) = applyState {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.remove)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(width: 470, height: 390)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.strokeStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 14)
    }

    private var buttonTitle: String {
        switch applyState {
        case .idle:
            return removed == 0 ? "Nothing To Remove" : "Apply Cleanup"
        case .applying:
            return "Applying..."
        case .applied(let removedCount):
            return removedCount == 0 ? "No Changes Needed" : "Removed \(removedCount) Items"
        case .failed:
            return "Retry Apply"
        }
    }

    private var buttonIcon: String {
        switch applyState {
        case .applied:
            return "checkmark"
        default:
            return "wand.and.stars"
        }
    }

    private var isApplyDisabled: Bool {
        if case .applying = applyState { return true }
        if case .applied = applyState { return true }
        return removed == 0
    }
}

struct TagView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(color.opacity(0.95))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.22), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.45), lineWidth: 1)
            }
    }
}

struct DecisionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(tint.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(AppTheme.chip.opacity(configuration.isPressed ? 0.62 : 1), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(AppTheme.strokeStrong, lineWidth: 1)
            }
    }
}

struct KeyboardReader<Content: View>: NSViewRepresentable {
    let onKeep: () -> Void
    let onRemove: () -> Void
    let onUndo: () -> Void
    let content: Content

    init(onKeep: @escaping () -> Void, onRemove: @escaping () -> Void, onUndo: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onKeep = onKeep
        self.onRemove = onRemove
        self.onUndo = onUndo
        self.content = content()
    }

    func makeNSView(context: Context) -> KeyboardHostingView<Content> {
        KeyboardHostingView(rootView: content, onKeep: onKeep, onRemove: onRemove, onUndo: onUndo)
    }

    func updateNSView(_ nsView: KeyboardHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.onKeep = onKeep
        nsView.onRemove = onRemove
        nsView.onUndo = onUndo
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

final class KeyboardHostingView<Content: View>: NSHostingView<Content> {
    var onKeep: () -> Void
    var onRemove: () -> Void
    var onUndo: () -> Void

    init(rootView: Content, onKeep: @escaping () -> Void, onRemove: @escaping () -> Void, onUndo: @escaping () -> Void) {
        self.onKeep = onKeep
        self.onRemove = onRemove
        self.onUndo = onUndo
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        switch characters {
        case "k":
            onKeep()
        case "j":
            onRemove()
        case "z" where event.modifierFlags.contains(.command):
            onUndo()
        default:
            super.keyDown(with: event)
        }
    }
}

enum AppTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.08, blue: 0.11),
            Color(red: 0.09, green: 0.12, blue: 0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let panel = Color(red: 0.08, green: 0.11, blue: 0.15).opacity(0.9)
    static let surface = Color(red: 0.10, green: 0.14, blue: 0.19).opacity(0.94)
    static let chip = Color(red: 0.14, green: 0.18, blue: 0.24).opacity(0.95)
    static let rowFill = Color(red: 0.15, green: 0.19, blue: 0.25).opacity(0.58)
    static let textPrimary = Color(red: 0.93, green: 0.96, blue: 0.98)
    static let textSecondary = Color(red: 0.74, green: 0.80, blue: 0.86)
    static let textMuted = Color(red: 0.58, green: 0.65, blue: 0.73)
    static let strokeStrong = Color.white.opacity(0.22)
    static let strokeSoft = Color.white.opacity(0.10)
    static let keep = Color(red: 0.18, green: 0.78, blue: 0.59)
    static let remove = Color(red: 0.94, green: 0.32, blue: 0.37)
    static let gold = Color(red: 0.90, green: 0.67, blue: 0.23)
}

@main
struct DockSwipeApp: App {
    var body: some Scene {
        WindowGroup {
            DockSwipeView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("DockSwipe") {
                Button("Keep") {
                    NSApp.sendAction(#selector(AppCommandBridge.keep), to: nil, from: nil)
                }
                .keyboardShortcut("k", modifiers: [])
                Button("Remove") {
                    NSApp.sendAction(#selector(AppCommandBridge.remove), to: nil, from: nil)
                }
                .keyboardShortcut("j", modifiers: [])
            }
        }
    }
}

final class AppCommandBridge: NSObject {
    @objc func keep() {}
    @objc func remove() {}
}
