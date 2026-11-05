import HerdrKit
import SwiftUI

/// The feed's state, shared by the tab and the iPad sidebar: what the machine serves, and the
/// owner's read and starred marks, which stay on the phone. A singleton like `PushCenter`, so
/// it outlives the home view's per-session remount.
@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()

    enum Filter: Hashable { case all, starred, feed(String) }

    /// One source folder on the machine.
    struct Source: Identifiable, Hashable {
        let id: String
        var title: String { id }
    }

    enum Problem: Equatable { case unsupported, failed(String) }

    /// An answer waiting on the card's `confirm` question.
    struct Choice: Identifiable {
        let entry: FeedEntry
        let action: FeedAction?
        let text: String?
        var id: String { entry.id }
    }

    @Published private(set) var entries: [FeedEntry] = []
    @Published private(set) var sources: [Source] = []
    /// Cards the machine could not serve or that are not cards, as "source/id: why".
    @Published private(set) var unreadable: [String] = []
    @Published private(set) var problem: Problem?
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published var filter: Filter = .all { didSet { settle() } }
    /// Off (the default), the timeline holds what is unread, plus what was read since it last
    /// settled, so a row doesn't vanish under the finger or out of the reader's paging.
    @Published var showRead = false { didSet { settle() } }
    @Published private(set) var readIDs: Set<String>
    @Published private(set) var readSinceSettled: Set<String> = []
    @Published private(set) var starred: [FeedEntry]
    /// Cards whose answer is on its way.
    @Published private(set) var sending: Set<String> = []
    /// What a card's `on-reply` script printed, until its own `outcome` says more.
    @Published private(set) var outputs: [String: String] = [:]
    @Published var confirming: Choice?
    @Published var failure: String?

    // ponytail: the newest 3000 read marks; older ones fall off and would show unread again.
    private static let readCap = 3000
    private var readOrder: [String]
    /// Bumped by an answer, so a list fetched before it can't put the card back as unanswered.
    private var generation = 0

    private init() {
        let defaults = UserDefaults.standard
        readOrder = defaults.stringArray(forKey: "feed.read") ?? []
        readIDs = Set(readOrder)
        starred = defaults.data(forKey: "feed.starred")
            .flatMap { try? JSONDecoder().decode([FeedEntry].self, from: $0) } ?? []
    }

    /// The cards that wait for the owner, newest first: "Needs you", above the timeline.
    var pending: [FeedEntry] {
        filter == .starred ? [] : picked.filter { $0.isPending() }
    }

    /// The Feed tab's badge: every card waiting for the owner, whatever the filter.
    var pendingCount: Int { entries.filter { $0.isPending() }.count }

    /// The timeline the filter picks, newest first, without the cards that wait for the owner.
    /// Starred items are kept whole on the phone, so they outlive the feed dropping them;
    /// while still served, the served copy shows.
    var visible: [FeedEntry] {
        switch filter {
        case .all, .feed:
            let settled = picked.filter { !$0.isPending() }
            return showRead ? settled : settled.filter { !readIDs.contains($0.id) || readSinceSettled.contains($0.id) }
        case .starred:
            let served = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return FeedCards.newestFirst(starred.map { served[$0.id] ?? $0 })
        }
    }

    /// How many read items the unread timeline leaves out.
    var hiddenReadCount: Int {
        guard !showRead, filter != .starred else { return 0 }
        return picked.filter { !$0.isPending() }.count - visible.count
    }

    /// The served entries the filter picks.
    private var picked: [FeedEntry] {
        if case .feed(let source) = filter { return entries.filter { $0.source == source } }
        return entries
    }

    /// Drops what was read from the unread timeline.
    func settle() { readSinceSettled = [] }

    var title: String {
        switch filter {
        case .all: return "Feed"
        case .starred: return "Starred"
        case .feed(let source): return source
        }
    }

    func entry(id: String) -> FeedEntry? {
        entries.first { $0.id == id } ?? starred.first { $0.id == id }
    }

    func load(_ client: HerdrClient) async {
        guard !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        let started = generation
        do {
            guard let files = try await client.feedList() else {
                entries = []; sources = []; unreadable = []; problem = .unsupported
                return
            }
            guard generation == started else { return }
            var cards: [FeedEntry] = []
            var broken: [String] = []
            for file in files {
                do {
                    cards.append(try FeedCards.entry(file))
                } catch {
                    broken.append("\(file.source)/\(file.id): \(file.error ?? "not a JSON card")")
                }
            }
            entries = FeedCards.newestFirst(cards)
            sources = Set(files.map(\.source)).sorted().map { Source(id: $0) }
            unreadable = broken
            problem = nil
            for card in cards where card.outcome != nil { outputs[card.id] = nil }
            if case .feed(let source) = filter, !sources.contains(where: { $0.id == source }) { filter = .all }
        } catch {
            problem = .failed(error.localizedDescription)
        }
    }

    /// The owner picked `action` (or sent `text`) on `entry`: asks the card's `confirm`
    /// question first, if it has one.
    func choose(_ entry: FeedEntry, _ action: FeedAction?, text: String?, client: HerdrClient) {
        let choice = Choice(entry: entry, action: action, text: text)
        if entry.confirm != nil {
            confirming = choice
        } else {
            Task { await send(choice, client: client) }
        }
    }

    func send(_ choice: Choice, client: HerdrClient) async {
        let entry = choice.entry
        guard !sending.contains(entry.id) else { return }
        sending.insert(entry.id)
        defer { sending.remove(entry.id) }
        do {
            let output = try await client.feedAct(source: entry.source, id: entry.cardID,
                                                  action: choice.action?.id, text: choice.text)
            generation += 1
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].reply = FeedReply(action: choice.action?.id, text: choice.text, at: Date())
            }
            outputs[entry.id] = output
            setRead([entry], true)
        } catch let error as APIError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
        await load(client)
    }

    func isRead(_ entry: FeedEntry) -> Bool { readIDs.contains(entry.id) }
    func isStarred(_ entry: FeedEntry) -> Bool { starred.contains { $0.id == entry.id } }

    func setRead(_ entries: [FeedEntry], _ read: Bool) {
        for entry in entries {
            if read, !readIDs.contains(entry.id) {
                readIDs.insert(entry.id)
                readOrder.append(entry.id)
                readSinceSettled.insert(entry.id)
            } else if !read, readIDs.remove(entry.id) != nil {
                readOrder.removeAll { $0 == entry.id }
            }
        }
        if readOrder.count > Self.readCap {
            let dropped = readOrder.prefix(readOrder.count - Self.readCap)
            readIDs.subtract(dropped)
            readOrder.removeFirst(dropped.count)
        }
        UserDefaults.standard.set(readOrder, forKey: "feed.read")
    }

    func toggleStar(_ entry: FeedEntry) {
        if isStarred(entry) {
            starred.removeAll { $0.id == entry.id }
        } else {
            starred.append(entry)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(starred), forKey: "feed.starred")
    }
}

