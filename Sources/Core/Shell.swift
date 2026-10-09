import Foundation

/// 跑命令行小工具（只用于 netstat / ps / smartctl / system_profiler 这类只读查询）。
///
/// 读输出与等进程退出是**并发**的：子进程输出一旦超过管道缓冲（64KB）就会堵在写端，
/// "先等退出再读"的老写法会截断尾部、甚至拖到超时——`sfltool dumpbtm` 实测 58KB，
/// 就贴着上限。stderr 直接进 /dev/null（没人读它，留着管道同样会堵）。
enum Shell {
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        execute(launchPath, args, timeout: timeout).output
    }

    /// 同上，但把退出码也带回来（SSH 探测这类要看 status）。-1 = 启动失败，-2 = 超时被杀。
    static func runStatus(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5) -> (output: String, status: Int32) {
        let outcome = execute(launchPath, args, timeout: timeout)
        return (outcome.output, outcome.status)
    }

    private struct Outcome {
        var output: String
        var status: Int32
    }

    private static let nullDevice = FileHandle.nullDevice

    private static func execute(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = nullDevice

        // 读端持续排空管道，EOF 时发信号（availableData 为空 = 对端关了管道）
        var data = Data()
        let lock = NSLock()
        let drained = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                lock.lock(); data.append(chunk); lock.unlock()
            }
        }

        guard (try? process.run()) != nil else {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Outcome(output: "", status: -1)
        }

        // waitUntilExit 没有超时版本，放到后台线程等，主等待带超时
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            exited.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()                       // SIGTERM，再宽限 1 秒后 SIGKILL
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        _ = drained.wait(timeout: .now() + 2)         // 把管道里剩下的收完再走
        lock.lock()
        let output = String(data: data, encoding: .utf8) ?? ""
        lock.unlock()
        return Outcome(output: output, status: timedOut ? -2 : process.terminationStatus)
    }

    /// 在常见路径里找一个可执行文件（本机 Homebrew 装在 /opt/homebrew）。
    static func which(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
