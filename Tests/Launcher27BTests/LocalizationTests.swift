import Foundation
import Testing

/// Guardrails for the "Simplified Chinese is the source language" localization scheme.
///
/// Keys in `Resources/*.lproj/Localizable.strings` are the Simplified-Chinese UI
/// literals used directly in `Sources/`, so the scheme has no compiler enforcement:
/// one typo in an enum's Chinese literal, one forgotten translation, or one format
/// specifier dropped in a translation ships Chinese (or a crash-prone format string)
/// to English users. There are no UI tests, so nothing else verifies that the keys
/// actually resolve.
///
/// These tests read the `.strings` files and the Swift sources straight from disk.
/// SwiftPM does not copy `Resources/` into the test bundle, so the package root is
/// resolved from `#filePath` (no `Package.swift` changes needed).
struct LocalizationTests {
    // MARK: - Conventions

    /// Languages that must contain a complete translation of every referenced key.
    private static let requiredLanguages = ["en", "es", "zh-Hans", "zh-Hant"]
    /// The source language. Intentionally sparse: a missing value falls back to the key.
    private static let sourceLanguage = "zh-Hans"

    /// Keys whose value is legitimately identical across scripts, so a CJK value in
    /// `en`/`es` is expected rather than an untranslated leak. Keep this list tight:
    /// every entry is a value the CJK scan will no longer check.
    private static let scriptNeutralKeys: Set<String> = [
        "、",
        "好",
        "更多",
        "Token 用量",
    ]

    /// Stands in for a value at substitution time. A key's format specifier
    /// (`%@`, `%lld`, `%%`) and a source interpolation (`\(...)`) both collapse to
    /// this character, so the interpolated form of a message can be compared with the
    /// key it should correspond to.
    private static let substitutionSentinel = "\u{FFFC}"

    /// Chinese literals that legitimately never reach the localized UI: log-file
    /// contents, interpolated developer-facing `errorDescription` fragments, and the
    /// native language names shown unchanged in the language picker.
    ///
    /// Entries are compared against a literal with its interpolations already
    /// collapsed to `substitutionSentinel`. Every other Chinese literal in
    /// `Sources/` must be a key, or it is a leak.
    private static let developerFacingLiterals: Set<String> = {
        let sentinel = substitutionSentinel
        return [
            // Contents written into the server log file.
            "llama-server 将所有日志写入 stderr；本文件通常为空，实际日志见 server.error.log。",
            "已启用",
            "已禁用（--no-webui）",
            "已设置（值不写入日志）",
            "未设置（仅本机模式）",
            "已通过 -lv " + sentinel + " 抑制常规 INFO 日志。",
            // `InstallerError.fileOperationFailed.errorDescription` keeps the raw
            // underlying text for logs; the UI path uses an actionable key instead.
            "安装文件时发生错误：" + sentinel,
            // Fragment concatenated inside a developer-facing `errorDescription`.
            "内存不足：运行 27B 模型至少需要 ",
            // Native language names, displayed as-is rather than translated.
            "简体中文",
            "繁體中文",
        ]
    }()

    /// Prefixes of large, indented, interpolated developer-facing text that is written
    /// to a log file rather than shown in the UI. Matched against the trimmed body.
    private static let developerFacingLiteralPrefixes: [String] = [
        // The server-log session header written at each launch.
        "===== 27B Launcher 会话开始",
    ]

    // MARK: - Fixtures

    /// `<package root>`, found by walking up from this file until `Package.swift` appears.
    private static let packageRoot: URL = {
        let fileManager = FileManager.default
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }()