/// The Feed tab, in the manner of Reeder: the cards that wait for the owner ("Needs you",
/// with their buttons inline) above one timeline of everything else, newest first and grouped
/// by day. A dot marks what is unread; swipe right to toggle read, left to star. The title is
/// the timeline picker (all, starred, one source).
struct FeedView: View {
    let client: HerdrClient
    @ObservedObject private var store = FeedStore.shared
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                content
            }
            .background(Palette.ground)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                FeedReaderView(entryID: id, client: client)
            }
        }
        .confirmationDialog(
            store.confirming?.entry.confirm ?? "",
            isPresented: Binding(get: { store.confirming != nil }, set: { if !$0 { store.confirming = nil } }),
            titleVisibility: .visible,
            presenting: store.confirming
        ) { choice in
            Button(choice.action?.label ?? "Send", role: choice.action?.isDestructive == true ? .destructive : nil) {
                Task { await store.send(choice, client: client) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't send",
               isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: store.failure ?? "")
        }
        .task { await store.load(client) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await store.load(client) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Menu {
                Picker("Timeline", selection: $store.filter) {
                    Label("All", systemImage: "tray.full").tag(FeedStore.Filter.all)
                    Label("Starred", systemImage: "star").tag(FeedStore.Filter.starred)
                    ForEach(store.sources) { source in
                        Text(verbatim: source.title).tag(FeedStore.Filter.feed(source.id))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: store.title)
                        .font(Typography.app(28, .bold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.textDim)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("feed-timeline")
            Spacer(minLength: 8)
            let unread = store.visible.filter { !store.isRead($0) }
            Button {
                store.setRead(unread, true)
                store.settle()
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(unread.isEmpty ? Palette.textFaint : Palette.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gramGlass(Capsule())
            .disabled(unread.isEmpty)
            .accessibilityLabel("Mark all as read")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - Timeline

    @ViewBuilder
    private var content: some View {
        if let problem = store.problem, store.entries.isEmpty || problem == .unsupported {
            switch problem {
            case .unsupported:
                notice("Update herdr to read feeds",
                       "This machine's herdr predates feed cards. Update it from Settings, then come back.")
            case .failed(let message):
                notice("Couldn't load the feed", message)
            }
        } else if !store.loaded {
            Spacer(); ProgressView().tint(Palette.textDim); Spacer()
        } else if store.sources.isEmpty {
            emptyFeeds
        } else {
            timeline
        }
    }

    private var timeline: some View {
        let pending = store.pending
        let entries = store.visible
        return List {
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { entry in
                        FeedAskCard(entry: entry, sending: store.sending.contains(entry.id),
                                    onOpen: { path.append(entry.id) },
                                    onChoose: { store.choose(entry, $0, text: nil, client: client) })
                            .listRowBackground(Palette.ground)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    }
                } header: {
                    sectionHeader("Needs you", tint: Palette.waiting)
                }
            }
            ForEach(days(entries), id: \.day) { day in
                Section {
                    ForEach(day.entries) { entry in row(entry) }
                } header: {
                    sectionHeader(day.day, tint: Palette.textFaint)
                }
            }
            if entries.isEmpty {
                Text(store.filter == .starred ? "Star an item to keep it here."
                     : store.hiddenReadCount > 0 || !pending.isEmpty ? "All caught up." : "Nothing here yet.")
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
                    .listRowBackground(Palette.ground)
                    .listRowSeparator(.hidden)
            }
            if store.filter != .starred, store.showRead || store.hiddenReadCount > 0 {
                Button { store.showRead.toggle() } label: {
                    Text(verbatim: store.showRead ? "Hide read" : "Show \(store.hiddenReadCount) read")
                        .font(Typography.app(15, .semibold))
                        .foregroundStyle(Palette.brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.ground)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("feed-show-read")
            }
            ForEach(store.unreadable, id: \.self) { problem in
                Label {
                    Text(verbatim: problem)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(Typography.app(13))
                .foregroundStyle(Palette.textFaint)
                .listRowBackground(Palette.ground)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { store.settle(); await store.load(client) }
    }

    private func sectionHeader(_ title: String, tint: Color) -> some View {
        Text(verbatim: title)
            .font(Typography.app(13, .semibold))
            .foregroundStyle(tint)
            .textCase(nil)
    }

    private func row(_ entry: FeedEntry) -> some View {
        let read = store.isRead(entry)
        let starred = store.isStarred(entry)
        return Button { path.append(entry.id) } label: {
            FeedRow(entry: entry, read: read, starred: starred, output: store.outputs[entry.id])
        }
        .buttonStyle(.plain)
        .listRowBackground(Palette.ground)
        .listRowSeparatorTint(Palette.hairlineQuiet)
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 16))
        .swipeActions(edge: .leading) {
            Button { store.setRead([entry], !read) } label: {
                Label(read ? "Unread" : "Read", systemImage: read ? "circle.fill" : "checkmark")
            }
            .tint(Palette.brand)
        }
        .swipeActions(edge: .trailing) {
            Button { store.toggleStar(entry) } label: {
                Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star.fill")
            }
            .tint(Palette.waiting)
        }
        .contextMenu {
            Button { store.setRead([entry], !read) } label: {
                Label(read ? "Mark as unread" : "Mark as read", systemImage: read ? "circle" : "checkmark.circle")
            }
            Button { store.toggleStar(entry) } label: {
                Label(starred ? "Unstar" : "Star", systemImage: starred ? "star.slash" : "star")
            }
            if let link = entry.link {
                ShareLink(item: link)
            }
        }
    }

    private struct Day { let day: String; let entries: [FeedEntry] }

    /// Consecutive entries under their day ("Today", "Yesterday", a weekday, a date).
    private func days(_ entries: [FeedEntry]) -> [Day] {
        var result: [Day] = []
        for entry in entries {
            let day = entry.date.map { GramDates.separator(for: $0).day } ?? "Undated"
            if result.last?.day == day {
                result[result.count - 1] = Day(day: day, entries: result[result.count - 1].entries + [entry])
            } else {
                result.append(Day(day: day, entries: [entry]))
            }
        }
        return result
    }

    private var emptyFeeds: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("No cards yet")
                    .font(Typography.app(20, .semibold))
                    .foregroundStyle(Palette.text)
                Text("Scripts on this machine publish here. Each JSON file in a folder under this one is a card: something to read, or a question with buttons. Write it to a temporary name and rename it into place, so it's never read half-written.")
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
                CopyableCommand(command: "~/.config/herdr/feeds/<source>/<id>.json")
            }
            .padding(20)
        }
        .refreshable { await store.load(client) }
    }

    private func notice(_ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(verbatim: title)
                .font(Typography.app(18, .semibold))
                .foregroundStyle(Palette.text)
            Text(verbatim: message)
                .font(Typography.app(15))
                .foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await store.load(client) } }
                .font(Typography.app(15, .semibold))
                .padding(.top, 6)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// A card's source and time, as the timeline and the cards set them above the title.
private struct FeedMeta: View {
    let entry: FeedEntry
    var starred = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: entry.source.uppercased())
                .font(Typography.app(11, .semibold))
                .kerning(0.6)
                .lineLimit(1)
            if let date = entry.date {
                Text(verbatim: date.formatted(date: .omitted, time: .shortened))
                    .font(Typography.app(12))
            }
            Spacer(minLength: 0)
            if let expires = entry.expires, entry.isPending() {
                Text(verbatim: "Until " + (Calendar.current.isDateInToday(expires)
                    ? expires.formatted(date: .omitted, time: .shortened)
                    : expires.formatted(.dateTime.month(.abbreviated).day().hour().minute())))
                    .font(Typography.app(12))
                    .foregroundStyle(Palette.waiting)
            }
            if starred {
                Image(systemName: "star.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.waiting)
            }
        }
        .foregroundStyle(Palette.textFaint)
    }
}

/// The preview line under a card's title: its summary, or its body as plain text.
private func feedPreview(_ entry: FeedEntry) -> String {
    (entry.summary ?? ChatMessageText.plain(entry.body))
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// A card waiting for the owner, in "Needs you": its buttons sit on the card. A card that
/// takes text offers Reply, which opens it with the text field.
private struct FeedAskCard: View {
    let entry: FeedEntry
    let sending: Bool
    let onOpen: () -> Void
    let onChoose: (FeedAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FeedMeta(entry: entry)
            Text(verbatim: entry.title)
                .font(Typography.app(17, .semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(3)
            let preview = feedPreview(entry)
            if !preview.isEmpty, preview != entry.title {
                Text(verbatim: preview)
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
                    .lineLimit(3)
            }
            FeedActionButtons(entry: entry, sending: sending, onChoose: onChoose, onReply: onOpen)
                .padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairlineQuiet))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityIdentifier("feed-ask-\(entry.id)")
    }
}

/// A card's actions as pills: the first is filled with ink (the design's acting control), the
/// rest quiet, a destructive one in red. Reply, when the card takes text, comes last.
private struct FeedActionButtons: View {
    let entry: FeedEntry
    let sending: Bool
    let onChoose: (FeedAction) -> Void
    var onReply: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(entry.actions.enumerated()), id: \.element.id) { index, action in
                pill(action.label, primary: index == 0 && !action.isDestructive,
                     destructive: action.isDestructive) { onChoose(action) }
            }
            if entry.input != nil, let onReply {
                pill("Reply", primary: entry.actions.isEmpty, destructive: false, action: onReply)
            }
            Spacer(minLength: 0)
            if sending { ProgressView().controlSize(.small).tint(Palette.textDim) }
        }
        .disabled(sending)
    }

    private func pill(_ label: String, primary: Bool, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(Typography.app(15, .semibold))
                .lineLimit(1)
                .foregroundStyle(primary ? Palette.ground : destructive ? Palette.died : Palette.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(primary ? Palette.text : Palette.surfaceRaised))
                .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
    }
}

