import Foundation

enum TextProcessingService {
    static func process(
        _ rawText: String,
        settings: AppSettings,
        vocabulary: [VocabularyEntry],
        snippets: [Snippet],
        context: TextContext
    ) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.selectedStyle != .verbatim, settings.autoFormatting {
            text = applySpokenFormatting(text)
            text = applyBacktrack(text)
        }
        if settings.selectedStyle != .verbatim, settings.removeFillers { text = removeFillers(text) }
        text = applyVocabulary(text, entries: vocabulary)
        text = applySnippets(text, snippets: snippets)
        text = normalizeWhitespace(text)

        if settings.selectedStyle != .verbatim, settings.autoFormatting {
            text = capitalizeWhenAppropriate(text, context: context)
        }
        return applyContextSpacing(text, context: context, style: settings.selectedStyle)
    }

    static func vocabularyPrompt(_ entries: [VocabularyEntry]) -> String {
        entries
            .sorted { ($0.isStarred ? 0 : 1, $0.spoken) < ($1.isStarred ? 0 : 1, $1.spoken) }
            .prefix(80)
            .map { $0.replacement ?? $0.spoken }
            .joined(separator: ", ")
    }

    private static func applySpokenFormatting(_ input: String) -> String {
        let replacements: [(String, String)] = [
            (#"(?i)\bnew paragraph\b[,.]?\s*"#, "\n\n"),
            (#"(?i)\bnew line\b[,.]?\s*"#, "\n"),
            (#"(?i)\b(?:bullet point|new bullet)\b[,.]?\s*"#, "\n• "),
            (#"(?i)\bnumbered list\b[,.]?\s*"#, "\n1. "),
            (#"(?i)\bopen parenthesis\b"#, "("),
            (#"(?i)\bclose parenthesis\b"#, ")"),
            (#"(?i)\bopen quote\b"#, "\""),
            (#"(?i)\bclose quote\b"#, "\""),
            (#"(?i)\bquestion mark\b"#, "?"),
            (#"(?i)\bexclamation (?:mark|point)\b"#, "!"),
            (#"(?i)\bsemicolon\b"#, ";"),
            (#"(?i)\bcolon\b"#, ":"),
            (#"(?i)\bcomma\b"#, ","),
            (#"(?i)\bperiod\b"#, ".")
        ]
        return replacements.reduce(input) { value, replacement in
            value.replacingOccurrences(of: replacement.0, with: replacement.1, options: .regularExpression)
        }
    }

    private static func applyBacktrack(_ input: String) -> String {
        let markers = #"(?i)\b(?:scratch that|never mind|correction)\b[,:-]?\s*"#
        guard let regex = try? NSRegularExpression(pattern: markers),
              let match = regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).last,
              let range = Range(match.range, in: input) else { return input }
        let before = String(input[..<range.lowerBound])
        let after = String(input[range.upperBound...])
        guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return before }
        let clauseSeparators = CharacterSet(charactersIn: ".!?;\n")
        if let boundary = before.rangeOfCharacter(from: clauseSeparators, options: .backwards) {
            return String(before[...boundary.lowerBound]) + " " + after
        }
        return after
    }

    private static func removeFillers(_ input: String) -> String {
        var text = input
        let patterns = [
            #"(?i)(?<![\w])(?:um+|uh+|erm+|ah+)(?:,)?\s*"#,
            #"(?i)(?<![\w])you know(?:,)?\s*"#,
            #"(?i)(?<![\w])I mean(?:,)?\s*"#
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    private static func applyVocabulary(_ input: String, entries: [VocabularyEntry]) -> String {
        entries.reduce(input) { text, entry in
            guard let replacement = entry.replacement, !replacement.isEmpty else { return text }
            return replacingWholePhrase(entry.spoken, in: text, with: replacement)
        }
    }

    private static func applySnippets(_ input: String, snippets: [Snippet]) -> String {
        snippets.sorted { $0.trigger.count > $1.trigger.count }.reduce(input) { text, snippet in
            replacingWholePhrase(snippet.trigger, in: text, with: snippet.expansion)
        }
    }

    private static func replacingWholePhrase(_ phrase: String, in input: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !escaped.isEmpty else { return input }
        let pattern = "(?i)(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
        return input.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func normalizeWhitespace(_ input: String) -> String {
        var value = input
        value = value.replacingOccurrences(of: #"[ \t]+([,.;:!?])"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeWhenAppropriate(_ input: String, context: TextContext) -> String {
        guard context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).last.map({ ".!?\n".contains($0) }) == true,
              let first = input.first, first.isLetter else { return input }
        return first.uppercased() + input.dropFirst()
    }

    private static func applyContextSpacing(_ input: String, context: TextContext, style: WritingStyle) -> String {
        guard !context.isSecure else { return input }
        var text = input
        let before = context.textBeforeCursor
        let after = context.textAfterCursor
        if let last = before.last, !last.isWhitespace, !"([{\n".contains(last),
           let first = text.first, !",.;:!?)]}\n".contains(first) {
            text = " " + text
        }
        if let firstAfter = after.first, !firstAfter.isWhitespace, !",.;:!?)]}\n".contains(firstAfter),
           let last = text.last, !last.isWhitespace, !"([{\n".contains(last) {
            text += " "
        }
        if style == .casual, text.count < 100, context.applicationName.lowercased().contains("message") {
            text = text.replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        }
        return text
    }
}
