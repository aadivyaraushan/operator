import Foundation

/// A piece of a line of prose: ordinary text (still inline Markdown) or a
/// formula that sits in the line.
enum ReplyInline: Equatable {
    case text(String)
    case math(String)
}

/// One stacked piece of a reply.
enum ReplyBlock: Equatable {
    case prose([ReplyInline])
    /// A fenced block, without its fences.
    case code(language: String?, text: String)
    /// A formula on its own line, as LaTeX without its delimiters.
    case math(String)
}

/// Splits a reply into prose, code and formulas. Runs on every streamed
/// update, so anything not yet closed is handled: an open fence is code to
/// the end, an open formula stays text until its closing mark arrives.
///
/// Recognised: ``` and ~~~ fences; `\[ \]` and `$$ $$` for a formula on its
/// own; `\( \)` and `$ $` for one in a line. Nothing inside a fence or inside
/// `inline code` is read as a formula, and "$5 and $10" is money.
enum ReplyBlocks {
    static func parse(_ reply: String) -> [ReplyBlock] {
        var blocks: [ReplyBlock] = []
        for segment in Self.splitFences(reply) {
            switch segment {
            case let .code(language, text):
                blocks.append(.code(language: language, text: text))
            case let .text(text):
                blocks.append(contentsOf: Self.proseAndMath(text))
            }
        }
        return blocks
    }

    // MARK: fences

    private enum Segment {
        case text(String)
        case code(language: String?, text: String)
    }

    private static func splitFences(_ reply: String) -> [Segment] {
        var segments: [Segment] = []
        var textLines: [Substring] = []
        var codeLines: [Substring] = []
        var open: (marker: String, language: String?)?

        func flushText() {
            if !textLines.isEmpty { segments.append(.text(textLines.joined(separator: "\n"))) }
            textLines = []
        }

        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = open {
                if trimmed.hasPrefix(fence.marker), trimmed.allSatisfy({ $0 == fence.marker.first }) {
                    segments.append(.code(language: fence.language, text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    open = nil
                } else {
                    codeLines.append(line)
                }
            } else if let marker = ["```", "~~~"].first(where: trimmed.hasPrefix) {
                flushText()
                let info = trimmed.drop { $0 == marker.first }.trimmingCharacters(in: .whitespaces)
                let language = info.split(separator: " ").first.map(String.init)
                open = (marker, language)
            } else {
                textLines.append(line)
            }
        }
        if let fence = open {
            segments.append(.code(language: fence.language, text: codeLines.joined(separator: "\n")))
        }
        flushText()
        return segments
    }

    // MARK: formulas

    private enum Token {
        case text(String)
        case inlineMath(String)
        case displayMath(String)
    }

    private static func proseAndMath(_ text: String) -> [ReplyBlock] {
        var blocks: [ReplyBlock] = []
        var line: [ReplyInline] = []

        func flushLine() {
            let trimmed = Self.trimmingOuterWhitespace(line)
            if !trimmed.isEmpty { blocks.append(.prose(trimmed)) }
            line = []
        }

        for token in Self.tokens(Array(text)) {
            switch token {
            case let .text(text):
                if case let .text(previous)? = line.last {
                    line[line.count - 1] = .text(previous + text)
                } else {
                    line.append(.text(text))
                }
            case let .inlineMath(latex):
                line.append(.math(latex))
            case let .displayMath(latex):
                flushLine()
                blocks.append(.math(latex))
            }
        }
        flushLine()
        return blocks
    }

    private static func trimmingOuterWhitespace(_ line: [ReplyInline]) -> [ReplyInline] {
        var line = line
        if case let .text(first)? = line.first {
            line[0] = .text(String(first.drop { $0.isWhitespace }))
        }
        if case let .text(last)? = line.last {
            var kept = Substring(last)
            while kept.last?.isWhitespace == true { kept.removeLast() }
            line[line.count - 1] = .text(String(kept))
        }
        return line.filter { $0 != .text("") }
    }

    private static func tokens(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0

        func starts(_ mark: String, at index: Int) -> Bool {
            let mark = Array(mark)
            return index + mark.count <= chars.count && Array(chars[index ..< index + mark.count]) == mark
        }
        func find(_ mark: String, from index: Int) -> Int? {
            var j = index
            while j < chars.count {
                if starts(mark, at: j) { return j }
                j += 1
            }
            return nil
        }
        func latex(_ from: Int, _ to: Int) -> String {
            String(chars[from ..< to]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                // Inline code: copied through whole, never searched.
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                let fence = String(repeating: "`", count: run)
                if let close = find(fence, from: i + run) {
                    tokens.append(.text(String(chars[i ..< close + run])))
                    i = close + run
                } else {
                    tokens.append(.text(fence))
                    i += run
                }
            } else if starts("\\$", at: i) {
                tokens.append(.text("\\$"))
                i += 2
            } else if starts("\\[", at: i), let close = find("\\]", from: i + 2) {
                tokens.append(.displayMath(latex(i + 2, close)))
                i = close + 2
            } else if starts("$$", at: i), let close = find("$$", from: i + 2), close > i + 2 {
                tokens.append(.displayMath(latex(i + 2, close)))
                i = close + 2
            } else if starts("\\(", at: i), let close = find("\\)", from: i + 2) {
                tokens.append(.inlineMath(latex(i + 2, close)))
                i = close + 2
            } else if c == "$", let close = Self.closingDollar(chars, opening: i) {
                tokens.append(.inlineMath(latex(i + 1, close)))
                i = close + 1
            } else {
                tokens.append(.text(String(c)))
                i += 1
            }
        }
        return tokens
    }

    /// A single `$` opens a formula only when it hugs its contents on both
    /// sides, closes on the same line, and is not followed by a digit. That
    /// keeps "$5 now and $10 later" as money.
    private static func closingDollar(_ chars: [Character], opening: Int) -> Int? {
        let first = opening + 1
        guard first < chars.count, !chars[first].isWhitespace, chars[first] != "$" else { return nil }
        var j = first
        while j < chars.count, chars[j] != "\n" {
            if chars[j] == "$", chars[j - 1] != "\\" {
                let hugs = !chars[j - 1].isWhitespace && j > first
                let digitFollows = j + 1 < chars.count && chars[j + 1].isNumber
                return hugs && !digitFollows ? j : nil
            }
            j += 1
        }
        return nil
    }
}
