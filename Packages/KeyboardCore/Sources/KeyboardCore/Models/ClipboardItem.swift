import Foundation

public struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var createdAt: Date
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.isPinned = isPinned
    }
}

public final class ClipboardStore {
    private let fileURL: URL
    private let maxUnpinnedItems: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedEntries: [ClipboardEntry] = []

    public static let maxStoredTextBytes = 32 * 1024
    public static let maxPinnedItems = 50

    private var pinnedCount: Int {
        cachedEntries.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
    }

    public init(fileURL: URL, maxUnpinnedItems: Int = 25) {
        self.fileURL = fileURL
        self.maxUnpinnedItems = maxUnpinnedItems
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.cachedEntries = loadFromDisk()
    }

    public func reload() {
        cachedEntries = loadFromDisk()
    }

    public func allEntries(retentionMinutes: Int, now: Date = Date()) -> [ClipboardEntry] {
        let pruned = pruneExpired(entries: cachedEntries, retentionMinutes: retentionMinutes, now: now)
        if pruned.count != cachedEntries.count {
            cachedEntries = pruned
            saveToDisk()
        }
        return sortEntries(cachedEntries)
    }

    public func pinnedEntries() -> [ClipboardEntry] {
        sortEntries(cachedEntries.filter { $0.isPinned })
    }

    public func recentUnpinnedEntries(retentionMinutes: Int, now: Date = Date()) -> [ClipboardEntry] {
        allEntries(retentionMinutes: retentionMinutes, now: now).filter { !$0.isPinned }
    }

    @discardableResult
    public func recordCopiedText(
        _ rawText: String,
        retentionMinutes: Int = 60,
        now: Date = Date()
    ) -> ClipboardEntry? {
        // The whole history is decoded into the extension's memory every time the keyboard opens,
        // so one huge copy (a log file, a book chapter) could push it toward the jetsam limit.
        guard rawText.utf8.count <= Self.maxStoredTextBytes else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        cachedEntries = pruneExpired(entries: cachedEntries, retentionMinutes: retentionMinutes, now: now)

        if let existingIndex = cachedEntries.firstIndex(where: { $0.text == rawText }) {
            var updated = cachedEntries[existingIndex]
            updated.createdAt = now
            cachedEntries[existingIndex] = updated
            saveToDisk()
            return updated
        }

        let newEntry = ClipboardEntry(text: rawText, createdAt: now, isPinned: false)
        cachedEntries.insert(newEntry, at: 0)
        enforceUnpinnedLimit()
        saveToDisk()
        return newEntry
    }

    @discardableResult
    public func addPinnedSnippet(_ rawText: String, now: Date = Date()) -> ClipboardEntry? {
        guard rawText.utf8.count <= Self.maxStoredTextBytes else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let existingIndex = cachedEntries.firstIndex(where: { $0.text == rawText }) {
            guard cachedEntries[existingIndex].isPinned || pinnedCount < Self.maxPinnedItems else { return nil }
            cachedEntries[existingIndex].isPinned = true
            cachedEntries[existingIndex].createdAt = now
            saveToDisk()
            return cachedEntries[existingIndex]
        }

        guard pinnedCount < Self.maxPinnedItems else { return nil }
        let entry = ClipboardEntry(text: rawText, createdAt: now, isPinned: true)
        cachedEntries.insert(entry, at: 0)
        saveToDisk()
        return entry
    }

    public func togglePin(entryID: UUID) {
        guard let index = cachedEntries.firstIndex(where: { $0.id == entryID }) else { return }
        guard cachedEntries[index].isPinned || pinnedCount < Self.maxPinnedItems else { return }
        cachedEntries[index].isPinned.toggle()
        enforceUnpinnedLimit()
        saveToDisk()
    }

    public func delete(entryID: UUID) {
        cachedEntries.removeAll { $0.id == entryID }
        saveToDisk()
    }

    public func clearUnpinned() {
        cachedEntries.removeAll { !$0.isPinned }
        saveToDisk()
    }

    private func pruneExpired(
        entries: [ClipboardEntry],
        retentionMinutes: Int,
        now: Date
    ) -> [ClipboardEntry] {
        guard retentionMinutes > 0 else { return entries }
        let cutoff = now.addingTimeInterval(-Double(retentionMinutes) * 60.0)
        return entries.filter { entry in
            entry.isPinned || entry.createdAt >= cutoff
        }
    }

    private func enforceUnpinnedLimit() {
        let pinned = cachedEntries.filter { $0.isPinned }
        let unpinned = cachedEntries
            .filter { !$0.isPinned }
            .sorted { $0.createdAt > $1.createdAt }
        cachedEntries = pinned + Array(unpinned.prefix(maxUnpinnedItems))
    }

    private func sortEntries(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        entries.sorted { left, right in
            if left.isPinned != right.isPinned {
                return left.isPinned
            }
            return left.createdAt > right.createdAt
        }
    }

    private func loadFromDisk() -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        return (try? decoder.decode([ClipboardEntry].self, from: data)) ?? []
    }

    private func saveToDisk() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(cachedEntries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
