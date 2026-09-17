import SwiftUI
import AppKit

/// 设置窗口里的「指南」页：左侧是可折叠的目录树（**文档 ▸ 章节**），
/// 右侧用 MarkdownRenderer 渲染成富文本、经 NSTextView 显示（docs/*.md，排除 CHANGELOG.md）。
/// 点击章节跳到对应标题；找不到文档时显示空态。
struct GuideSettingsView: View {
    /// 单份文档的渲染结果 + 目录（章节偏移只在渲染后才知道，所以两者一起缓存）
    private struct DocContent {
        let attributed: NSAttributedString
        let outline: [MarkdownRenderer.OutlineItem]
    }

    @State private var documents: [URL] = []
    @State private var selectedIndex = 0
    /// 所有文档一次性渲染并缓存：侧边栏要在**未选中**的文档下列出章节，
    /// 且偏移必须来自该文档的真实渲染结果（文档都是几 KB，代价可忽略）。
    @State private var docs: [Int: DocContent] = [:]
    @State private var loadFailed = false
    /// 待滚动请求（带 token，所以连续点同一个章节也会重新滚动）
    @State private var scrollRequest: RichTextScrollRequest?
    @State private var scrollToken = 0
    @ObservedObject private var uiState = UIStateStore.shared

    private var selectedDoc: URL? {
        documents.indices.contains(selectedIndex) ? documents[selectedIndex] : nil
    }

    private var selectedContent: DocContent? { docs[selectedIndex] }

    var body: some View {
        Group {
            if documents.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: 200)
                    Divider()
                    VStack(spacing: 0) {
                        contentHeader
                        Divider()
                        contentArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
    }

    // MARK: - 侧边栏（文档 ▸ 章节，可折叠）

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(documents.indices, id: \.self) { idx in
                    sidebarDocument(idx)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private func sidebarDocument(_ idx: Int) -> some View {
        let url = documents[idx]
        let key = UIStateStore.Key.guideDoc(slug(url))
        let expanded = uiState.bool(key, default: true)
        // 只列 h2 / h3：文档标题（h1）已经是父节点本身。
        let headings = (docs[idx]?.outline ?? []).filter { $0.level >= 2 && $0.level <= 3 }

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    uiState.setBool(key, !expanded)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(expanded ? Strings.sectionsCollapseAll : Strings.sectionsExpandAll)

                Button {
                    selectDocument(idx)
                } label: {
                    Text(displayTitle(for: url))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(idx == selectedIndex ? .primary : .secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(idx == selectedIndex ? Color.accentColor.opacity(0.14) : Color.clear)
            .cornerRadius(4)

            if expanded {
                ForEach(headings) { heading in
                    sidebarHeading(heading, docIndex: idx)
                }
            }
        }
    }

    /// 章节行：按层级缩进（h2 一级、h3 两级），点击滚动到该标题。
    private func sidebarHeading(_ item: MarkdownRenderer.OutlineItem, docIndex: Int) -> some View {
        Button {
            selectHeading(item, docIndex: docIndex)
        } label: {
            Text(item.title)
                .font(.system(size: 11, weight: item.level == 2 ? .regular : .light))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 13 + CGFloat(item.level - 1) * 11)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(item.title)
    }

    // MARK: - 内容头部（当前文档 + 外部打开 / 在 Finder 中显示）

    private var contentHeader: some View {
        HStack(spacing: 6) {
            Text(selectedDoc.map { displayTitle(for: $0) } ?? "")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(.secondary)
            Spacer()
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
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var contentArea: some View {
        if let content = selectedContent {
            RichTextScrollView(attributed: content.attributed, scrollRequest: scrollRequest)
                .id(selectedIndex)   // 切文档时重建文本视图，滚动位置从头开始
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
        renderAll()
    }

    /// 一次性渲染所有文档，缓存富文本 + 目录。
    /// 侧边栏要在未选中的文档下列出章节，而章节偏移只有渲染后才知道 —— 分文档懒加载
    /// 会让「点别的文档的章节」需要两跳，所以这里直接全渲染（总量只有几 KB）。
    private func renderAll() {
        var result: [Int: DocContent] = [:]
        var failures = 0
        for (idx, url) in documents.enumerated() {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let rendered = MarkdownRenderer.render(markdown: text,
                                                       baseURL: url.deletingLastPathComponent())
                result[idx] = DocContent(attributed: rendered.attributed, outline: rendered.outline)
            } catch {
                failures += 1
            }
        }
        docs = result
        loadFailed = result.isEmpty && failures > 0
        if result[selectedIndex] == nil, let first = result.keys.min() { selectedIndex = first }
    }

    private func selectDocument(_ idx: Int) {
        selectedIndex = idx
        scrollRequest = nextScroll(location: 0)
    }

    private func selectHeading(_ item: MarkdownRenderer.OutlineItem, docIndex: Int) {
        selectedIndex = docIndex
        scrollRequest = nextScroll(location: item.location)
    }

    /// token 递增 —— 重复点同一个章节也会触发一次滚动。
    private func nextScroll(location: Int) -> RichTextScrollRequest {
        scrollToken += 1
        return RichTextScrollRequest(location: location, token: scrollToken)
    }

    /// 由文件名生成稳定 slug（用于持久化展开状态）：how-it-works.md → "how-it-works"。
    private func slug(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
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

/// 一次「滚动到某个字符偏移」的请求。带 token，所以重复点同一个章节也会重新滚动。
private struct RichTextScrollRequest: Equatable {
    let location: Int
    let token: Int
}

private struct RichTextScrollView: NSViewRepresentable {
    let attributed: NSAttributedString
    var scrollRequest: RichTextScrollRequest?

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
        context.coordinator.lastAttributed = attributed
        applyScroll(textView: tv, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // 只在内容真的换了时重排：`apply` 会重设整个 attributed string，
        // 在每次 SwiftUI 刷新时调用会把读者已经滚动到的位置抹掉。
        if context.coordinator.lastAttributed !== attributed {
            apply(textView: tv, scroll: scroll)
            context.coordinator.lastAttributed = attributed
        }
        applyScroll(textView: tv, coordinator: context.coordinator)
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

    /// 把请求的字符偏移滚进可视区；同一个 token 只滚一次。
    private func applyScroll(textView tv: NSTextView, coordinator: Coordinator) {
        guard let request = scrollRequest, request.token != coordinator.lastScrollToken else { return }
        coordinator.lastScrollToken = request.token
        let length = tv.textStorage?.length ?? 0
        guard length > 0 else { return }
        let location = min(max(0, request.location), length - 1)
        tv.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastScrollToken: Int?
        var lastAttributed: NSAttributedString?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
            }
            return true
        }
    }
}
