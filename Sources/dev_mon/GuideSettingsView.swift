import SwiftUI
import AppKit

/// 设置窗口里的「指南」页：把每份文档作为独立页签展示（docs/*.md，排除 CHANGELOG.md），
/// 并用 MarkdownRenderer 渲染成富文本，经 NSTextView 显示；找不到文档时显示空态。
struct GuideSettingsView: View {
    @State private var documents: [URL] = []
    @State private var selectedIndex = 0
    @State private var rendered: NSAttributedString?
    @State private var loadFailed = false

    private var selectedDoc: URL? {
        documents.indices.contains(selectedIndex) ? documents[selectedIndex] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if documents.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabBar
                Divider().padding(.horizontal, 12)
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onChange(of: selectedIndex) { _, _ in renderDocument() }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let r = rendered {
            RichTextScrollView(attributed: r)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            Text(Strings.guideLoadFailed)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(18)
        } else {
            ProgressView().padding(20)
        }
    }

    // MARK: - 页签栏（每份文档一个页签）

    private var tabBar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $selectedIndex) {
                ForEach(documents.indices, id: \.self) { idx in
                    Text(displayTitle(for: documents[idx])).tag(idx)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let url = selectedDoc {
                toolbarButton(systemName: "arrow.up.forward.square", help: Strings.guideOpenExternal) {
                    NSWorkspace.shared.open(url)
                }
                toolbarButton(systemName: "folder", help: Strings.guideReveal) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func toolbarButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(Strings.guideNoDocsTitle)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(Strings.guideNoDocsHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Data

    private func load() {
        documents = DocsLocator.locateDocuments()
        guard !documents.isEmpty else { return }
        if !documents.indices.contains(selectedIndex) { selectedIndex = 0 }
        renderDocument()
    }

    private func renderDocument() {
        guard let url = selectedDoc else {
            rendered = nil
            loadFailed = true
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            rendered = MarkdownRenderer.attributedString(from: text,
                                                         baseURL: url.deletingLastPathComponent())
            loadFailed = false
        } catch {
            rendered = nil
            loadFailed = true
        }
    }

    /// 由文件名生成人类可读标题：how-it-works.md → "How It Works"，ui-guide.md → "UI Guide"。
    private func displayTitle(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let acronyms: Set<String> = ["ui", "api", "aws", "ai", "url", "sse", "http", "https"]
        let words = base.split(separator: "-").map { seg -> String in
            let lower = seg.lowercased()
            if acronyms.contains(lower) { return lower.uppercased() }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return words.joined(separator: " ")
    }
}

// MARK: - 富文本显示（NSTextView 承载 MarkdownRenderer 输出）

private struct RichTextScrollView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.allowsUndo = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        tv.delegate = context.coordinator
        scroll.documentView = tv
        apply(textView: tv, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        apply(textView: tv, scroll: scroll)
    }

    /// 按当前宽度重新排版并让文本视图高度匹配内容。
    private func apply(textView tv: NSTextView, scroll: NSScrollView) {
        let inset = tv.textContainerInset
        let contentW = max(scroll.contentSize.width, 200)
        tv.textContainer?.containerSize = NSSize(width: contentW - inset.width * 2,
                                                 height: .greatestFiniteMagnitude)
        tv.frame = NSRect(x: 0, y: 0, width: contentW, height: 1)
        tv.textStorage?.setAttributedString(attributed)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!) ?? .zero
        // 文档高度至少铺满可视区，更长则交给 NSScrollView 内部滚动
        tv.frame.size.height = max(used.height + inset.height * 2 + 6, scroll.contentSize.height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
