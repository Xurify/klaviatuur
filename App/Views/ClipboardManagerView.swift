import SwiftUI
import KeyboardCore

struct ClipboardManagerView: View {
    @EnvironmentObject private var viewModel: SettingsViewModel
    @State private var newSnippetText: String = ""

    private var pinnedEntries: [ClipboardEntry] {
        viewModel.clipboardEntries.filter(\.isPinned)
    }

    private var recentEntries: [ClipboardEntry] {
        viewModel.clipboardEntries.filter { !$0.isPinned }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a pinned snippet (email, address, phrase...)", text: $newSnippetText)
                        Button("Pin") {
                            let trimmed = newSnippetText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            viewModel.addPinnedSnippet(trimmed)
                            newSnippetText = ""
                        }
                        .disabled(newSnippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("New Pinned Snippet")
                }

                Section("Pinned Snippets") {
                    if pinnedEntries.isEmpty {
                        Text("No pinned snippets yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pinnedEntries) { entry in
                            clipboardRow(entry)
                        }
                    }
                }

                Section {
                    if recentEntries.isEmpty {
                        Text("Recent clipboard items appear here automatically when copied.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentEntries) { entry in
                            clipboardRow(entry)
                        }
                        Button("Clear Recent History", role: .destructive) {
                            viewModel.clearRecentClipboard()
                        }
                    }
                } header: {
                    Text("Recent (auto-expires after \(viewModel.settings.clipboardRetentionMinutes) min)")
                }
            }
            .navigationTitle("Clipboard")
        }
    }

    private func clipboardRow(_ entry: ClipboardEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.togglePin(entry.id)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                viewModel.deleteClipboardEntry(entry.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
