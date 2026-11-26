import SwiftUI
import KeyboardCore

struct PreferencesView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Keyboard Theme", selection: $viewModel.settings.themeStyle) {
                        ForEach(KeyboardThemeStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                }

                Section("Pixel Layout") {
                    Toggle("Dedicated Number Row", isOn: $viewModel.settings.showNumberRow)
                    Toggle("Long-Press Symbol Hints", isOn: $viewModel.settings.showLongPressHints)
                    Toggle("Key Press Popups", isOn: $viewModel.settings.enableKeyPopups)
                    Toggle("Haptic Feedback", isOn: $viewModel.settings.enableHaptics)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Long-Press Delay")
                            Spacer()
                            Text("\(viewModel.settings.longPressDelayMilliseconds) ms")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.settings.longPressDelayMilliseconds) },
                                set: { viewModel.settings.longPressDelayMilliseconds = Int($0.rounded()) }
                            ),
                            in: 180...450,
                            step: 10
                        )
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Keyboard Height")
                            Spacer()
                            Text("\(Int((viewModel.settings.keyboardHeightScale * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $viewModel.settings.keyboardHeightScale,
                            in: 0.85...1.20,
                            step: 0.05
                        )
                    }
                }

                Section("Typing Intelligence") {
                    Toggle("Autocorrect & Diacritic Restoration", isOn: $viewModel.settings.enableAutocorrect)
                    Toggle("Probabilistic Key Hitboxes", isOn: $viewModel.settings.enableProbabilisticHitboxes)
                    Toggle("Auto-Capitalization", isOn: $viewModel.settings.enableAutoCapitalization)
                    Toggle("Double-Space Period", isOn: $viewModel.settings.enableDoubleSpacePeriod)
                }

                Section {
                    Toggle("Capture Clipboard History", isOn: $viewModel.settings.enableClipboardHistory)
                    Picker("Recent Item Expiry", selection: $viewModel.settings.clipboardRetentionMinutes) {
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("4 hours").tag(240)
                        Text("24 hours").tag(1440)
                    }
                } header: {
                    Text("Clipboard")
                } footer: {
                    Text("Clipboard history and haptic feedback need Full Access: Settings › General › Keyboard › Keyboards › Klaviatuur › Allow Full Access.")
                }
            }
            .navigationTitle("Preferences")
        }
    }
}
