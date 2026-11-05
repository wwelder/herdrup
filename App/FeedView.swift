import HerdrKit
import SwiftUI

/// The feed's state, shared by the tab and the iPad sidebar: what the machine serves, and the
/// owner's read and starred marks, which stay on the phone. A singleton like `PushCenter`, so
/// it outlives the home view's per-session remount.
@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()

    enum Filter: Hashable { case all, starred, feed(String) }

    /// One feed file on the machine, or why it could not be read.
    struct Source: Identifiable, Hashable {
        let id: String
        let title: String
        var problem: String?
    }

    enum Problem: Equatable { case unsupported, failed(String) }

    @Published private(set) var entries: [FeedEntry] = []
    @Published private(set) var sources: [Source] = []
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

    // ponytail: the newest 3000 read marks; older ones fall off and would show unread again.
    private static let readCap = 3000
    private var readOrder: [String]

    private init() {
        let defaults = UserDefaults.standard
        readOrder = defaults.stringArray(forKey: "feed.read") ?? []
        readIDs = Set(readOrder)
        starred = defaults.data(forKey: "feed.starred")
            .flatMap { try? JSONDecoder().decode([FeedEntry].self, from: $0) } ?? []
    }

    /// The timeline the filter picks, newest first. Starred items are kept whole on the phone,
    /// so they outlive the feed dropping them; while still served, the served copy shows.
    var visible: [FeedEntry] {
        switch filter {
        case .all, .feed:
            return showRead ? picked : picked.filter { !readIDs.contains($0.id) || readSinceSettled.contains($0.id) }
        case .starred:
            let served = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return Self.newestFirst(starred.map { served[$0.id] ?? $0 })
        }
    }

    /// How many read items the unread timeline leaves out.
    var hiddenReadCount: Int {
        guard !showRead, filter != .starred else { return 0 }
        return picked.count - visible.count
    }

    /// The served entries the filter picks, read or not.
    private var picked: [FeedEntry] {
        if case .feed(let file) = filter { return entries.filter { $0.feed == file } }
        return entries
    }

    /// Drops what was read from the unread timeline.
    func settle() { readSinceSettled = [] }

    var title: String {
        switch filter {
        case .all: return "Feed"
        case .starred: return "Starred"
        case .feed(let file): return sources.first { $0.id == file }?.title ?? "Feed"
        }
    }

    func entry(id: String) -> FeedEntry? {
        entries.first { $0.id == id } ?? starred.first { $0.id == id }
    }

    func load(_ client: HerdrClient) async {
        guard !loading else { return }
        loading = true
        defer { loading = false; loaded = true }
        do {
            guard let files = try await client.feedList() else {
                entries = []; sources = []; problem = .unsupported
                return
            }
            var all: [FeedEntry] = []
            var found: [Source] = []
            for file in files {
                let stem = (file.name as NSString).deletingPathExtension
                guard let xml = file.xml else {
                    found.append(Source(id: file.name, title: stem, problem: file.error ?? "Couldn't be read"))
                    continue
                }
                do {
                    let channel = try FeedParser.parse(xml, file: file.name)
                    all += channel.entries
                    found.append(Source(id: file.name, title: channel.title))
                } catch {
                    found.append(Source(id: file.name, title: stem, problem: "Not an RSS or Atom feed"))
                }
            }
            entries = Self.newestFirst(all)
            sources = found
            problem = nil
            if case .feed(let file) = filter, !found.contains(where: { $0.id == file }) { filter = .all }
        } catch {
            problem = .failed(error.localizedDescription)
        }
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

    private static func newestFirst(_ entries: [FeedEntry]) -> [FeedEntry] {
        entries.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// The Feed tab: one timeline of every feed on the machine, newest first and grouped by day,
/// in the manner of Reeder. A dot marks what is unread; swipe right to toggle read, left to
/// star. The title is the timeline picker (all, starred, one feed).
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
                FeedReaderView(entryID: id)
            }
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
                       "This machine's herdr predates feeds. Update it from Settings, then come back.")
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
        let entries = store.visible
        return List {
            ForEach(days(entries), id: \.day) { day in
                Section {
                    ForEach(day.entries) { entry in row(entry) }
                } header: {
                    Text(verbatim: day.day)
                        .font(Typography.app(13, .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .textCase(nil)
                }
            }
            if entries.isEmpty {
                Text(store.filter == .starred ? "Star an item to keep it here."
                     : store.hiddenReadCount > 0 ? "All caught up." : "Nothing here yet.")
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
            ForEach(store.sources.filter { $0.problem != nil }) { source in
                Label {
                    Text(verbatim: "\(source.id): \(source.problem ?? "")")
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

    private func row(_ entry: FeedEntry) -> some View {
        let read = store.isRead(entry)
        let starred = store.isStarred(entry)
        return Button { path.append(entry.id) } label: {
            FeedRow(entry: entry, read: read, starred: starred)
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
                Text("No feeds yet")
                    .font(Typography.app(20, .semibold))
                    .foregroundStyle(Palette.text)
                Text("Scripts on this machine publish here: each RSS or Atom file in this folder is a feed. Write it to a temporary name and rename it into place, so it's never read half-written.")
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
                CopyableCommand(command: "~/.config/herdr/feeds/")
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

/// A timeline row: the feed and time over the title and the first lines of the content.
private struct FeedRow: View {
    let entry: FeedEntry
    let read: Bool
    let starred: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(read ? Color.clear : Palette.brand)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.feedTitle.uppercased())
                        .font(Typography.app(11, .semibold))
                        .kerning(0.6)
                        .lineLimit(1)
                    if let date = entry.date {
                        Text(verbatim: date.formatted(date: .omitted, time: .shortened))
                            .font(Typography.app(12))
                    }
                    Spacer(minLength: 0)
                    if starred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.waiting)
                    }
                }
                .foregroundStyle(Palette.textFaint)
                Text(verbatim: entry.title)
                    .font(Typography.app(17, .semibold))
                    .foregroundStyle(read ? Palette.textDim : Palette.text)
                    .lineLimit(3)
                if !entry.excerpt.isEmpty, entry.excerpt != entry.title {
                    Text(verbatim: entry.excerpt)
                        .font(Typography.app(15))
                        .foregroundStyle(read ? Palette.textFaint : Palette.textDim)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(read ? "" : "Unread")
    }
}

/// One item, full screen: the article in a web view (script off, nothing loaded from the
/// network, links open in the browser), with star and up/down to the neighbouring items
/// of the same timeline in the bottom bar. Opening it marks it read.
struct FeedReaderView: View {
    @ObservedObject private var store = FeedStore.shared
    @State private var entryID: String

    init(entryID: String) { _entryID = State(initialValue: entryID) }

    var body: some View {
        let list = store.visible
        let index = list.firstIndex { $0.id == entryID }
        let entry = index.map { list[$0] } ?? store.entry(id: entryID)
        Group {
            if let entry {
                HtmlWebView(html: FeedArticle.document(entry), opensLinks: true,
                            background: UIColor(Palette.ground))
                    .id(entry.id)
            } else {
                Text("This item is no longer in the feed.")
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

    private func move(_ list: [FeedEntry], _ index: Int?, _ delta: Int) {
        guard let index, list.indices.contains(index + delta) else { return }
        let next = list[index + delta]
        entryID = next.id
        store.setRead([next], true)
    }
}

/// The reader's page: the feed, title and date above the item's own HTML (or its plain text),
/// set in the app's dark palette.
enum FeedArticle {
    static func document(_ entry: FeedEntry) -> String {
        let body = FeedText.looksLikeHTML(entry.content)
            ? entry.content
            : "<div class=plain>\(escape(entry.content))</div>"
        let meta = [entry.date.map { $0.formatted(date: .long, time: .shortened) }, entry.author]
            .compactMap { $0 }.joined(separator: " · ")
        let title = entry.link.map { "<a href=\"\(escape($0.absoluteString))\">\(escape(entry.title))</a>" }
            ?? escape(entry.title)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>\(css)</style></head><body><article>
        <div class="feed">\(escape(entry.feedTitle))</div>
        <h1 class="title">\(title)</h1>
        <div class="meta">\(escape(meta))</div>
        <div class="content">\(body)</div>
        </article></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }

    private static var css: String {
        typealias Dark = DesignTokens.Color.Dark
        let size = 17 * Typography.scale
        return """
        :root{color-scheme:dark}
        html{-webkit-text-size-adjust:100%}
        body{margin:0;background:\(hex(Dark.ground));color:\(hex(Dark.text));
          font:\(size)px/1.6 -apple-system,system-ui,sans-serif;overflow-wrap:break-word}
        article{max-width:38em;margin:0 auto;padding:12px 20px 48px}
        .feed{font-size:.72em;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:\(hex(Dark.textDim))}
        h1.title{font-size:1.65em;line-height:1.2;font-weight:700;margin:.3em 0 .3em}
        h1.title a{color:inherit;text-decoration:none}
        .meta{font-size:.82em;color:\(hex(Dark.textFaint));margin-bottom:1.6em}
        .content h1,.content h2,.content h3,.content h4{line-height:1.25;margin:1.4em 0 .5em}
        .content h1{font-size:1.35em}.content h2{font-size:1.2em}.content h3{font-size:1.05em}
        p{margin:0 0 1em} ul,ol{padding-left:1.3em} li{margin:.3em 0}
        a{color:\(hex(Dark.brand))}
        img,video{max-width:100%;height:auto;border-radius:10px}
        blockquote{margin:1em 0;padding:.1em 0 .1em 1em;border-left:3px solid \(hex(Dark.hairline));color:\(hex(Dark.textDim))}
        code,pre{font-family:ui-monospace,Menlo,monospace;font-size:.85em}
        code{background:\(hex(Dark.surface));padding:.1em .35em;border-radius:5px}
        pre{background:\(hex(Dark.groundMachine));border:1px solid \(hex(Dark.hairline));padding:12px 14px;border-radius:10px;overflow-x:auto;line-height:1.45}
        pre code{background:none;padding:0}
        hr{border:0;border-top:1px solid \(hex(Dark.hairline));margin:2em 0}
        table{border-collapse:collapse;width:100%;font-size:.9em;margin:1em 0}
        th,td{border-bottom:1px solid \(hex(Dark.hairlineQuiet));padding:6px 8px;text-align:left;vertical-align:top}
        th{color:\(hex(Dark.textDim));font-weight:600}
        .plain{white-space:pre-wrap}
        """
    }
}

/// The iPad sidebar's timelines: All, Starred and each feed. Selecting one sets the filter the
/// Feed page in the detail column reads.
struct FeedTimelineList: View {
    @ObservedObject private var store = FeedStore.shared

    var body: some View {
        VStack(spacing: 2) {
            item(.all, "All", icon: "tray.full")
            item(.starred, "Starred", icon: "star")
            ForEach(store.sources) { source in
                item(.feed(source.id), source.title, icon: "dot.radiowaves.up.forward")
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
