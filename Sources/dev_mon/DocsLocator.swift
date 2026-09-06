import Foundation

/// 帮助定位要展示的文档（`docs/*.md`，排除 CHANGELOG.md）。
///
/// 查找顺序（返回第一个包含可用 .md 的目录）：
///   1. 应用资源里的 `docs`（打包时由 scripts/build.sh 复制进 .app 的 Resources）
///   2. 当前工作目录下的 `docs`（从仓库根目录 `swift run` 运行时）
///   3. 从 bundle/可执行文件位置逐级向上查找名为 `docs` 的目录（覆盖其它启动方式）
enum DocsLocator {
    /// 返回候选文档 .md 文件（按文件名排序）；找不到时为空数组。
    static func locateDocuments() -> [URL] {
        for dir in candidateDirectories() {
            let docs = markdownFiles(in: dir)
            if !docs.isEmpty { return docs }
        }
        return []
    }

    // MARK: - Private

    private static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { dirs.append(url) }
        }

        // 1) 打包后的 .app 资源
        if let res = Bundle.main.resourceURL {
            add(res.appendingPathComponent("docs", isDirectory: true))
        }

        // 2) 当前工作目录（`swift run` 从仓库根目录执行时即仓库根目录）
        add(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs", isDirectory: true))

        // 3) 从 bundle 位置逐级向上（.app 位于 build/ 下；非 bundle 可执行文件从 .build/<cfg>/ 起）
        var cursor = Bundle.main.bundleURL
        for _ in 0..<6 {
            add(cursor.appendingPathComponent("docs", isDirectory: true))
            if cursor.pathComponents.count <= 2 { break }
            cursor.deleteLastPathComponent()
        }

        return dirs
    }

    private static func markdownFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls
            .filter { url in
                guard url.pathExtension.lowercased() == "md" else { return false }
                // 排除 CHANGELOG.md（不区分大小写）
                return url.deletingPathExtension().lastPathComponent.lowercased() != "changelog"
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
