import Foundation

func klog(_ msg: String) {
    NSLog("[Koe] %@", msg)
    let line = msg + "\n"
    guard let data = line.data(using: .utf8) else { return }
    // ~/Library/Logs/Koe/ に 0700 で保存（/tmp はワールドリーダブルなので避ける）
    let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Koe")
    let path = logDir.appendingPathComponent("koe.log")
    let fm = FileManager.default
    if !fm.fileExists(atPath: logDir.path) {
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }
    if let fh = try? FileHandle(forWritingTo: path) {
        fh.seekToEndOfFile()
        try? fh.write(contentsOf: data)
        try? fh.close()
    } else {
        try? data.write(to: path, options: .atomic)
        // ファイルパーミッション 0600
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