    private static let stringsByLanguage: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for language in ["en", "es", "zh-Hans", "zh-Hant"] {
            result[language] = loadStrings(language)
        }
        return result
    }()

    private static let swiftSourceFiles: [String] = {
        let root = packageRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var sources: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                sources.append(contents)
            }
        }
        return sources.sorted()
    }()

    private static let combinedSourceText: String = swiftSourceFiles.joined(separator: "\n")

    /// Every localization key that `Sources/` can ask for at runtime.
    private static let referencedKeys: Set<String> = {
        var keys: Set<String> = []
        for source in swiftSourceFiles {
            keys.formUnion(referencedKeys(in: source))
        }
        return keys
    }()

    private static func loadStrings(_ language: String) -> [String: String] {
        let url = packageRoot
            .appendingPathComponent("Sources/Launcher27B/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let table = plist as? [String: String] else {
            return [:]
        }
        return table
    }

    /// Raw text of a `.strings` file.
    ///
    /// Deliberately not `loadStrings`: `PropertyListSerialization` returns a
    /// dictionary, which silently keeps only the last entry for a duplicated key, so
    /// duplicates must be counted from the file text.
    private static func rawStringsFile(_ language: String) -> String? {
        let url = packageRoot
            .appendingPathComponent("Sources/Launcher27B/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Matches the `"key" =` part of a `"key" = "value";` line, ignoring comments.
    private static let keyDeclarationRegex = try? NSRegularExpression(
        pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#
    )

    private static func keyDeclaration(in line: String) -> String? {
        guard let regex = keyDeclarationRegex else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let keyRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[keyRange])
    }

    // MARK: - Key discovery

    /// Keys reach the localization helper through `localized(_:)` / `localizedFormat(_:)`
    /// call arguments, and indirectly through computed properties/functions whose
    /// Chinese literals are handed to those helpers (for example
    /// `Text(preferences.localized(controller.status.title))`).
    private static func referencedKeys(in source: String) -> Set<String> {
        let characters = Array(source)
        var keys: Set<String> = []

        // Direct call arguments: every string literal inside localized(...) / localizedFormat(...).
        for openIndex in openingParentheses(ofCallsTo: ["localized", "localizedFormat"], in: characters) {
            guard let endIndex = endOfBalanced(characters, openIndex: openIndex, open: "(", close: ")") else {
                continue
            }
            let argumentRegion = String(characters[(openIndex + 1)..<endIndex])
            keys.formUnion(keyLiterals(in: argumentRegion))
        }

        // Indirect providers: switch-based computed properties and helper functions.
        for openIndex in openingBraces(ofKeyProvidersIn: characters) {
            guard let endIndex = endOfBalanced(characters, openIndex: openIndex, open: "{", close: "}") else {
                continue
            }
            let body = String(characters[(openIndex + 1)..<endIndex])
            keys.formUnion(keyLiterals(in: body))
        }

        return keys
    }

    /// Declaration names whose Chinese literals always flow into `localized(...)`.
    private static let providerPatterns = [
        #"\bvar\s+(?:title|detail|titleKey|detailKey|localizationKey|explanation|subtitleKey)\s*:\s*String\s*\{"#,
        #"\bfunc\s+\w*(?:Title|Key|Message|Subtitle|Explanation)\w*\s*\([^)]*\)[^{]*\{"#,
    ]

    private static func openingBraces(ofKeyProvidersIn characters: [Character]) -> [Int] {
        let source = String(characters)
        var indices: [Int] = []
        for pattern in providerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let matchRange = Range(match.range, in: source),
                      let braceIndex = source[matchRange].lastIndex(of: "{") else {
                    continue
                }
                indices.append(source.distance(from: source.startIndex, to: braceIndex))
            }
        }
        return indices
    }

    private static func openingParentheses(
        ofCallsTo names: [String],
        in characters: [Character]
    ) -> [Int] {
        let source = String(characters)
        var indices: [Int] = []
        for name in names {
            let pattern = "(?<![A-Za-z0-9_])\(name)\\s*\\("
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let matchRange = Range(match.range, in: source),
                      let parenIndex = source[matchRange].lastIndex(of: "(") else {
                    continue
                }
                indices.append(source.distance(from: source.startIndex, to: parenIndex))
            }
        }
        return indices.sorted()
    }

    /// String literals that could be localization keys: Chinese, or containing a
    /// format specifier. Symbol names and identifiers are ignored.
    private static func keyLiterals(in text: String) -> Set<String> {
        Set(stringLiterals(in: text).filter { containsCJK($0) || $0.contains("%") })
    }

    private static func stringLiterals(in text: String) -> [String] {
        let characters = Array(text)
        var literals: [String] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "\"" else {
                index += 1
                continue
            }

            // Multi-line literal: skip until the closing triple quote.
            if index + 2 < characters.count,
               characters[index + 1] == "\"",
               characters[index + 2] == "\"" {
                var cursor = index + 3
                var body = ""
                var closed = false
                while cursor + 2 < characters.count {
                    if characters[cursor] == "\"",
                       characters[cursor + 1] == "\"",
                       characters[cursor + 2] == "\"" {
                        cursor += 3
                        closed = true
                        break
                    }
                    body.append(characters[cursor])
                    cursor += 1
                }
                if closed {
                    literals.append(body)
                    index = cursor
                } else {
                    index += 1
                }
                continue
            }

            var cursor = index + 1
            var body = ""
            var closed = false
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "\\", cursor + 1 < characters.count {
                    body.append(characters[cursor + 1])
                    cursor += 2
                    continue
                }
                if character == "\"" {
                    cursor += 1
                    closed = true
                    break
                }
                body.append(character)
                cursor += 1
            }
            if closed {
                literals.append(body)
                index = cursor
            } else {
                index += 1
            }
        }
        return literals
    }

    /// A string literal found in source, with every interpolation (`\(...)`) already
    /// collapsed to `substitutionSentinel`.
    private struct LiteralToken {
        let body: String
        let hasInterpolation: Bool
        /// Index of the opening quote.
        let start: Int
        /// Index just past the closing quote.
        let end: Int
    }

    /// A run of literals joined by `+`, which Swift evaluates into a single message.
    /// The codebase builds several formatted messages this way, so fragments are only
    /// meaningful once reassembled into one string.
    private struct LiteralRun {
        let body: String
        let hasInterpolation: Bool
    }

    /// Every string literal in `text`. Interpolation contents are replaced by
    /// `substitutionSentinel`, which lets the outer text of a message be compared
    /// against a key without the interpolated expression's contents interfering.
    private static func literalTokens(in text: String) -> [LiteralToken] {
        let characters = Array(text)
        var tokens: [LiteralToken] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "\"" else {
                index += 1
                continue
            }
            let start = index

            if index + 2 < characters.count,
               characters[index + 1] == "\"",
               characters[index + 2] == "\"" {
                var cursor = index + 3
                var body = ""
                var hasInterpolation = false
                var closed = false
                while cursor + 2 < characters.count {
                    if characters[cursor] == "\"",
                       characters[cursor + 1] == "\"",
                       characters[cursor + 2] == "\"" {
                        cursor += 3
                        closed = true
                        break
                    }
                    let character = characters[cursor]
                    if character == "\\", cursor + 1 < characters.count {
                        if characters[cursor + 1] == "(" {
                            hasInterpolation = true
                            body += substitutionSentinel
                            cursor = endOfInterpolation(characters, from: cursor)
                            continue
                        }
                        body.append(characters[cursor + 1])
                        cursor += 2
                        continue
                    }
                    body.append(character)
                    cursor += 1
                }
                if closed {
                    tokens.append(
                        LiteralToken(body: body, hasInterpolation: hasInterpolation, start: start, end: cursor)
                    )
                    index = cursor
                } else {
                    index += 1
                }
                continue
            }

            var cursor = index + 1
            var body = ""
            var hasInterpolation = false
            var closed = false
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "\\", cursor + 1 < characters.count {
                    if characters[cursor + 1] == "(" {
                        hasInterpolation = true
                        body += substitutionSentinel
                        cursor = endOfInterpolation(characters, from: cursor)
                        continue
                    }
                    body.append(characters[cursor + 1])
                    cursor += 2
                    continue
                }
                if character == "\"" {
                    cursor += 1
                    closed = true
                    break
                }
                body.append(character)
                cursor += 1
            }
            if closed {
                tokens.append(
                    LiteralToken(body: body, hasInterpolation: hasInterpolation, start: start, end: cursor)
                )
                index = cursor
            } else {
                index += 1
            }
        }
        return tokens
    }

    private static func literalRuns(_ tokens: [LiteralToken], in text: String) -> [LiteralRun] {
        let characters = Array(text)
        var runs: [LiteralRun] = []
        var index = 0

        while index < tokens.count {
            var body = tokens[index].body
            var hasInterpolation = tokens[index].hasInterpolation
            var next = index
            while next + 1 < tokens.count,
                  isPlusOnly(characters, from: tokens[next].end, to: tokens[next + 1].start) {
                body += tokens[next + 1].body
                hasInterpolation = hasInterpolation || tokens[next + 1].hasInterpolation
                next += 1
            }
            runs.append(LiteralRun(body: body, hasInterpolation: hasInterpolation))
            index = next + 1
        }
        return runs
    }

    /// True when only whitespace and a single `+` separate two literals.
    private static func isPlusOnly(_ characters: [Character], from: Int, to: Int) -> Bool {
        guard from < to, to <= characters.count else { return false }
        return String(characters[from..<to])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "+"
    }

    /// Index just past the `)` matching the `\(` at `index`.
    private static func endOfInterpolation(_ characters: [Character], from index: Int) -> Int {
        var cursor = index + 2
        var depth = 1
        while cursor < characters.count, depth > 0 {
            let character = characters[cursor]
            if character == "\"" {
                cursor += 1
                while cursor < characters.count {
                    if characters[cursor] == "\\" {
                        cursor += 2
                        continue
                    }
                    if characters[cursor] == "\"" {
                        cursor += 1
                        break
                    }
                    cursor += 1
                }
                continue
            }
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            }
            cursor += 1
        }
        return cursor
    }

    /// Collapses each format specifier in a key to `substitutionSentinel`, so a key
    /// and an interpolated source literal reduce to the same shape.
    private static func normalizedKey(_ key: String) -> String {
        guard let regex = formatSpecifierRegex else { return key }
        let range = NSRange(key.startIndex..., in: key)
        var result = ""
        var last = key.startIndex
        for match in regex.matches(in: key, range: range) {
            guard let matchRange = Range(match.range, in: key) else { continue }
            result += String(key[last..<matchRange.lowerBound])
            result += substitutionSentinel
            last = matchRange.upperBound
        }
        result += String(key[last...])
        return result
    }

    /// Index of the character matching the delimiter opened at `openIndex`, ignoring
    /// delimiters inside string literals.
    private static func endOfBalanced(
        _ characters: [Character],
        openIndex: Int,
        open: Character,
        close: Character
    ) -> Int? {
        guard openIndex < characters.count, characters[openIndex] == open else { return nil }
        var depth = 0
        var index = openIndex

        while index < characters.count {
            let character = characters[index]

            if character == "\"" {
                if index + 2 < characters.count,
                   characters[index + 1] == "\"",
                   characters[index + 2] == "\"" {
                    index += 3
                    while index + 2 < characters.count {
                        if characters[index] == "\"",
                           characters[index + 1] == "\"",
                           characters[index + 2] == "\"" {
                            index += 3
                            break
                        }
                        index += 1
                    }
                    continue
                }
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" {
                        index += 2
                        continue
                    }
                    if characters[index] == "\"" {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }

            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Character helpers

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, // CJK symbols and punctuation
                 0x3400...0x4DBF, // CJK unified ideographs extension A
                 0x4E00...0x9FFF, // CJK unified ideographs
                 0xF900...0xFAFF, // CJK compatibility ideographs
                 0xFF00...0xFFEF: // Halfwidth and fullwidth forms
                return true
            default:
                return false
            }
        }
    }

    /// A printf-style format specifier such as `%@`, `%lld`, `%d` or `%%`.
    private static let formatSpecifierRegex = try? NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0]*[\d.*]*(?:hh|h|ll|l|L|z|j|t|q)?[@dDuUxXoOfeEgGcsSaApnZ]"#
    )

    private static func formatSpecifiers(in text: String) -> [String] {
        guard let regex = formatSpecifierRegex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func comment(_ message: String) -> Comment {
        Comment(rawValue: message)
    }

    // MARK: - Tests

    @Test
    func stringsFilesAreReadable() {
        for language in ["en", "es", "zh-Hans", "zh-Hant"] {
            let table = Self.stringsByLanguage[language] ?? [:]
            #expect(!table.isEmpty, Self.comment("Could not read Localizable.strings for \(language)."))
        }
    }

    /// A duplicated key is invisible everywhere else: `plutil -lint` accepts it,
    /// `plutil -convert` and `PropertyListSerialization` dedupe it (so the key count
    /// still looks right and `stringsByLanguage` hides it), and the last entry wins at
    /// runtime. With several agents editing these files concurrently, a duplicate
    /// silently overrides a translation without any signal. Count from the raw text.
    @Test
    func stringsFilesContainNoDuplicateKeys() {
        var duplicates: [String] = []

        for language in ["en", "es", "zh-Hans", "zh-Hant"] {
            guard let raw = Self.rawStringsFile(language) else {
                duplicates.append("\(language): Localizable.strings could not be read")
                continue
            }
            var counts: [String: Int] = [:]
            for line in raw.components(separatedBy: .newlines) {
                guard let key = Self.keyDeclaration(in: line) else { continue }
                counts[key, default: 0] += 1
            }
            for (key, count) in counts where count > 1 {
                duplicates.append("\(language): \(key) appears \(count) times")
            }
        }

        #expect(
            duplicates.isEmpty,
            Self.comment("Duplicate key(s):\n" + duplicates.sorted().joined(separator: "\n"))
        )
    }

    /// All four translation tables must have the same complete key set.
    @Test
    func completeTranslationsShareOneKeySet() {
        let english = Set(Self.stringsByLanguage["en"]?.keys ?? [:].keys)
        for language in Self.requiredLanguages where language != "en" {
            let other = Set(Self.stringsByLanguage[language]?.keys ?? [:].keys)
            #expect(
                english == other,
                Self.comment(
                    "\(language) key set differs from en. Only in en: \(english.subtracting(other).sorted()). "
                        + "Only in \(language): \(other.subtracting(english).sorted())."
                )
            )
        }

        let source = Set(Self.stringsByLanguage[Self.sourceLanguage]?.keys ?? [:].keys)
        #expect(
            source.isSubset(of: english),
            Self.comment(
                "\(Self.sourceLanguage) contains keys absent from en: \(source.subtracting(english).sorted())."
            )
        )
    }

    /// Every referenced key must exist in all four locales.
    @Test
    func everyReferencedKeyIsTranslated() {
        let referenced = Self.referencedKeys
        #expect(!referenced.isEmpty, Self.comment("Key discovery found no keys; the extractor is broken."))

        for language in Self.requiredLanguages {
            let table = Set(Self.stringsByLanguage[language]?.keys ?? [:].keys)
            let missing = referenced.subtracting(table)
            #expect(
                missing.isEmpty,
                Self.comment(
                    "\(missing.count) key(s) referenced in Sources/ have no \(language) translation: "
                        + missing.sorted().joined(separator: " | ")
                )
            )
        }
    }

    /// A translation must repeat exactly the format specifiers of its key, or
    /// `String(format:)` will read the wrong arguments.
    @Test
    func formatSpecifiersMatchTheirTranslations() {
        let english = Self.stringsByLanguage["en"] ?? [:]
        var mismatches: [String] = []

        for (key, _) in english {
            let expected = Self.formatSpecifiers(in: key)
            guard !expected.isEmpty else { continue }
            let expectedSet = expected.sorted()

            for language in ["es", "zh-Hans", "zh-Hant"] {
                guard let translation = Self.stringsByLanguage[language]?[key] else { continue }
                let actual = Self.formatSpecifiers(in: translation).sorted()
                if actual != expectedSet {
                    mismatches.append(
                        "\(language): \(key) expects \(expectedSet) but has \(actual)"
                    )
                }
            }
        }

        #expect(
            mismatches.isEmpty,
            Self.comment("Format specifier mismatch(es):\n" + mismatches.joined(separator: "\n"))
        )
    }

    /// `en` and `es` must never contain CJK; a CJK value there means an untranslated
    /// Simplified-Chinese string leaked in. `zh-Hant` legitimately contains CJK.
    @Test
    func englishAndSpanishContainNoCJK() {
        var leaks: [String] = []

        for language in ["en", "es"] {
            for (key, value) in Self.stringsByLanguage[language] ?? [:] {
                if Self.scriptNeutralKeys.contains(key) { continue }
                if Self.containsCJK(value) {
                    leaks.append("\(language): \(key) = \(value)")
                }
            }
        }

        #expect(
            leaks.isEmpty,
            Self.comment("Untranslated CJK value(s) leaked into en/es:\n" + leaks.sorted().joined(separator: "\n"))
        )
    }

    /// A key present in the translation tables but referenced nowhere in `Sources/`
    /// is a stale artifact. The check is deliberately conservative: a key counts as
    /// referenced when its text appears *anywhere* in the sources, so literals that
    /// are only reached indirectly (through a computed property, a concatenation, or
    /// a dynamically built string) can never produce a false failure.
    @Test
    func translationTablesContainNoDeadKeys() {
        let source = Self.combinedSourceText
        var deadKeys: Set<String> = []

        for language in ["en", "es", "zh-Hant", Self.sourceLanguage] {
            for key in Self.stringsByLanguage[language]?.keys ?? [:].keys {
                if !source.contains(key) {
                    deadKeys.insert(key)
                }
            }
        }

        #expect(
            deadKeys.isEmpty,
            Self.comment(
                "\(deadKeys.count) key(s) exist in the .strings tables but appear nowhere in Sources/: "
                    + deadKeys.sorted().joined(separator: " | ")
            )
        )
    }

    /// A Chinese literal in `Sources/` that is not itself a key is almost always a
    /// leak. The worst case is Chinese smuggled in as the *argument* to a `%@` — for
    /// example an error enum carrying a `String` payload, formatted with
    /// `localizedFormat("模型迁移失败：%@", payload)`. That formatting error leaves the key
    /// present, the specifier counts correct, every other check green, and still
    /// renders Chinese to an English user, so it needs its own guard.
    ///
    /// Developer-facing literals that never reach the localized UI are allowlisted in
    /// `developerFacingLiterals`; interpolated (`\(...)`) literals are skipped.
    @Test
    func noChineseLiteralEscapesLocalization() {
        let keys = Set(Self.stringsByLanguage["en"]?.keys ?? [:].keys)
        let normalizedKeys = Set(keys.map(Self.normalizedKey))
        var leaks: Set<String> = []

        for source in Self.swiftSourceFiles {
            let runs = Self.literalRuns(Self.literalTokens(in: source), in: source)
            for run in runs {
                guard Self.containsCJK(run.body) else { continue }
                if keys.contains(run.body) { continue }
                if Self.developerFacingLiterals.contains(run.body) { continue }
                let trimmed = run.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.developerFacingLiteralPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                    continue
                }
                if run.hasInterpolation, normalizedKeys.contains(run.body) { continue }
                leaks.insert(run.body)
            }
        }

        #expect(
            leaks.isEmpty,
            Self.comment(
                "\(leaks.count) Chinese literal(s) in Sources/ are not localization keys. "
                    + "If one is passed as a `%@` argument it reaches English users untranslated; "
                    + "add it as a key (or allowlist it in developerFacingLiterals if it never reaches the UI): "
                    + leaks.sorted().joined(separator: " | ")
            )
        )
    }
}
