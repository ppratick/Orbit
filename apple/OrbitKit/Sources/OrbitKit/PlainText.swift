import Foundation

/// Orbit's replies read like text messages: plain prose, shown verbatim (never parsed as Markdown).
/// `clean` mirrors cloud/src/plaintext.ts so the live streaming bubble matches the stored reply.
public enum PlainText {
    private static func sub(_ s: String, _ pattern: String, _ template: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    public static func clean(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "\r\n", with: "\n")
        s = sub(s, "```[A-Za-z0-9_-]*\\n?([\\s\\S]*?)```", "$1")
        s = sub(s, "`([^`\\n]+)`", "$1")
        s = sub(s, "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", "$1")
        s = sub(s, "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "$1 ($2)")
        s = sub(s, "^[ \\t]{0,3}#{1,6}[ \\t]+", "")
        s = sub(s, "^[ \\t]{0,3}>[ \\t]?", "")
        s = sub(s, "^[ \\t]*[-*+•][ \\t]+", "")
        s = sub(s, "(\\*\\*|__)(?=\\S)([\\s\\S]*?\\S)\\1", "$2")
        s = sub(s, "(^|[^\\w*])\\*(?=\\S)([^*\\n]*?\\S)\\*(?!\\w)", "$1$2")
        s = sub(s, "~~(?=\\S)([\\s\\S]*?\\S)~~", "$1")
        s = sub(s, "[ \\t]+\\n", "\n")
        s = sub(s, "\\n{3,}", "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text with web links made tappable, like Messages does.
    public static func attributed(_ input: String) -> AttributedString {
        let text = clean(input)
        var out = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = m.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let r = Range(m.range, in: text), let ar = Range(r, in: out) else { continue }
            out[ar].link = url
        }
        return out
    }
}
