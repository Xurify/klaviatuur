import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            SetupGuideView()
                .tabItem {
                    Label("Setup", systemImage: "keyboard")
                }

            LanguagesSettingsView()
                .tabItem {
                    Label("Languages", systemImage: "globe")
                }

            ClipboardManagerView()
                .tabItem {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                }

            PreferencesView()
                .tabItem {
                    Label("Preferences", systemImage: "slider.horizontal.3")
                }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                viewModel.refreshAll()
            }
        }
    }
}
