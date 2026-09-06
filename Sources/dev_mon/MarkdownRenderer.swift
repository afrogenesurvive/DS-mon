import AppKit

/// 轻量 Markdown 渲染器：把文档渲染成带具体字体/颜色/段落样式的 NSAttributedString，
/// 供 NSTextView 显示。覆盖指南文档用到的常见语法：标题、粗斜体、行内代码、代码块、
/// 列表（含任务列表/有序/无序）、引用、表格、链接、分隔线。
/// （不渲染 Mermaid 图 — 按代码块原样显示；需要完整效果时用「在外部打开」。）
enum MarkdownRenderer {

    // MARK: - Fonts

    private static let bodySize: CGFloat = 12

    private static func systemFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func monoFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func styledFont(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    // MARK: - Public

    static func attributedString(from markdown: String, baseURL: URL? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        let n = lines.count

        while i < n {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // 围栏代码块
            if let fence = fenceInfo(trimmed) {
                i = appendCodeBlock(lines: lines, start: i, fence: fence, to: out)
                continue
            }
            // ATX 标题
            if let level = headingLevel(raw) {
                appendHeading(raw, level: level, baseURL: baseURL, to: out)
                i += 1
                continue
            }
            // 分隔线
            if isHorizontalRule(trimmed) {
                appendRule(to: out)
                i += 1
                continue
            }
            // 引用
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < n {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var content = t
                        content.removeFirst()
                        quote.append(content.trimmingCharacters(in: .whitespaces))
                        i += 1
                    } else {
                        break
                    }
                }
                appendBlockquote(quote.joined(separator: " "), baseURL: baseURL, to: out)
                continue
            }
            // 列表
            if parseListItem(raw) != nil {
                i = appendList(lines: lines, start: i, baseURL: baseURL, to: out)
                continue
            }
            // 表格
            if looksLikeTableRow(raw), i + 1 < n, isTableSeparator(lines[i + 1]) {
                i = appendTable(lines: lines, start: i, baseURL: baseURL, to: out)
                continue
            }
            // 普通段落（收集连续行）
            var para: [String] = []
            while i < n {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                let rest = lines[i]
                if fenceInfo(t) != nil
                    || headingLevel(rest) != nil
                    || isHorizontalRule(t)
                    || t.hasPrefix(">")
                    || parseListItem(rest) != nil
                    || (looksLikeTableRow(rest) && i + 1 < n && isTableSeparator(lines[i + 1])) {
                    break
                }
                para.append(t)
                i += 1
            }
            appendParagraph(para.joined(separator: " "), baseURL: baseURL, to: out)
        }

