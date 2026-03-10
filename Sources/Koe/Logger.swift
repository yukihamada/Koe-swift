import Foundation

private let logQueue = DispatchQueue(label: "com.yuki.koe.logger", qos: .utility)
private var logBuffer: [String] = []
private var flushTimer: DispatchSourceTimer?
private let logDir: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Koe")
    if !FileManager.default.fileExists(atPath: dir.path) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
    }
    return dir
}()
private let logPath = logDir.appendingPathComponent("koe.log")

func klog(_ msg: String) {
    NSLog("[Koe] %@", msg)
    logQueue.async {
        logBuffer.append(msg)
        if logBuffer.count >= 20 {
            flushLogs()
        } else if flushTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: logQueue)
            timer.schedule(deadline: .now() + 2)
            timer.setEventHandler { flushLogs() }
            timer.resume()
            flushTimer = timer
        }
    }
}

private func flushLogs() {
    guard !logBuffer.isEmpty else { return }
    let lines = logBuffer.joined(separator: "\n") + "\n"
    logBuffer.removeAll()
    flushTimer?.cancel()
    flushTimer = nil
    guard let data = lines.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: logPath) {
        fh.seekToEndOfFile()
        try? fh.write(contentsOf: data)
        try? fh.close()
    } else {
        try? data.write(to: logPath, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath.path)
    }
}
