import Foundation

// A LaunchAgent starts with a bare PATH; t3-dispatch needs node and git.
public func childPath(home: URL) -> String {
    "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
}

// The prompt as sent, or nil when there is nothing to send.
public func sendablePrompt(_ text: String) -> String? {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return prompt.isEmpty ? nil : prompt
}

// Runs `<executable> --cwd <cwd> --image <image> <prompt>` and waits. Returns
// whether it exited 0, and its trimmed stdout and stderr.
public func dispatch(executable: String, prompt: String, image: URL, cwd: String,
                     environment: [String: String], home: URL) -> (ok: Bool, output: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = ["--cwd", cwd, "--image", image.path, prompt]
    var childEnv = environment
    childEnv["PATH"] = childPath(home: home)
    task.environment = childEnv
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return (false, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return (task.terminationStatus == 0, out)
}
