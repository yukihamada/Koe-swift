import Foundation

func klog(_ msg: String) {
    NSLog("[Koe] %@", msg)
    let line = msg + "\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/koe_log.txt"
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        fh.seekToEndOfFile()
        try? fh.write(contentsOf: data)
        try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
