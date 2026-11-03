import SwiftUI
import WidgetKit

/// The home-screen widget, small (2x2) and medium (4x2): host APM, running and blocked
/// counts, Claude and Codex usage left, and the agent waiting on the owner with its
/// question. A tap opens that agent to answer it, or the app when nobody is waiting.
///
/// It shows the last `WidgetSnapshot` the app or the notification service saved; a widget
/// cannot reach the machine itself. Both reload the timeline when they save.
struct HerdWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HerdWidget", provider: Provider()) { entry in
            HerdWidgetView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { WidgetPalette.cardGradient }
        }
        .configurationDisplayName("Herd")
        .description("APM, usage left, and the agent waiting on you.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    struct Entry: TimelineEntry {
        let date: Date
        let snapshot: WidgetSnapshot?
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .sample) }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry(date: .now, snapshot: context.isPreview ? .sample : WidgetSnapshot.load()))
        }

        /// Nothing changes on a clock here: the app and the notification service reload it.
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: .now, snapshot: WidgetSnapshot.load())], policy: .never))
        }
    }
}

private struct HerdWidgetView: View {
    let snapshot: WidgetSnapshot?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot {
                if family == .systemMedium {
                    HStack(alignment: .top, spacing: 14) {
                        Metrics(snapshot: snapshot).frame(width: 118, alignment: .leading)
                        Group {
                            if let ask = snapshot.ask { AskCard(ask: ask, lines: 4) } else { Quiet(snapshot: snapshot) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else if let ask = snapshot.ask {
                    VStack(alignment: .leading, spacing: 6) {
                        AskCard(ask: ask, lines: 3)
                        Spacer(minLength: 0)
                        ApmLine(snapshot: snapshot)
                    }
                } else {
                    Metrics(snapshot: snapshot)
                }
            } else {
                Text("Open herdrup to connect a machine.")
                    .font(WidgetFont.geist(13))
                    .foregroundStyle(WidgetPalette.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(snapshot?.tapURL ?? AgentActivityDeepLink.url(agentID: nil))
    }
}

/// APM large, running and blocked, then each provider's usage left.
private struct Metrics: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("APM").font(WidgetFont.plexMedium(10)).foregroundStyle(WidgetPalette.textFaint)
            Text(snapshot.apmText ?? "–")
                .font(WidgetFont.plexSemiBold(28))
                .foregroundStyle(snapshot.blocked > 0 ? WidgetPalette.waiting : WidgetPalette.text)
            HStack(spacing: 10) {
                Count(value: snapshot.running, label: "run", color: WidgetPalette.working)
                Count(value: snapshot.blocked, label: "blocked", color: WidgetPalette.waiting)
            }
            Spacer(minLength: 6)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(snapshot.usage, id: \.provider) { UsageRow(usage: $0) }
            }
        }
    }
}

private struct Count: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Text("\(value)").font(WidgetFont.plexSemiBold(12))
                .foregroundStyle(value > 0 ? color : WidgetPalette.textFaint)
            Text(label).font(WidgetFont.geist(11)).foregroundStyle(WidgetPalette.textDim)
        }
    }
}

private struct UsageRow: View {
    let usage: WidgetSnapshot.Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(usage.provider.capitalized).font(WidgetFont.geist(11)).foregroundStyle(WidgetPalette.textDim)
                Spacer(minLength: 2)
                Text("\(Int(usage.remainingPercent.rounded()))%").font(WidgetFont.plexMedium(11))
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(WidgetPalette.textFaint.opacity(0.3))
                    Capsule().fill(tint).frame(width: geo.size.width * usage.remainingPercent / 100)
                }
            }
            .frame(height: 3)
        }
    }

    private var tint: Color {
        usage.remainingPercent < 15 ? WidgetPalette.died
            : usage.remainingPercent < 35 ? WidgetPalette.waiting : WidgetPalette.working
    }
}

/// The waiting agent: who, what it asks, and for how long.
private struct AskCard: View {
    let ask: WidgetSnapshot.Ask
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(WidgetPalette.waiting).frame(width: 7, height: 7)
                Text(ask.agent).font(WidgetFont.geistSemiBold(13)).foregroundStyle(WidgetPalette.text)
                    .lineLimit(1)
            }
            Text(ask.request ?? "Waiting for your answer")
                .font(WidgetFont.geist(12))
                .foregroundStyle(WidgetPalette.textDim)
                .lineLimit(lines)
            (Text("waiting ") + Text(ask.since, style: .relative))
                .font(WidgetFont.plex(10))
                .foregroundStyle(WidgetPalette.waiting)
                .lineLimit(1)
        }
    }
}

/// The medium widget's right side when nobody is waiting.
private struct Quiet: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nobody waiting").font(WidgetFont.geistSemiBold(13)).foregroundStyle(WidgetPalette.text)
            Text(snapshot.host).font(WidgetFont.geist(12)).foregroundStyle(WidgetPalette.textDim).lineLimit(1)
            Spacer(minLength: 0)
            (Text("updated ") + Text(snapshot.updatedAt, style: .relative) + Text(" ago"))
                .font(WidgetFont.plex(10))
                .foregroundStyle(WidgetPalette.textFaint)
                .lineLimit(1)
        }
    }
}

private struct ApmLine: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text("APM \(snapshot.apmText ?? "–")").font(WidgetFont.plexMedium(11))
                .foregroundStyle(WidgetPalette.text)
            Count(value: snapshot.blocked, label: "blocked", color: WidgetPalette.waiting)
        }
    }
}

private extension WidgetSnapshot {
    static let sample = WidgetSnapshot(
        host: "My Mac", apm: 14.6, running: 3, blocked: 1,
        usage: [.init(provider: "claude", remainingPercent: 62, window: "5h", resetsAt: nil),
                .init(provider: "codex", remainingPercent: 28, window: "weekly", resetsAt: nil)],
        ask: .init(agent: "api-refactor", request: "Bash command\ngit push origin main\nDo you want to proceed?",
                   paneID: "w1:p1", session: nil, since: .now.addingTimeInterval(-240)),
        updatedAt: .now)
}
