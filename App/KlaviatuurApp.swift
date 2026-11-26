import SwiftUI

@main
struct KlaviatuurApp: App {
    @StateObject private var viewModel = SettingsViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
