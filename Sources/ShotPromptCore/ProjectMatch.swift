import Foundation

// Picks the T3 project a capture is about from the window it was taken in, so
// the picker starts there. It looks at the window only on this Mac; nothing
// it reads goes into the prompt. Each step returns its project only when
// exactly one matches; two or more means it cannot tell, and the picker keeps
// its default.
//
// 1. A path: the window's file, a path in its title (terminals, editors), or
//    the folder of the server behind a localhost page (`serverFolder`).
// 2. A GitHub or GitLab address: the repository name is a project's folder name.
// 3. The title: one of its parts ("Config.swift — shot-prompt") is a
//    project's folder name or T3 title.
public func matchProject(_ w: WindowInfo, serverFolder: String?, projects: [Project],
                         home: String = NSHomeDirectory()) -> String? {
    let steps: [() -> Set<String>] = [
        { matchByPath(paths(w, serverFolder: serverFolder, home: home), projects) },
        { matchByRepo(w.document ?? w.webURL, projects) },
        { matchByTitle(w.title, projects) },
    ]
    for step in steps {
        let roots = step()
        if roots.count == 1 { return roots.first }
        if roots.count > 1 { return nil }
    }
    return nil
}

private func folderName(_ root: String) -> String {
    ((root as NSString).standardizingPath as NSString).lastPathComponent.lowercased()
}

private func paths(_ w: WindowInfo, serverFolder: String?, home: String) -> [String] {
    var list = [filePath(fromDocument: w.document), serverFolder].compactMap { $0 }
    for word in (w.title ?? "").split(whereSeparator: { $0.isWhitespace || $0 == ":" }) {
        let s = String(word)
        if s.hasPrefix("/") { list.append(s) }
        if s == "~" || s.hasPrefix("~/") { list.append(home + s.dropFirst()) }
    }
    return list
}

// For each path, the project with the longest root that holds it. A T3
// worktree (~/.t3/worktrees/<project folder>/<branch>) counts as its project.
private func matchByPath(_ paths: [String], _ projects: [Project]) -> Set<String> {
    var roots = Set<String>()
    for raw in paths {
        let path = (raw as NSString).standardizingPath
        let holders = projects.filter {
            let root = ($0.root as NSString).standardizingPath
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        if let best = holders.max(by: { $0.root.count < $1.root.count }) {
            roots.insert(best.root)
            continue
        }
        let parts = (path as NSString).pathComponents
        if let i = parts.firstIndex(of: "worktrees"), i > 0, parts[i - 1] == ".t3", i + 1 < parts.count {
            let name = parts[i + 1].lowercased()
            roots.formUnion(projects.filter { folderName($0.root) == name }.map(\.root))
        }
    }
    return roots
}

private func matchByRepo(_ address: String?, _ projects: [Project]) -> Set<String> {
    guard let address, let c = URLComponents(string: address),
          let host = c.host?.lowercased(), host == "github.com" || host == "gitlab.com" else { return [] }
    let parts = c.path.split(separator: "/")
    guard parts.count >= 2 else { return [] }
    var repo = parts[1].lowercased()
    if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
    return Set(projects.filter { folderName($0.root) == repo }.map(\.root))
}

// Window titles join their parts with these.
let titleSeparators = [" — ", " – ", " - ", " · ", " | ", " / ", " • "]

private func matchByTitle(_ title: String?, _ projects: [Project]) -> Set<String> {
    guard var rest = title else { return [] }
    for s in titleSeparators { rest = rest.replacingOccurrences(of: s, with: "\u{0}") }
    let parts = Set(rest.split(separator: "\u{0}").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { $0.count >= 3 })
    return Set(projects.filter { parts.contains(folderName($0.root)) || parts.contains($0.title.lowercased()) }
        .map(\.root))
}

// The port of a page served from this Mac, whose server's folder can name the project.
public func localPort(_ address: String?) -> Int? {
    guard let address, let c = URLComponents(string: address), let host = c.host?.lowercased(),
          ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) else { return nil }
    return c.port
}

// The first value of a field in `lsof -F` output: "p123" for a PID, "n/path" for a name.
public func lsofField(_ output: String, _ field: Character) -> String? {
    for line in output.split(separator: "\n") where line.first == field && line.count > 1 {
        return String(line.dropFirst())
    }
    return nil
}