/// Under a settled card's preview: the owner's answer and what came of it, or that it expired.
private struct FeedStatusLine: View {
    let entry: FeedEntry
    let output: String?

    var body: some View {
        if let outcome = entry.outcome {
            line("checkmark.circle.fill", outcome, Palette.done)
        } else if let answer = entry.replySummary {
            line("arrowshape.turn.up.left.fill", [answer, output].compactMap { $0 }.joined(separator: " — "), Palette.textDim)
        } else if entry.asks, entry.isExpired() {
            line("clock", "Expired", Palette.textFaint)
        }
    }

    private func line(_ icon: String, _ text: String, _ tint: Color) -> some View {
        Label {
            Text(verbatim: text).lineLimit(3)
        } icon: {
            Image(systemName: icon).font(.system(size: 12))
        }
        .font(Typography.app(14, .medium))
        .foregroundStyle(tint)
    }
}

/// A timeline row: the source and time over the title, the first lines of the card, and
/// what came of a question.
private struct FeedRow: View {
    let entry: FeedEntry
    let read: Bool
    let starred: Bool
    let output: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(read ? Color.clear : Palette.brand)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                FeedMeta(entry: entry, starred: starred)
                Text(verbatim: entry.title)
                    .font(Typography.app(17, .semibold))
                    .foregroundStyle(read ? Palette.textDim : Palette.text)
                    .lineLimit(3)
                let preview = feedPreview(entry)
                if !preview.isEmpty, preview != entry.title {
                    Text(verbatim: preview)
                        .font(Typography.app(15))
                        .foregroundStyle(read ? Palette.textFaint : Palette.textDim)
                        .lineLimit(3)
                }
                FeedStatusLine(entry: entry, output: output)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(read ? "" : "Unread")
    }
}

