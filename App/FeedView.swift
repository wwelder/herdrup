import HerdrKit
import SwiftUI

/// Which saved machine holds the feed. Agents on every machine push their cards to that one
/// machine, and the Feed tab reads it whichever machine is open in Agents.
enum FeedPreference {
    /// `SavedHost.id.uuidString`; "" (or a machine no longer saved) reads every saved machine.
    static let machineKey = "feed.machine"
}

/// The feed's state, shared by the tab and the iPad sidebar: what the feed's machine serves
/// (`FeedPreference`; every saved machine merged into one timeline until one is picked), and
/// the owner's read and starred marks, which stay on the phone. The feed does not follow the
/// machine open in Agents, and an answer goes back to the machine that serves the card. A
/// singleton like `PushCenter`, so it outlives the home view's per-session remount.
@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()

    enum Filter: Hashable { case all, starred, feed(String) }

    /// One source folder, on any machine.
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
    /// A card to open in the reader, from a tapped question push.
    @Published var opening: String?
    /// The card whose answer was just sent, and the next one that waits for the owner (nil
    /// when none does): the reader showing the answered card moves on.
    struct Answered: Equatable {
        let id: String
        let next: String?
    }
    @Published var answered: Answered?
    @Published var failure: String?

    // ponytail: the newest 3000 read marks; older ones fall off and would show unread again.
    private static let readCap = 3000
    private var readOrder: [String]
    /// What one machine served last. A machine that cannot be reached keeps its cards on
    /// screen and says why in `unreadable`.
    private struct Served {
        var entries: [FeedEntry] = []
        var sources: Set<String> = []
        var unreadable: [String] = []
        /// Nil once the machine has served its feed; before that, why it has not.
        var problem: Problem?
        var served = false
    }
    private var machines: [String: Served] = [:]
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

    /// The card named `id`. A question push, and a mark from before cards had a machine, name
    /// it `source/id`: that finds the card of that name on whichever machine serves it.
    func entry(id: String) -> FeedEntry? {
        entries.first { $0.id == id } ?? starred.first { $0.id == id }
            ?? entries.first { $0.legacyID == id }
    }

    /// The saved machine's name, for a card's source line. Nil while one machine serves the
    /// whole feed, where the name would say nothing.
    func machineLabel(_ entry: FeedEntry) -> String? {
        guard machines.values.filter({ $0.served }).count > 1, let id = entry.machine else { return nil }
        return SavedHostsStore.shared.hosts.first { $0.id.uuidString == id }?.label
    }

    /// Reads the feed's machine, or every saved machine at once when none is picked. Each
    /// machine's cards land as it answers, so a machine that is asleep delays only itself.
    // ponytail: with no machine picked, every saved machine is dialled on every load, a minute
    // apart, reachable or not (a dead one costs its 15 s connect budget).
    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        let saved = SavedHostsStore.shared.hosts
        let picked = UserDefaults.standard.string(forKey: FeedPreference.machineKey) ?? ""
        let hosts = saved.contains { $0.id.uuidString == picked } ? saved.filter { $0.id.uuidString == picked } : saved
        let known = Set(hosts.map(\.id.uuidString))
        machines = machines.filter { known.contains($0.key) }
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { await self.load(host) }
            }
        }
        merge()
    }

    private func load(_ host: SavedHost) async {
        let machine = host.id.uuidString
        // A machine saved without its secret on this phone has no feed to read here.
        guard let client = FleetClients.shared.client(for: host) else { return }
        let started = generation
        do {
            guard let files = try await client.feedList() else {
                machines[machine] = Served(problem: .unsupported)
                merge()
                return
            }
            guard generation == started else { return }
            var cards: [FeedEntry] = []
            var broken: [String] = []
            for file in files {
                do {
                    cards.append(try FeedCards.entry(file, machine: machine))
                } catch {
                    broken.append("\(host.label): \(file.source)/\(file.id): \(file.error ?? "not a JSON card")")
                }
            }
            machines[machine] = Served(entries: cards, sources: Set(files.map(\.source)), unreadable: broken, served: true)
            for card in cards where card.outcome != nil { outputs[card.id] = nil }
        } catch {
            var kept = machines[machine] ?? Served()
            kept.problem = .failed(error.localizedDescription)
            kept.unreadable = ["\(host.label): couldn't be reached (\(error.localizedDescription))"]
            machines[machine] = kept
        }
        merge()
    }

    /// One timeline out of what the machines served.
    private func merge() {
        let all = machines.values
        entries = FeedCards.newestFirst(all.flatMap(\.entries))
        sources = Set(all.flatMap(\.sources)).sorted().map { Source(id: $0) }
        unreadable = all.flatMap(\.unreadable).sorted()
        // The feed as a whole has a problem only when no machine served one: an old herdr on
        // every machine, or none reachable.
        if all.contains(where: { $0.served }) || all.isEmpty {
            problem = nil
        } else if all.allSatisfy({ $0.problem == .unsupported }) {
            problem = .unsupported
        } else {
            problem = all.compactMap { served -> Problem? in
                if case .failed = served.problem { return served.problem }
                return nil
            }.first
        }
        if !all.isEmpty { loaded = true }
        adoptLegacyMarks()
        if case .feed(let source) = filter, loaded, !sources.contains(where: { $0.id == source }) { filter = .all }
    }

    /// Read and starred marks made when the feed came from one machine name a card
    /// `source/id`. They carry over to the card of that name on whichever machine serves it.
    private func adoptLegacyMarks() {
        var adopted = false
        for entry in entries where entry.machine != nil && !readIDs.contains(entry.id) && readIDs.contains(entry.legacyID) {
            readIDs.insert(entry.id)
            readOrder.append(entry.id)
            adopted = true
        }
        if adopted { UserDefaults.standard.set(readOrder, forKey: "feed.read") }
        var restarred = false
        for (index, star) in starred.enumerated() where star.machine == nil {
            if let now = entries.first(where: { $0.legacyID == star.id }) {
                starred[index] = now
                restarred = true
            }
        }
        if restarred { UserDefaults.standard.set(try? JSONEncoder().encode(starred), forKey: "feed.starred") }
    }

    /// The owner picked `action` (or sent `text`) on `entry`: asks the card's `confirm`
    /// question first, if it has one.
    func choose(_ entry: FeedEntry, _ action: FeedAction?, text: String?) {
        let choice = Choice(entry: entry, action: action, text: text)
        if entry.confirm != nil {
            confirming = choice
        } else {
            Task { await send(choice) }
        }
    }

    /// Sends the answer to the machine that serves the card.
    func send(_ choice: Choice) async {
        let entry = choice.entry
        guard !sending.contains(entry.id) else { return }
        guard let client = FleetClients.shared.client(forMachine: entry.machine) else {
            failure = "The machine this card came from is no longer saved on this phone."
            return
        }
        sending.insert(entry.id)
        defer { sending.remove(entry.id) }
        do {
            let output = try await client.feedAct(source: entry.source, id: entry.cardID,
                                                  action: choice.action?.id, text: choice.text)
            generation += 1
            let next = FeedCards.next(after: entry.id, in: pending)?.id
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index].reply = FeedReply(action: choice.action?.id, text: choice.text, at: Date())
            }
            outputs[entry.id] = output
            setRead([entry], true)
            answered = Answered(id: entry.id, next: next)
        } catch let error as APIError {
            // The reader offers a written reply on every card. A herdr from before that
            // takes text only on a card that asked for it, and says so in these words.
            failure = error.message == "the card takes no text"
                ? "The herdr on the feed machine is too old to take a written reply to this card. Update herdr there, or clear the reply and pick one of the card's choices."
                : error.message
        } catch {
            failure = error.localizedDescription
        }
        await load()
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
                // Keyed by the card: a push that opens a card while another is being read
                // replaces the path's one element, and without the key the reader on screen
                // keeps its state, and so the card it had.
                // ponytail: keyed by the path's element, which the reader's own paging does
                // not change. Opened on A and paged to B, a push for A leaves B on screen;
                // move the paging into the path if that ever matters.
                FeedReaderView(entryID: id).id(id)
            }
        }
        .onChange(of: store.opening, initial: true) { _, card in
            guard let card else { return }
            store.opening = nil
            // A push names the card `source/id`; the timeline names it by its machine too.
            path = [store.entry(id: card)?.id ?? card]
            Task { await store.load() }
        }
        .modifier(FeedAnswerPrompts(shown: path.isEmpty))
        .task { await store.load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await store.load() }
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
                       "The herdr on your machines predates feed cards. Update it from Settings, then come back.")
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
                                    onChoose: { store.choose(entry, $0, text: nil) })
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
        .modifier(NoTopScrollEdgeEffect())
        .refreshable { store.settle(); await store.load() }
    }

    /// Fills its row with the ground, so a pinned header covers the rows passing under it
    /// (the system's own backdrop for it is off: `NoTopScrollEdgeEffect`).
    private func sectionHeader(_ title: String, tint: Color) -> some View {
        Text(verbatim: title)
            .font(Typography.app(13, .semibold))
            .foregroundStyle(tint)
            .textCase(nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ground)
            .listRowInsets(EdgeInsets())
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
                Text("Scripts on your machines publish here. Each JSON file in a folder under this one is a card: something to read, or a question with buttons. Write it to a temporary name and rename it into place, so it's never read half-written.")
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
                CopyableCommand(command: "~/.config/herdr/feeds/<source>/<id>.json")
            }
            .padding(20)
        }
        .refreshable { await store.load() }
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
            Button("Try again") { Task { await store.load() } }
                .font(Typography.app(15, .semibold))
                .padding(.top, 6)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// An answer's `confirm` question and its "Couldn't send" alert. The timeline shows them
