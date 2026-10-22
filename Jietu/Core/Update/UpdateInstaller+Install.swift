import Foundation

/// 更新安装器的「替换并重启」阶段。
///
/// App 不能在运行中替换自己，所以起一个**独立的后台 shell 脚本**：
/// 等本进程退出 → 把新包 `ditto` 到同目录的暂存位置 → 去隔离属性 →
/// 两次 `mv` 原子换位（失败自动回滚旧版）→ `open` 重新打开。
/// 全程只 `open`（不带 `-n`），保证重启前后只有一个实例。
extension UpdateInstaller {
    /// 安装日志（脚本每步都写，App 已退出后仍可排查）。
    static var installLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Jietu/update.log")
    }

    /// 当前 App 能不能原地替换；不能时返回给用户看的原因（此时应引导手动安装）。
    static func inPlaceInstallBlocker(for bundleURL: URL) -> String? {
        guard bundleURL.pathExtension == "app" else {
            return L10n.s("update.error.not_app_bundle")
        }
        // 从 DMG / 下载目录直接运行的 App 会被系统「路径随机化」到只读位置。
        if bundleURL.path.contains("/AppTranslocation/") {
            return L10n.s("update.error.translocated")
        }
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return L10n.sf("update.error.not_writable", parent.path)
        }
        return nil
    }

    /// 生成安装脚本。参数依次为：旧进程 pid、新 App、目标 App、日志文件、是否重新打开（默认 1）。
    static let installScript = """
        #!/bin/sh
        PID="$1"; NEW="$2"; DEST="$3"; LOG="$4"; RELAUNCH="${5:-1}"
        log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
        mkdir -p "$(dirname "$LOG")"
        log "== update start: pid=$PID new=$NEW dest=$DEST"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          i=$((i + 1))
          if [ "$i" -gt 150 ]; then log "app did not quit within 30s, abort"; exit 1; fi
          sleep 0.2
        done
        PARENT="$(dirname "$DEST")"; NAME="$(basename "$DEST")"
        STAGE="$PARENT/.$NAME.update-new"; OLD="$PARENT/.$NAME.update-old"
        rm -rf "$STAGE" "$OLD"
        if ! /usr/bin/ditto "$NEW" "$STAGE"; then
          log "stage copy failed"; rm -rf "$STAGE"; [ "$RELAUNCH" = "1" ] && /usr/bin/open "$DEST"; exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null
        if ! mv "$DEST" "$OLD"; then
          log "move old aside failed"; rm -rf "$STAGE"; [ "$RELAUNCH" = "1" ] && /usr/bin/open "$DEST"; exit 1
        fi
        if ! mv "$STAGE" "$DEST"; then
          log "swap failed, rolling back"; mv "$OLD" "$DEST"; [ "$RELAUNCH" = "1" ] && /usr/bin/open "$DEST"; exit 1
        fi
        rm -rf "$OLD"
        log "installed, relaunch=$RELAUNCH"
        if [ "$RELAUNCH" = "1" ]; then /usr/bin/open "$DEST"; fi
        log "== update done"
        """

    /// 启动安装脚本。调用方随后应立刻退出 App。
    ///
    /// - Parameters:
    ///   - newApp: 已校验的新 App。
    ///   - destination: 要被替换的 App（当前运行的那个）。
    ///   - pid: 当前进程 id，脚本等它退出后才动手。
    ///   - logURL: 日志文件。
    ///   - relaunch: 替换完成后是否重新打开（测试里关掉，免得真去启动假 App）。
    /// - Returns: 脚本进程（调用方通常不管它；测试用来等它结束）。
    @discardableResult
    func launchInstaller(
        newApp: URL,
        destination: URL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        logURL: URL = UpdateInstaller.installLogURL,
        relaunch: Bool = true
    ) throws -> Process {
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let scriptURL = workDirectory.appendingPathComponent("install.sh")
            try Self.installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptURL.path, String(pid), newApp.path, destination.path, logURL.path, relaunch ? "1" : "0"]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try task.run()
            return task
        } catch {
            throw UpdateError.installerLaunchFailed(error.localizedDescription)
        }
    }

    /// 同步以外的子进程执行：合并 stdout / stderr，在后台队列读取，不占用协作线程池。
    @concurrent
    static func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.arguments = arguments
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe
                do {
                    try task.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (task.terminationStatus, text))
            }
        }
    }
}
