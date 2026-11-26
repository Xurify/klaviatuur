import SwiftUI
import KeyboardCore

struct LanguagesSettingsView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(
                        "Simultaneous Multilingual Typing",
                        isOn: $viewModel.settings.simultaneousMultilingual
                    )

                    Picker("Latin Layout", selection: $viewModel.settings.latinVariant) {
                        ForEach(LatinLayoutVariant.allCases, id: \.self) { variant in
                            Text(variant.displayName).tag(variant)
                        }
                    }
                } header: {
                    Text("Multilingual Mode")
                } footer: {
                    Text("When enabled, all active Latin languages (English, Slovak, Czech, Estonian) run simultaneously with zero 3-language cap. Switch to Cyrillic with Globe or long-pressing Spacebar.")
                }

                Section {
                    ForEach(LanguageCode.allCases) { language in
                        let isEnabled = viewModel.settings.enabledLanguages.contains(language)
                        Button {
                            viewModel.toggleLanguage(language)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language.profile.displayName)
                                        .foregroundStyle(.primary)
                                    Text("\(language.profile.nativeName) · \(language.profile.script.displayName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isEnabled {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Available Languages (\(viewModel.settings.enabledLanguages.count) active)")
                } footer: {
                    Text("Each dictionary uses a compact memory-mapped binary trie (.kdict), keeping RAM well under iOS's keyboard extension limit even with 5+ languages active.")
                }
            }
            .navigationTitle("Languages")
        }
    }
}