        return out
    }

    // MARK: - Paragraph helpers

    private static func paragraphStyle(spacingBefore: CGFloat = 0, spacing: CGFloat = 6,
                                       firstLineHeadIndent: CGFloat = 0, headIndent: CGFloat = 0,
                                       lineSpacing: CGFloat = 2) -> NSParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.paragraphSpacingBefore = spacingBefore
        s.paragraphSpacing = spacing
        s.firstLineHeadIndent = firstLineHeadIndent
        s.headIndent = headIndent
        s.lineSpacing = lineSpacing
        s.lineBreakMode = .byWordWrapping
        return s
    }

    private static func applyStyle(_ out: NSMutableAttributedString, from start: Int,
                                   _ style: NSParagraphStyle) {
        guard out.length > start else { return }
        out.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: start, length: out.length - start))
    }

    private static func newline(_ out: NSMutableAttributedString) {
        out.append(NSAttributedString(string: "\n"))
    }

    private static func appendText(_ s: String, font: NSFont,
                                   color: NSColor = .labelColor,
                                   extra: [NSAttributedString.Key: Any] = [:],
                                   to out: NSMutableAttributedString) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for (k, v) in extra { attrs[k] = v }
        out.append(NSAttributedString(string: s, attributes: attrs))
    }

    // MARK: - Heading

    private static func headingLevel(_ raw: String) -> Int? {
        let chars = Array(raw)
        var level = 0
        for ch in chars {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, chars.count > level else { return nil }
        guard chars[level] == " " else { return nil }
        return level
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "-_* ")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let ch = marks.first, Set(marks).count == 1,
              ch == "-" || ch == "_" || ch == "*" else { return false }
        return true
    }

    private static func headingSpec(_ level: Int) -> (CGFloat, NSFont.Weight) {
        switch level {
        case 1: return (20, .bold)
        case 2: return (16, .semibold)
        case 3: return (14, .semibold)
        case 4: return (13, .medium)
        case 5: return (12, .medium)
        default: return (11, .medium)
        }
    }

    private static func appendHeading(_ raw: String, level: Int, baseURL: URL?, to out: NSMutableAttributedString) {
        let chars = Array(raw)
        let content = String(chars.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
        let spec = headingSpec(level)
        let font = systemFont(spec.0, spec.1)
        let before: CGFloat = level <= 2 ? 14 : 8
        let start = out.length
        appendInlineRuns(content, font: font, color: .labelColor, baseURL: baseURL, to: out)
        applyStyle(out, from: start, paragraphStyle(spacingBefore: before, spacing: 5))
        newline(out)
    }

    // MARK: - Paragraph / quote / rule

    private static func appendParagraph(_ text: String, baseURL: URL?, to out: NSMutableAttributedString) {
        guard !text.isEmpty else { return }
        let start = out.length
        appendInlineRuns(text, font: systemFont(bodySize, .regular), color: .labelColor, baseURL: baseURL, to: out)
        applyStyle(out, from: start, paragraphStyle(spacing: 6))
        newline(out)
    }

    private static func appendBlockquote(_ text: String, baseURL: URL?, to out: NSMutableAttributedString) {
        guard !text.isEmpty else { return }
        let start = out.length
        appendInlineRuns(text, font: systemFont(bodySize, .regular), color: .secondaryLabelColor,
                         baseURL: baseURL, to: out)
        applyStyle(out, from: start, paragraphStyle(spacing: 6,
                                                   firstLineHeadIndent: 14, headIndent: 14))
        newline(out)
    }

    private static func appendRule(to out: NSMutableAttributedString) {
        let start = out.length
        appendText("\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}",
                   font: systemFont(8, .regular), color: .tertiaryLabelColor, to: out)
        applyStyle(out, from: start, paragraphStyle(spacingBefore: 6, spacing: 8))
        newline(out)
    }

    // MARK: - Code blocks

    private static func fenceInfo(_ trimmed: String) -> (char: Character, count: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == first }).count
        return count >= 3 ? (first, count) : nil
    }

    private static func appendCodeBlock(lines: [String], start: Int, fence: (char: Character, count: Int),
                                        to out: NSMutableAttributedString) -> Int {
        let marker = String(repeating: fence.char, count: fence.count)
        var body: [String] = []
        var i = start + 1
        let n = lines.count
        while i < n {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(marker) { i += 1; break }
            body.append(lines[i])
            i += 1
        }
        let codeText = body.joined(separator: "\n")
        let startIdx = out.length
        appendText(codeText, font: monoFont(11, .regular), color: .labelColor,
                   extra: [.backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)],
                   to: out)
        applyStyle(out, from: startIdx, paragraphStyle(spacing: 8))
        newline(out)
        return i
    }

    // MARK: - Lists

    private struct ListItem {
        let level: Int        // 前导空格数
        let marker: String
        var text: String
    }

    private static func parseListItem(_ raw: String) -> ListItem? {
        let spaces = raw.prefix(while: { $0 == " " }).count
        let rest = raw.dropFirst(spaces)
        guard let first = rest.first else { return nil }

        // 无序 / 任务
        if first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            var content = after.dropFirst().trimmingCharacters(in: .whitespaces)
            var marker = String(first) + " "
            if first == "-" || first == "+" {
                let lower = content.lowercased()
                if lower.hasPrefix("[ ]") || lower.hasPrefix("[x]") {
                    let checked = lower.hasPrefix("[x]")
                    let idx = content.index(content.startIndex, offsetBy: 3)
                    content = String(content[idx...]).trimmingCharacters(in: .whitespaces)
                    marker = checked ? "\u{2611} " : "\u{2610} "
                }
            }
            if content.isEmpty { return nil }
            return ListItem(level: spaces, marker: marker, text: content)
        }

        // 有序
        if first.isNumber {
            var idx = rest.startIndex
            while idx < rest.endIndex, rest[idx].isNumber {
                idx = rest.index(after: idx)
            }
            let digits = String(rest[rest.startIndex..<idx])
            guard !digits.isEmpty else { return nil }
            let suffix = rest[idx...]
            guard let sep = suffix.first, sep == "." || sep == ")" else { return nil }
            let content = suffix.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return ListItem(level: spaces, marker: digits + ". ", text: content)
        }
        return nil
    }

    private static func appendList(lines: [String], start: Int, baseURL: URL?, to out: NSMutableAttributedString) -> Int {
        var items: [ListItem] = []
        var i = start
        let n = lines.count
        while i < n {
            let raw = lines[i]
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if let item = parseListItem(raw) {
                items.append(item)
                i += 1
                continue
            }
            // 续行：缩进的普通文字并入上一个列表项
            let leading = raw.prefix(while: { $0 == " " }).count
            if leading > 0, let last = items.indices.last {
                items[last].text += " " + t
                i += 1
                continue
            }
            break
        }

        for item in items {
            let indent = CGFloat(item.level) * 7
            let markerWidth = CGFloat(item.marker.count) * 9 + 6
            let startIdx = out.length
            let isCheck = item.marker.hasPrefix("\u{2610}") || item.marker.hasPrefix("\u{2611}")
            appendText(item.marker, font: systemFont(bodySize, .regular),
                       color: isCheck ? .secondaryLabelColor : .labelColor, to: out)
            appendInlineRuns(item.text, font: systemFont(bodySize, .regular), color: .labelColor,
                             baseURL: baseURL, to: out)
            applyStyle(out, from: startIdx,
                       paragraphStyle(spacing: 3,
                                      firstLineHeadIndent: indent, headIndent: indent + markerWidth))
            newline(out)
        }
        return i
    }

    // MARK: - Tables

    private static func looksLikeTableRow(_ line: String) -> Bool {
        line.contains("|")
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.contains("-") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: ")
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func splitCells(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while parts.first?.isEmpty == true { parts.removeFirst() }
        while parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    private static func appendTable(lines: [String], start: Int, baseURL: URL?, to out: NSMutableAttributedString) -> Int {
        var rows: [[String]] = []
        rows.append(splitCells(lines[start]))
        var i = start + 2 // 跳过表头分隔行
        let n = lines.count
        while i < n {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if looksLikeTableRow(t) {
                rows.append(splitCells(t))
                i += 1
            } else {
                break
            }
        }

        let colCount = rows.map { $0.count }.max() ?? 0
        guard colCount > 0 else { return i }
        let widths = (0..<colCount).map { c in
            rows.compactMap { $0.indices.contains(c) ? $0[c].count : 0 }.max() ?? 0
        }
        func pad(_ s: String, _ w: Int) -> String {
            s + String(repeating: " ", count: max(0, w - s.count))
        }
        var text = ""
        for (r, row) in rows.enumerated() {
            let cells = (0..<colCount).map { c in pad(row.indices.contains(c) ? row[c] : "", widths[c]) }
            text += cells.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
            if r < rows.count - 1 { text += "\n" }
        }

        let startIdx = out.length
        appendText(text, font: monoFont(11.5, .regular), color: .labelColor,
                   extra: [.backgroundColor: NSColor.labelColor.withAlphaComponent(0.05)],
                   to: out)
        // 表头加粗（第一行的可见长度）
        if rows.count > 1 {
            let headerLineLen = rows[0].indices.map { widths[$0] + 2 }.reduce(0, +) - 2
            if startIdx + headerLineLen <= out.length {
                out.addAttribute(.font, value: monoFont(11.5, .semibold),
                                 range: NSRange(location: startIdx, length: headerLineLen))
            }
        }
        applyStyle(out, from: startIdx, paragraphStyle(spacing: 8))
        newline(out)
        return i
    }

    // MARK: - Inline

    private static func resolveURL(_ str: String, base: URL?) -> URL? {
        let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: t), u.scheme != nil { return u }
        if let b = base { return b.appendingPathComponent(t) }
        return nil
    }

    /// 行内解析：代码、粗体、斜体、删除线、链接/图片。
    private static func appendInlineRuns(_ raw: String, font baseFont: NSFont,
                                         color: NSColor, isBold: Bool = false,
                                         isItalic: Bool = false, baseURL: URL? = nil,
                                         to out: NSMutableAttributedString) {
        let chars = Array(raw)
        var i = 0
        let count = chars.count
        let font = styledFont(baseFont, bold: isBold, italic: isItalic)

        func find(_ ch: Character, from i0: Int) -> Int? {
            for k in i0..<count where chars[k] == ch { return k }
            return nil
        }
        func findPair(_ a: Character, _ b: Character, from i0: Int) -> Int? {
            var k = i0
            while k + 1 < count {
                if chars[k] == a && chars[k + 1] == b { return k }
                k += 1
            }
            return nil
        }
        func wordBoundaryBefore(_ k: Int) -> Bool {
            guard k > 0 else { return true }
            let prev = chars[k - 1]
            return !prev.isLetter && !prev.isNumber
        }
        func wordBoundaryAfter(_ k: Int) -> Bool {
            guard k + 1 < count else { return true }
            let next = chars[k + 1]
            return !next.isLetter && !next.isNumber
        }

        while i < count {
            let ch = chars[i]

            // 行内代码
            if ch == "`" {
                if let j = find("`", from: i + 1) {
                    let code = String(chars[(i + 1)..<j])
                    let codeFont = monoFont(max(baseFont.pointSize - 0.5, 10), .regular)
                    appendText(code, font: codeFont, color: .systemBlue,
                               extra: [.backgroundColor: NSColor.labelColor.withAlphaComponent(0.08)],
                               to: out)
                    i = j + 1
                } else {
                    appendText("`", font: font, color: color, to: out)
                    i += 1
                }
                continue
            }

            // 图片 / 链接
            if ch == "[" || (ch == "!" && i + 1 < count && chars[i + 1] == "[") {
                let isImage = ch == "!"
                let linkIdx = isImage ? i + 1 : i
                if let close = find("]", from: linkIdx + 1), close + 1 < count, chars[close + 1] == "(",
                   let closeParen = find(")", from: close + 2) {
                    let label = String(chars[(linkIdx + 1)..<close])
                    let urlStr = String(chars[(close + 2)..<closeParen])
                    let subStart = out.length
                    if isImage {
                        appendInlineRuns(label, font: baseFont, color: .secondaryLabelColor,
                                         isBold: isBold, isItalic: true, baseURL: baseURL, to: out)
                    } else {
                        appendInlineRuns(label, font: baseFont, color: color,
                                         isBold: isBold, isItalic: isItalic, baseURL: baseURL, to: out)
                        if let url = resolveURL(urlStr, base: baseURL) {
                            out.addAttribute(.link, value: url,
                                             range: NSRange(location: subStart, length: out.length - subStart))
                        }
                        out.addAttribute(.foregroundColor, value: NSColor.systemBlue,
                                         range: NSRange(location: subStart, length: out.length - subStart))
                        out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                         range: NSRange(location: subStart, length: out.length - subStart))
                    }
                    i = closeParen + 1
                    continue
                }
                appendText(isImage ? "!" : "[", font: font, color: color, to: out)
                i += isImage ? 2 : 1
                continue
            }

            // 粗体 **
            if ch == "*", i + 1 < count, chars[i + 1] == "*" {
                if let j = findPair("*", "*", from: i + 2) {
                    let inner = String(chars[(i + 2)..<j])
                    appendInlineRuns(inner, font: baseFont, color: color,
                                     isBold: true, isItalic: isItalic, baseURL: baseURL, to: out)
                    i = j + 2
                    continue
                }
                appendText("**", font: font, color: color, to: out)
                i += 2
                continue
            }
            // 斜体 *
            if ch == "*" {
                if let j = find("*", from: i + 1) {
                    let inner = String(chars[(i + 1)..<j])
                    appendInlineRuns(inner, font: baseFont, color: color,
                                     isBold: isBold, isItalic: true, baseURL: baseURL, to: out)
                    i = j + 1
                    continue
                }
                appendText("*", font: font, color: color, to: out)
                i += 1
                continue
            }
            // 斜体 _（仅在词边界触发，避免把 a_b 当斜体）
            if ch == "_" {
                if wordBoundaryBefore(i), i + 1 < count,
                   let j = find("_", from: i + 1), j > i + 1, wordBoundaryAfter(j) {
                    let inner = String(chars[(i + 1)..<j])
                    appendInlineRuns(inner, font: baseFont, color: color,
                                     isBold: isBold, isItalic: true, baseURL: baseURL, to: out)
                    i = j + 1
                    continue
                }
                appendText("_", font: font, color: color, to: out)
                i += 1
                continue
            }
            // 删除线 ~~
            if ch == "~", i + 1 < count, chars[i + 1] == "~" {
                if let j = findPair("~", "~", from: i + 2) {
                    let inner = String(chars[(i + 2)..<j])
                    let subStart = out.length
                    appendInlineRuns(inner, font: baseFont, color: color,
                                     isBold: isBold, isItalic: isItalic, baseURL: baseURL, to: out)
                    out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                     range: NSRange(location: subStart, length: out.length - subStart))
                    i = j + 2
                    continue
                }
            }

            // 普通字符
            appendText(String(ch), font: font, color: color, to: out)
            i += 1
        }
    }
}
