import SwiftUI
import WidgetKit

/// The widget extension's entry point: the agent-session Live Activity (Dynamic Island +
/// lock-screen banner) and the home-screen widget (small and medium).
@main
struct HerdrWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
        HerdWidget()
    }
}
