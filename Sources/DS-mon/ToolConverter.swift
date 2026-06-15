import Foundation
// MARK: - 工具转换 (Responses API → Chat Completions)

func convertTools(_ tools: [JSONValue]?) -> [JSONValue] {
    guard let tools else { return [] }
    let denied = toolDenylist()
    var out: [JSONValue] = []
    for tool in tools {
        guard let obj = tool.objectValue, let type = obj["type"]?.stringValue else { continue }
        switch type {
        case "function":
            if let name = obj["name"]?.stringValue {
                if denied.contains(name) { continue }
                out.append(convertSingleTool(tool, overrideName: nil))
            }
        case "namespace":
            if let namespace = obj["name"]?.stringValue,
               let subs = obj["tools"]?.arrayValue {
                for sub in subs {
                    guard let subObj = sub.objectValue,
                          subObj["type"]?.stringValue == "function",
                          let fnName = subObj["name"]?.stringValue else { continue }
                    let chatName = chatFunctionNameForNamespace(namespace: namespace, name: fnName)
                    if denied.contains(chatName) { continue }
                    out.append(convertSingleTool(sub, overrideName: chatName))
                }
            }
        default:
            break
        }
    }
    return out
}

private func convertSingleTool(_ tool: JSONValue, overrideName: String?) -> JSONValue {
    guard let obj = tool.objectValue else { return tool }
    if obj["function"] != nil {
        var t = tool
        if let name = overrideName,
           var funcObj = obj["function"]?.objectValue {
            funcObj["name"] = .string(name)
            if case .object(var root) = t {
                root["function"] = .object(funcObj)
                t = .object(root)
            }
        }
        return t
    }
    var fn: [String: JSONValue] = [:]
    if let name = overrideName {
        fn["name"] = .string(name)
    } else if let v = obj["name"] {
        fn["name"] = v
    }
    if let v = obj["description"] { fn["description"] = v }
    if let v = obj["parameters"] { fn["parameters"] = v }
    if let v = obj["strict"] { fn["strict"] = v }
    return .object([
        "type": .string("function"),
        "function": .object(fn)
    ])
}

func chatFunctionNameForNamespace(namespace: String, name: String) -> String {
    "\(namespace)-\(name)"
}

private func toolDenylist() -> Set<String> {
    guard let env = ProcessInfo.processInfo.environment["CODEX_RELAY_TOOL_DENYLIST"],
          !env.isEmpty else { return [] }
    return Set(env.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
    })
}

func namespaceToolMap(_ tools: [JSONValue]?) -> [String: (namespace: String, name: String)] {
    guard let tools else { return [:] }
    var map: [String: (namespace: String, name: String)] = [:]
    for tool in tools {
        guard let obj = tool.objectValue,
              obj["type"]?.stringValue == "namespace",
              let namespace = obj["name"]?.stringValue,
              let subs = obj["tools"]?.arrayValue else { continue }
        for sub in subs {
            guard let subObj = sub.objectValue,
                  subObj["type"]?.stringValue == "function",
                  let fn = subObj["name"]?.stringValue else { continue }
            let chatName = chatFunctionNameForNamespace(namespace: namespace, name: fn)
            map[chatName] = (namespace: namespace, name: fn)
        }
    }
    return map
}

func responseFunctionNameForResponses(
    _ name: String,
    namespaceTools: [String: (namespace: String, name: String)]
) -> (namespace: String?, name: String) {
    if let entry = namespaceTools[name] {
        return (namespace: entry.namespace, name: entry.name)
    }
    return splitMCPFunctionName(name)
}

private func splitMCPFunctionName(_ name: String) -> (namespace: String?, name: String) {
    if let dotIdx = name.firstIndex(of: ".") {
        let ns = String(name[..<dotIdx])
        let child = String(name[name.index(after: dotIdx)...])
        if !ns.isEmpty && !child.isEmpty {
            return (namespace: ns, name: child)
        }
    }
    if let rest = name.removingPrefix("mcp__"),
       let serverEnd = rest.range(of: "__") {
        let splitAt = name.distance(from: name.startIndex, to: serverEnd.upperBound)
        if splitAt < name.count {
            let ns = String(name.prefix(splitAt))
            let child = String(name.suffix(name.count - splitAt))
            return (namespace: ns, name: child)
        }
    }
    return (namespace: nil, name: name)
}

extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