/// while no card is open, and an open card's page shows its own: in the split layout (iPad,
/// Mac) what the timeline presents does not appear while a page covers it, so from an open
/// card a failed answer said nothing and a card with a `confirm` question could not be answered.
private struct FeedAnswerPrompts: ViewModifier {
    @ObservedObject private var store = FeedStore.shared
    /// False on the timeline while a card's page is open, so one view presents at a time.
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                store.confirming?.entry.confirm ?? "",
                isPresented: Binding(get: { shown && store.confirming != nil }, set: { if !$0 { store.confirming = nil } }),
                titleVisibility: .visible,
                presenting: store.confirming
            ) { choice in
                Button(choice.action?.label ?? "Send", role: choice.action?.isDestructive == true ? .destructive : nil) {
                    Task { await store.send(choice) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't send",
                   isPresented: Binding(get: { shown && store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: store.failure ?? "")
            }
    }
}

/// Turns off the list's top scroll edge effect, which iOS 26 draws behind a pinned section
/// header. Every section header on screen joins that effect, and on a Mac it is sized to reach
/// the lowest of them, so it blurred every card above that header. The headers carry their
/// own ground instead.
private struct NoTopScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// A card's source and time, as the timeline and the cards set them above the title.
private struct FeedMeta: View {
    let entry: FeedEntry
    var starred = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: ([FeedStore.shared.machineLabel(entry), entry.source].compactMap { $0 }
                .joined(separator: " · ")).uppercased())
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

/// A card waiting for the owner, in "Needs you": its buttons sit on the card. Reply is always
/// one of them and opens the card with the text field, so the owner can answer in their own
/// words when none of the card's choices is the one they want.
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
/// rest quiet, a destructive one in red. Reply, where the caller offers it, comes last.
private struct FeedActionButtons: View {
    let entry: FeedEntry
    let sending: Bool
    let onChoose: (FeedAction) -> Void
    var onReply: (() -> Void)?
    /// Opens the agent to ask about the card (the reader, when there is one to ask).
    var onAsk: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(entry.actions.enumerated()), id: \.element.id) { index, action in
                pill(action.label, primary: index == 0 && !action.isDestructive,
                     destructive: action.isDestructive) { onChoose(action) }
            }
            if let onReply {
                pill("Reply", primary: entry.actions.isEmpty, destructive: false, action: onReply)
            }
            Spacer(minLength: 0)
            if sending { ProgressView().controlSize(.small).tint(Palette.textDim) }
            if let onAsk {
                Button(action: onAsk) {
                    Label("Ask agent", systemImage: "bubble.left.and.text.bubble.right")
                        .font(Typography.app(15, .semibold))
                        .lineLimit(1)
                        .foregroundStyle(Palette.brand)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("feed-ask-agent")
            }
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
/// bar. Opening it marks it read. Once its answer is sent it shows the next card that waits
/// for the owner, or goes back to the timeline when none does.
struct FeedReaderView: View {
    @ObservedObject private var store = FeedStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var entryID: String
    @State private var text = ""
    @FocusState private var typing: Bool
    /// The reading size the owner set for Chat applies to a card too.
    @AppStorage(ChatTextSize.storageKey) private var fontSize = ChatTextSize.defaultPoints
    /// The agent whose page is open over the card, to ask about it.
    @State private var asking: FeedAskTarget?

    init(entryID: String) {
        _entryID = State(initialValue: entryID)
    }

    var body: some View {
        let entry = store.entry(id: entryID)
        // A question pages through the other questions; anything else through the timeline.
        let list = entry?.isPending() == true ? store.pending : store.visible
        let index = list.firstIndex { $0.id == entry?.id }
        Group {
            if let entry {
                ScrollView {
                    article(entry)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(entry.id)
                // On a wide window the card takes the width the owner chose for Chat and Gram
                // (one width for all three), and its edges drag the same way.
                .conversationColumnResizer(.feed)
                .safeAreaInset(edge: .bottom) {
                    if entry.isPending() { answerBar(entry) }
                }
                .environment(\.chatTextScale, CGFloat(fontSize / ChatTextSize.defaultPoints))
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
        .modifier(FeedAnswerPrompts(shown: true))
        // On the page, not on the Feed's stack: in the split layout what is attached to the
        // stack does not present while a card is pushed.
        .fullScreenCover(item: $asking) { FeedAgentPage(target: $0) }
        .onAppear { if let entry { store.setRead([entry], true) } }
        .onChange(of: store.answered) { _, answered in
            guard let answered, answered.id == entry?.id else { return }
            store.answered = nil
            if let next = answered.next.flatMap({ store.entry(id: $0) }) {
                show(next)
            } else {
                dismiss()
            }
        }
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
            .font(Self.titleFont(entry.title))
            .foregroundStyle(Palette.text)
            .padding(.top, 6)
            if let date = entry.date {
                Text(verbatim: date.formatted(date: .long, time: .shortened))
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textFaint)
                    .padding(.top, 4)
            }
            if !entry.body.isEmpty {
                ChatMarkdownView(markdown: entry.body, tone: .article)
                    .padding(.top, 18)
            }
            FeedStatusLine(entry: entry, output: store.outputs[entry.id])
                .padding(.top, 18)
        }
        .textSelection(.enabled)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .conversationColumn(cap: Self.compactWidth, probe: "feed-column")
    }

    /// The most a card takes on a phone. On a wide window the shared conversation column
    /// decides (`conversationColumn`).
    private static let compactWidth: CGFloat = 680

    /// A headline is set large. A title that is a whole question, as a fleet card's is, would
    /// fill the screen in that size, so it steps down with its length and reads as a lead.
    static func titleFont(_ title: String) -> Font {
        switch title.count {
        case ...60: return Typography.app(26, .bold)
        case ...120: return Typography.app(22, .bold)
        default: return Typography.app(19, .semibold)
        }
    }

    /// The text field over the card's buttons. Send answers with the text alone, whatever
    /// buttons the card has: the owner is never made to pick a choice they do not want in
    /// order to say something else. A button sends the text along with it.
    private func answerBar(_ entry: FeedEntry) -> some View {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = store.sending.contains(entry.id)
        let placeholder = entry.input.flatMap { $0.isEmpty ? nil : $0 } ?? "Reply"
        let ask: (() -> Void)? = FeedAskTarget(entry).map { target in
            return {
                typing = false
                asking = target
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .font(Typography.app(16))
                    .foregroundStyle(Palette.text)
                    .focused($typing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("feed-reply-field")
                Button {
                    typing = false
                    store.choose(entry, nil, text: note)
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
            // The row also shows for a card with no buttons when there is an agent to ask.
            if !entry.actions.isEmpty || ask != nil {
                FeedActionButtons(entry: entry, sending: sending, onChoose: { action in
                    typing = false
                    store.choose(entry, action, text: note.isEmpty ? nil : note)
                }, onAsk: ask)
            } else if sending {
                ProgressView().controlSize(.small).tint(Palette.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Under the card, in the same column.
        .conversationColumn(cap: Self.compactWidth)
        .background(Palette.ground)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairlineQuiet).frame(height: 1) }
    }

    private func move(_ list: [FeedEntry], _ index: Int?, _ delta: Int) {
        guard let index, list.indices.contains(index + delta) else { return }
        show(list[index + delta])
    }

    private func show(_ next: FeedEntry) {
        entryID = next.id
        text = ""
        store.setRead([next], true)
    }
}

/// Who a question about a card goes to: the agent that asked it, or, for a card no agent asked
/// (a script's, the fleet's), the orchestrator Gram talks to.
struct FeedAskTarget: Identifiable, Equatable {
    /// `SavedHost.id.uuidString`.
    let machine: String
    /// The agent's herdr session; nil for the machine's default one.
    let session: String?
    /// The asking agent's pane. Nil for the orchestrator, which is found by `name`.
    let paneID: String?
    let name: String
    /// What the reply starts with: names the card for an agent that did not ask it.
    let about: String

    var id: String { [machine, session ?? "", paneID ?? "", name].joined(separator: "|") }

    init?(_ entry: FeedEntry) {
        if let asker = entry.asker, let machine = entry.machine {
            self.machine = machine
            session = asker.session == "default" ? nil : asker.session
            paneID = asker.paneID
            name = asker.agent.isEmpty ? "the agent" : asker.agent
            about = ""
        } else {
            let defaults = UserDefaults.standard
            guard let machine = defaults.string(forKey: OrchestratorPreference.machineKey), !machine.isEmpty else {
                return nil
            }
            self.machine = machine
            session = nil
            paneID = nil
            name = defaults.string(forKey: OrchestratorPreference.agentKey) ?? OrchestratorPreference.defaultAgent
            // The file's name: for a fleet card that is the run the orchestrator tracks.
            about = "About \(entry.legacyID): "
        }
    }
}

/// An agent's own chat page, opened over a card: the owner asks about the card, reads the
/// answer, and goes back to the card to decide. For Claude Code the reply starts as `/btw `,
/// its side question: it is answered without becoming part of the agent's task, so the agent
/// goes on waiting for the card's answer. Nothing is sent until the owner sends it.
private struct FeedAgentPage: View {
    let target: FeedAskTarget
    @Environment(\.dismiss) private var dismiss
    @State private var client: HerdrClient?
    @State private var found: AgentInfo?
    @State private var problem: String?

    var body: some View {
        ZStack {
            Palette.groundMachine.ignoresSafeArea()
            if let client, let found {
                TerminalPaneContent(client: client, paneID: found.paneID, title: found.displayName, agent: found,
                                    draft: (found.agent == "claude" ? "/btw " : "") + target.about,
                                    onClose: { dismiss() })
            } else {
                VStack(spacing: 12) {
                    if let problem {
                        Text(verbatim: problem)
                            .font(Typography.app(15))
                            .foregroundStyle(Palette.textDim)
                            .multilineTextAlignment(.center)
                    } else {
                        ProgressView().tint(Palette.textDim)
                        Text(verbatim: "Looking for \(target.name)")
                            .font(Typography.app(15))
                            .foregroundStyle(Palette.textDim)
                    }
                    Button("Back to the card") { dismiss() }
                        .font(Typography.app(15, .semibold))
                        .padding(.top, 6)
                }
                .padding(24)
            }
        }
        .task { await look() }
    }

    private func look() async {
        guard let machine = FleetClients.shared.client(forMachine: target.machine),
              let client = target.session == nil ? machine : machine.forSession(target.session) else {
            problem = "This device has no connection to the machine \(target.name) runs on."
            return
        }
        do {
            let agents = try await client.agentList()
            let match = agents.first { agent in
                if let pane = target.paneID { return agent.paneID == pane }
                return agent.name == target.name
            }
            guard let agent = match else {
                problem = "\(target.name) is no longer running there."
                return
            }
            self.client = client
            found = agent
        } catch {
            problem = error.localizedDescription
        }
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
