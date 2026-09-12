import Combine
import Foundation
import SwiftUI

@MainActor
final class AppDataStore: ObservableObject {
    @Published var settings: AppSettings { didSet { persist() } }
    @Published private(set) var history: [TranscriptEntry] { didSet { persist() } }
    @Published private(set) var vocabulary: [VocabularyEntry] { didSet { persist() } }
    @Published private(set) var snippets: [Snippet] { didSet { persist() } }
    @Published var scratchpad: String { didSet { persist() } }
    @Published var onboardingComplete: Bool { didSet { persist() } }

    private struct PersistedState: Codable {
        var settings = AppSettings()
        var history: [TranscriptEntry] = []
        var vocabulary: [VocabularyEntry] = []
        var snippets: [Snippet] = []
        var scratchpad = ""
        var onboardingComplete = false
    }

    private let defaults: UserDefaults
    private let persistenceKey = "WhisperType.State.v2"
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let state: PersistedState
        if let data = defaults.data(forKey: persistenceKey),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = PersistedState()
        }
        settings = state.settings
        history = state.history
        vocabulary = state.vocabulary
        snippets = state.snippets
        scratchpad = state.scratchpad
        onboardingComplete = state.onboardingComplete
        isLoading = false
    }

    var totalWords: Int { history.reduce(0) { $0 + $1.wordCount } }
    var totalMinutes: Double { history.reduce(0) { $0 + $1.duration } / 60 }
    var averageWordsPerMinute: Int {
        guard totalMinutes > 0.05 else { return 0 }
        return Int((Double(totalWords) / totalMinutes).rounded())
    }
    var lastTranscript: TranscriptEntry? { history.first }

    var currentStreak: Int {
        let calendar = Calendar.current
        let days = Set(history.map { calendar.startOfDay(for: $0.createdAt) })
        guard !days.isEmpty else { return 0 }
        var cursor = calendar.startOfDay(for: Date())
        if !days.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor), days.contains(yesterday) {
            cursor = yesterday
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    func addTranscript(_ entry: TranscriptEntry) {
        history.insert(entry, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    func deleteTranscripts(at offsets: IndexSet) { history.remove(atOffsets: offsets) }
    func deleteTranscript(id: UUID) { history.removeAll { $0.id == id } }
    func clearHistory() { history.removeAll() }

    func addVocabulary(spoken: String, replacement: String? = nil) {
        let clean = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let index = vocabulary.firstIndex(where: { $0.spoken.caseInsensitiveCompare(clean) == .orderedSame }) {
            vocabulary[index].replacement = replacement?.nilIfBlank
        } else {
            vocabulary.insert(VocabularyEntry(spoken: clean, replacement: replacement?.nilIfBlank), at: 0)
        }
    }

    func updateVocabulary(_ entry: VocabularyEntry) {
        guard let index = vocabulary.firstIndex(where: { $0.id == entry.id }) else { return }
        vocabulary[index] = entry
    }

    func deleteVocabulary(at offsets: IndexSet) { vocabulary.remove(atOffsets: offsets) }
    func deleteVocabulary(id: UUID) { vocabulary.removeAll { $0.id == id } }

    func addSnippet(trigger: String, expansion: String) {
        let cleanTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTrigger.isEmpty, !expansion.isEmpty else { return }
        if let index = snippets.firstIndex(where: { $0.trigger.caseInsensitiveCompare(cleanTrigger) == .orderedSame }) {
            snippets[index].expansion = expansion
            snippets[index].updatedAt = Date()
        } else {
            snippets.insert(Snippet(trigger: cleanTrigger, expansion: expansion), at: 0)
        }
    }

    func updateSnippet(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.updatedAt = Date()
        snippets[index] = updated
    }

    func deleteSnippets(at offsets: IndexSet) { snippets.remove(atOffsets: offsets) }
    func deleteSnippet(id: UUID) { snippets.removeAll { $0.id == id } }

    func exportData() throws -> Data {
        try JSONEncoder.pretty.encode(currentState)
    }

    func importData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedState.self, from: data)
        settings = decoded.settings
        history = decoded.history
        vocabulary = decoded.vocabulary
        snippets = decoded.snippets
        scratchpad = decoded.scratchpad
        onboardingComplete = decoded.onboardingComplete
    }

    private var currentState: PersistedState {
        PersistedState(
            settings: settings,
            history: history,
            vocabulary: vocabulary,
            snippets: snippets,
            scratchpad: scratchpad,
            onboardingComplete: onboardingComplete
        )
    }

    private func persist() {
        guard !isLoading, let encoded = try? JSONEncoder().encode(currentState) else { return }
        defaults.set(encoded, forKey: persistenceKey)
    }
}

private extension String {
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