/// One card, full screen: its markdown body, and for a question the answer bar (text field
/// and buttons) at the bottom. Star and up/down to the neighbouring cards are in the bottom
/// bar. Opening it marks it read.
struct FeedReaderView: View {
    let client: HerdrClient
    @ObservedObject private var store = FeedStore.shared
    @State private var entryID: String
    @State private var text = ""
    @FocusState private var typing: Bool

    init(entryID: String, client: HerdrClient) {
        _entryID = State(initialValue: entryID)
        self.client = client
    }

    var body: some View {
        let entry = store.entry(id: entryID)
        // A question pages through the other questions; anything else through the timeline.
        let list = entry?.isPending() == true ? store.pending : store.visible
        let index = list.firstIndex { $0.id == entryID }
        Group {
            if let entry {
                ScrollView {
                    article(entry)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(entry.id)
                .safeAreaInset(edge: .bottom) {
                    if entry.isPending() { answerBar(entry) }
                }
            } else {
                Text("This card is no longer in the feed.")
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if let entry {
                    Button { store.toggleStar(entry) } label: {
                        Image(systemName: store.isStarred(entry) ? "star.fill" : "star")
                    }
                    .accessibilityLabel(store.isStarred(entry) ? "Unstar" : "Star")
                }
                Spacer()
                Button { move(list, index, -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index.map { $0 == 0 } ?? true)
                    .accessibilityLabel("Previous")
                Button { move(list, index, 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index.map { $0 == list.count - 1 } ?? true)
                    .accessibilityLabel("Next")
                Spacer()
                if let link = entry?.link {
                    ShareLink(item: link)
                }
            }
        }
        .onAppear { if let entry { store.setRead([entry], true) } }
    }

    private func article(_ entry: FeedEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedMeta(entry: entry)
            Group {
                if let link = entry.link {
                    Link(destination: link) { Text(verbatim: entry.title) }
                } else {
                    Text(verbatim: entry.title)
                }
            }
            .font(Typography.app(26, .bold))
            .foregroundStyle(Palette.text)
            .padding(.top, 6)
            if let date = entry.date {
                Text(verbatim: date.formatted(date: .long, time: .shortened))
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textFaint)
                    .padding(.top, 4)
            }
            if !entry.body.isEmpty {
                ChatMarkdownView(markdown: entry.body)
                    .padding(.top, 18)
            }
            FeedStatusLine(entry: entry, output: store.outputs[entry.id])
                .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// The text field (when the card takes text) over the card's buttons. A card with only a
    /// text field sends with Send; an action sends the text along with it.
    private func answerBar(_ entry: FeedEntry) -> some View {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = store.sending.contains(entry.id)
        return VStack(alignment: .leading, spacing: 10) {
            if let placeholder = entry.input {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder.isEmpty ? "Reply" : placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .font(Typography.app(16))
                        .foregroundStyle(Palette.text)
                        .focused($typing)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityIdentifier("feed-reply-field")
                    if entry.actions.isEmpty {
                        Button {
                            typing = false
                            store.choose(entry, nil, text: note, client: client)
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Palette.ground)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(note.isEmpty ? Palette.textFaint : Palette.text))
                        }
                        .buttonStyle(.plain)
                        .disabled(note.isEmpty || sending)
                        .accessibilityLabel("Send")
                    }
                }
            }
            if !entry.actions.isEmpty {
                FeedActionButtons(entry: entry, sending: sending) { action in
                    typing = false
                    store.choose(entry, action, text: note.isEmpty ? nil : note, client: client)
                }
            } else if sending {
                ProgressView().controlSize(.small).tint(Palette.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Palette.ground)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
    }

    private func move(_ list: [FeedEntry], _ index: Int?, _ delta: Int) {
        guard let index, list.indices.contains(index + delta) else { return }
        let next = list[index + delta]
        entryID = next.id
        text = ""
        store.setRead([next], true)
    }
}

/// The iPad sidebar's timelines: All, Starred and each source. Selecting one sets the filter the
/// Feed page in the detail column reads.
struct FeedTimelineList: View {
    @ObservedObject private var store = FeedStore.shared

    var body: some View {
        VStack(spacing: 2) {
            item(.all, "All", icon: "tray.full")
            item(.starred, "Starred", icon: "star")
            ForEach(store.sources) { source in
                item(.feed(source.id), source.title, icon: "folder")
            }
        }
    }

    private func item(_ filter: FeedStore.Filter, _ title: String, icon: String) -> some View {
        let selected = store.filter == filter
        return Button { store.filter = filter } label: {
            Label(title, systemImage: icon)
                .font(Typography.app(15, .medium))
                .foregroundStyle(selected ? Palette.text : Palette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(selected ? Palette.surfaceRaised : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
