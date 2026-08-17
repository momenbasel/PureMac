import Foundation

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> Result {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Result(status: 127, out: "", err: "not found: \(launchPath)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return Result(status: 126, out: "", err: (error as NSError).localizedDescription)
        }

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "puremac.shell.drain", attributes: .concurrent)
        q.async(group: group) { outData = outPipe.fileHandleForReading.readDataToEndOfFile() }
        q.async(group: group) { errData = errPipe.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }
}
