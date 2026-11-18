import HerdrKit
import SwiftUI

/// Connections to saved machines that do not depend on which machine is open in Agents. Gram
/// talks to the orchestrator's machine over one, and the Feed reads every machine over them.
/// A connection is made on first use and again after a drop (`CitadelTransport` does both).
// ponytail: one SSH connection per saved machine, and a second one to the machine that is open
// in Agents. Share the home's transport for that machine if the extra connection ever matters.
// A machine whose key is replaced in place keeps its old connection until the app restarts.
@MainActor
final class FleetClients {
    static let shared = FleetClients()

    private var live: [UUID: (host: SavedHost, client: HerdrClient)] = [:]

    /// A client for the machine's default herdr session, or nil when this phone holds no key
    /// or password for it.
    func client(for host: SavedHost) -> HerdrClient? {
        #if DEBUG
        // A mock run (UI tests, screenshots) must not dial the machines saved on the device.
        if ScreenshotMock.mode != nil { return nil }
        #endif
        if let held = live[host.id], held.host == host { return held.client }
        guard let credentials = SavedHostsStore.shared.credentials(for: host) else { return nil }
        let transport = CitadelTransport(credentials: credentials, hostKeyPolicy: KeychainHostKeyPolicy.shared)
        let client = HerdrClient(transport: transport)
        live[host.id] = (host, client)
        return client
    }

    /// The same, by the id a feed card carries (`FeedEntry.machine`).
    func client(forMachine id: String?) -> HerdrClient? {
        guard let id, let host = SavedHostsStore.shared.hosts.first(where: { $0.id.uuidString == id }) else { return nil }
        return client(for: host)
    }
}

/// Where Gram finds the orchestrator: a saved machine and the agent's herdr name there.
enum OrchestratorPreference {
    /// `SavedHost.id.uuidString`; "" until the owner picks a machine.
    static let machineKey = "gram.orchestratorMachine"
    static let agentKey = "gram.orchestratorAgent"
    static let defaultAgent = "orchestrator"
}

/// Gram: one conversation with the orchestrator, the long-lived agent that tracks the work on
/// every machine. It is the agent's own chat page (the transcript, the composer that sends
/// straight into its session, the terminal behind the switch), reached over a connection of
/// its own, so it is the same whichever machine is open in Agents.
struct GramTab: View {
    /// Whether the tab is on screen: the page holds the keyboard and the pane's width only then.
    let isActive: Bool
    @ObservedObject private var saved = SavedHostsStore.shared
    @AppStorage(OrchestratorPreference.machineKey) private var machineID = ""
    @AppStorage(OrchestratorPreference.agentKey) private var agentName = OrchestratorPreference.defaultAgent
    @State private var found: AgentInfo?
    @State private var problem: String?

    private var machine: SavedHost? { saved.hosts.first { $0.id.uuidString == machineID } }

    var body: some View {
        ZStack {
            Palette.groundMachine.ignoresSafeArea()
            if let machine, let client = FleetClients.shared.client(for: machine) {
                if let found {
                    TerminalPaneContent(client: client, paneID: found.paneID, title: found.name ?? agentName,
                                        agent: found, isForeground: isActive,
                                        // The pane went away: look for the orchestrator again.
                                        onClose: { self.found = nil }, embedded: true)
                        .id(machineID + "/" + found.paneID)
                } else {
                    looking(machine)
                }
            } else {
                ScrollView { GramMachinePicker().padding(20) }
            }
        }
        .onChange(of: machineID) { _, _ in found = nil; problem = nil }
        .onChange(of: agentName) { _, _ in found = nil; problem = nil }
        .task(id: "\(machineID)/\(agentName)/\(isActive)") { await follow() }
    }

    /// Finds the orchestrator's pane by its agent name, and keeps finding it: an orchestrator
    /// that was restarted comes back in another pane.
    // ponytail: looks in the machine's default herdr session only.
    private func follow() async {
        guard isActive, let machine, let client = FleetClients.shared.client(for: machine) else { return }
        while !Task.isCancelled {
            do {
                let match = try await client.agentList().first { $0.name == agentName }
                if match?.paneID != found?.paneID { found = match }
                problem = match == nil ? "No agent named “\(agentName)” is running on \(machine.label)." : nil
            } catch {
                if found == nil { problem = error.localizedDescription }
            }
            try? await Task.sleep(nanoseconds: (found == nil ? 5 : 30) * 1_000_000_000)
        }
    }

    private func looking(_ machine: SavedHost) -> some View {
        VStack(spacing: 12) {
            if let problem {
                Text(verbatim: problem)
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
                    .multilineTextAlignment(.center)
                Text("Gram keeps looking. Start the agent there, or pick another machine.")
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textFaint)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView().tint(Palette.textDim)
                Text(verbatim: "Looking for \(agentName) on \(machine.label)")
                    .font(Typography.app(15))
                    .foregroundStyle(Palette.textDim)
            }
            Button("Pick another machine") { machineID = "" }
                .font(Typography.app(15, .semibold))
                .padding(.top, 6)
                .accessibilityIdentifier("gram-change-machine")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Gram's first-run question, also shown when its machine is no longer saved: which machine
/// the orchestrator runs on.
struct GramMachinePicker: View {
    @ObservedObject private var saved = SavedHostsStore.shared
    @AppStorage(OrchestratorPreference.machineKey) private var machineID = ""
    @AppStorage(OrchestratorPreference.agentKey) private var agentName = OrchestratorPreference.defaultAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gram")
                .font(Typography.app(28, .bold))
                .foregroundStyle(Palette.text)
            Text("One conversation with your orchestrator, the agent that tracks the work on all your machines. Which machine does it run on?")
                .font(Typography.app(15))
                .foregroundStyle(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(saved.hosts) { host in
                    Button {
                        machineID = host.id.uuidString
                    } label: {
                        HStack {
                            Text(verbatim: host.label).font(Typography.app(17)).foregroundStyle(Palette.text)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Palette.textFaint)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("gram-machine-\(host.label)")
                    if host.id != saved.hosts.last?.id {
                        Rectangle().fill(Palette.hairlineQuiet).frame(height: 1).padding(.leading, 18)
                    }
                }
            }
            // The Settings group look (`settingsGroup`, private to HerdrApp.swift).
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.hairlineQuiet, lineWidth: 1))
            Text(verbatim: "Gram talks to the agent named “\(agentName)” there. If the machine is not listed, add it in Settings → Machines.")
                .font(Typography.app(12))
                .foregroundStyle(Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
