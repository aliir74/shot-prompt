import Foundation

// Where Enter sends the screenshot and prompt.
public enum Target: String, CaseIterable, Equatable {
    // A coding agent's CLI, started in a new terminal window in the project folder.
    case claudeCode, codex, cursorAgent
    // A desktop chat app: it comes forward, a new chat opens, and the
    // screenshot and prompt are pasted into it for you to send.
    case claudeApp, chatGPT
    // `$SHOT_PROMPT_DISPATCH --cwd DIR --image PATH… PROMPT`: T3 Code, or your own script.
    case command
    // The screenshot and prompt go on the clipboard, to paste anywhere.
    case clipboard

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursorAgent: return "Cursor Agent"
        case .claudeApp: return "Claude app"
        case .chatGPT: return "ChatGPT app"
        case .command: return "Custom command (T3 Code)"
        case .clipboard: return "Clipboard"
        }
    }

    // The CLI a terminal target runs, or nil for the others.
    public var executable: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .cursorAgent: return "cursor-agent"
        case .claudeApp, .chatGPT, .command, .clipboard: return nil
        }
    }

    // The app a paste target pastes into, newest bundle ID first; empty for
    // the others. ChatGPT.app changed its ID from com.openai.chat.
    public var bundleIDs: [String] {
        switch self {
        case .claudeApp: return ["com.anthropic.claudefordesktop"]
        case .chatGPT: return ["com.openai.codex", "com.openai.chat"]
        case .claudeCode, .codex, .cursorAgent, .command, .clipboard: return []
        }
    }

    public var isChatApp: Bool { !bundleIDs.isEmpty }

    // Whether the target works in a project folder (and the panel shows the picker).
    public var usesProject: Bool { !isChatApp && self != .clipboard }
}

public let targetKey = "target"

// The target you picked; else the custom command when `$SHOT_PROMPT_DISPATCH`
// is set (an install from before targets existed); else the first one
// installed; else the clipboard, which needs nothing.
public func currentTarget(stored: String?, dispatchFromEnvironment: Bool,
                          isInstalled: (Target) -> Bool) -> Target {
    if let s = stored, let t = Target(rawValue: s) { return t }
    if dispatchFromEnvironment { return .command }
    let order: [Target] = [.claudeCode, .codex, .cursorAgent, .claudeApp, .chatGPT]
    return order.first(where: isInstalled) ?? .clipboard
}

// Folders a terminal's login shell usually has on its PATH, for finding a CLI
// from an app started with a bare PATH.
public func cliSearchPath(home: URL) -> [String] {
    [".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", ".cargo/bin"]
        .map { home.appendingPathComponent($0).path }
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
}

