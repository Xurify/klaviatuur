import SwiftUI
import UIKit

struct SetupGuideView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var sandboxText: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(
                            systemName: viewModel.isKeyboardEnabledInSystem
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle.fill"
                        )
                        .font(.title2)
                        .foregroundStyle(viewModel.isKeyboardEnabledInSystem ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                viewModel.isKeyboardEnabledInSystem
                                    ? "Klaviatuur is enabled"
                                    : "Enable Klaviatuur in iOS Settings"
                            )
                            .font(.headline)
                            Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Klaviatuur")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settingsURL)
                        }
                    } label: {
                        Label("Open Klaviatuur Settings", systemImage: "gear")
                    }
                } header: {
                    Text("Installation")
                } footer: {
                    Text("Turn on Allow Full Access so Klaviatuur can share your languages, clipboard snippets, and haptic settings with the keyboard extension.")
                }

                Section {
                    TextEditor(text: $sandboxText)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if sandboxText.isEmpty {
                                Text("Tap here to test Klaviatuur in English, Slovak, Czech, Estonian, and Russian...")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                    if !sandboxText.isEmpty {
                        Button("Clear test text", role: .destructive) {
                            sandboxText = ""
                        }
                    }
                } header: {
                    Text("Keyboard Sandbox")
                } footer: {
                    Text("Try typing \"dakujem\", \"prilis\", \"tanan\", or \"teh\" without switching languages. Tap Globe or hold Spacebar to switch to Russian Cyrillic.")
                }
            }
            .navigationTitle("Klaviatuur")
        }
    }
}
