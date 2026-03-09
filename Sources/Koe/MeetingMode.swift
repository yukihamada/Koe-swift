import Foundation
import AppKit

class MeetingMode: ObservableObject {
    static let shared = MeetingMode()

    @Published var isActive = false
    @Published var entryCount = 0
    private var outputURL: URL?
    private var fileHandle: FileHandle?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let name = "Koe_議事録_\(fmt.string(from: Date())).txt"
        let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        outputURL = url
        isActive = true
        entryCount = 0
        klog("MeetingMode: started \(name)")

        let header = "# Koe 議事録\n開始: \(Date())\n\n"
        fileHandle?.write(Data(header.utf8))
    }

    func stop() {
        try? fileHandle?.close()
        fileHandle = nil
        isActive = false
        klog("MeetingMode: stopped (\(entryCount)件)")
        if let url = outputURL {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        }
    }

    func append(text: String) {
        guard isActive else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(text)\n"
        fileHandle?.write(Data(line.utf8))
        entryCount += 1
    }
}