// The first executable file with this name in the folders, if any.
public func findExecutable(_ name: String, in folders: [String]) -> String? {
    folders.map { ($0 as NSString).appendingPathComponent(name) }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

// One argument for a POSIX shell: single-quoted, with each ' closed, escaped and reopened.
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// The prompt for a CLI that reads images by path: the paths go after the text.
public func promptWithImagePaths(_ prompt: String, images: [URL]) -> String {
    guard !images.isEmpty else { return prompt }
    let lines = images.map { "- " + $0.path }.joined(separator: "\n")
    let noun = images.count == 1 ? "Screenshot" : "Screenshots"
    return prompt + "\n\n\(noun) (read the image file\(images.count == 1 ? "" : "s")):\n" + lines
}

// The arguments after the CLI's name. Codex attaches images itself; Claude
// Code and Cursor Agent read them from the paths in the prompt. Claude Code
// gets their folder with --add-dir, so reading them asks for no permission.
public func terminalArguments(_ target: Target, prompt: String, images: [URL]) -> [String] {
    switch target {
    case .codex:
        return images.map { "--image=" + $0.path } + ["--", prompt]
    case .claudeCode where !images.isEmpty:
        let folder = images[0].deletingLastPathComponent().path
        return ["--add-dir", folder, "--", promptWithImagePaths(prompt, images: images)]
    default:
        return [promptWithImagePaths(prompt, images: images)]
    }
}

// The script a terminal runs: it deletes itself, goes to the project folder,
// and replaces itself with the CLI. `executable` is the CLI's full path when
// it was found; else its name, which the interactive login shell's PATH finds.
public func terminalScript(_ target: Target, executable: String?, prompt: String, images: [URL],
                           cwd: String) -> String {
    let cli = executable ?? target.executable ?? "false"
    let command = ([cli] + terminalArguments(target, prompt: prompt, images: images))
        .map(shellQuote).joined(separator: " ")
    return """
        #!/bin/zsh -il
        rm -f -- "$0"
        cd \(shellQuote(cwd)) || exit 1
        clear
        exec \(command)

        """
}

// Copies the images to a folder of their own, so a CLI that reads them later
// still finds them after the panel deletes its window shot. The copies get
// plain names (shot-1.png): macOS's own hold spaces and a narrow no-break
// space before AM/PM, which an agent retyping the path gets wrong. A HEIC
// (macOS's HDR capture) becomes a PNG, which every model reads.
public func stageImages(_ images: [URL], in folder: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return try images.enumerated().map { i, url in
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg"].contains(ext) {
            let copy = folder.appendingPathComponent("shot-\(i + 1).\(ext)")
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        }
        guard let png = pngData(of: url) else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
        let copy = folder.appendingPathComponent("shot-\(i + 1).png")
        try png.write(to: copy)
        return copy
    }
}

// Removes staged folders older than `maxAge`.
public func pruneStaged(in root: URL, now: Date, maxAge: TimeInterval) {
    let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for item in items {
        if let created = creationDate(item), now.timeIntervalSince(created) > maxAge {
            try? FileManager.default.removeItem(at: item)
        }
    }
}

// The project folders you sent to, most recent first.
public let recentFoldersKey = "recentFolders"
public let maxRecentFolders = 12

public func rememberFolder(_ folder: String, in list: [String], limit: Int = maxRecentFolders) -> [String] {
    let path = (folder as NSString).standardizingPath
    return Array(([path] + list.filter { ($0 as NSString).standardizingPath != path }).prefix(limit))
}

// T3's projects first (when T3 is installed), then the recent folders it
// does not have. Folders that are gone are left out.
public func mergeProjects(t3: [Project], recent: [String],
                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Project] {
    let known = Set(t3.map { ($0.root as NSString).standardizingPath })
    let extra = recent.map { ($0 as NSString).standardizingPath }
        .filter { !known.contains($0) && exists($0) }
        .map { Project(title: ($0 as NSString).lastPathComponent, root: $0) }
    return t3 + extra
}

// The folder the panel starts on: `$SHOT_PROMPT_CWD`, else the last folder
// you sent to that is still there, else the home folder.
public func startFolder(environment: String?, recent: [String], home: URL,
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
    environment ?? recent.first(where: exists) ?? home.path
}

// Where an app bundle can stay: login items and permissions bind to its path,
// so a copy run from the disk image or Downloads must be moved first.
public func isInApplicationsFolder(_ bundlePath: String, home: URL) -> Bool {
    let path = (bundlePath as NSString).standardizingPath
    return path.hasPrefix("/Applications/") || path.hasPrefix(home.appendingPathComponent("Applications").path + "/")
}

// The note on first launch: what to do, where it goes, and where the settings are.
public func welcomeText(target: Target, inApplications: Bool) -> String {
    let move = inApplications ? "" : "Move ShotPrompt to your Applications folder first, then open it from there.\n\n"
    let goes = target == .clipboard
        ? "No AI tool was found, so it goes to the clipboard: paste it into any chat."
        : "It goes to \(target.title) with your screenshot."
    return move + """
        Take a screenshot (Cmd+Shift+4), start typing, and press Enter. \(goes)

        The menu bar icon (a viewfinder) changes where it goes and what it sends. \
        macOS asks once for the Desktop folder, where screenshots are saved.
        """
}
