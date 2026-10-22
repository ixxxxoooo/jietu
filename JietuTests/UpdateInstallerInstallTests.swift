import Foundation
import Testing

@testable import Jietu

/// 「替换并重启」阶段：安装脚本的换位 / 回滚、原地安装拦截。
struct UpdateInstallerInstallTests {
    private func setUp() async throws -> (dir: URL, installDir: URL, old: URL, new: URL, log: URL) {
        let dir = UpdateFixtures.tempDir()
        let installDir = dir.appendingPathComponent("Applications")
        let newDir = dir.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let old = try await UpdateFixtures.makeApp(at: installDir, version: "1.0.0", marker: "old")
        let new = try await UpdateFixtures.makeApp(at: newDir, version: "2.0.0", marker: "new")
        return (dir, installDir, old, new, dir.appendingPathComponent("update.log"))
    }

    @Test func 脚本用新版替换旧版并清理暂存() async throws {
        let s = try await setUp()
        let sut = UpdateInstaller(workDirectory: s.dir.appendingPathComponent("work"))
        let process = try sut.launchInstaller(
            newApp: s.new, destination: s.old, pid: try UpdateFixtures.deadPID(), logURL: s.log,
            relaunch: false)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let marker = s.old.appendingPathComponent("Contents/marker.txt")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "new")
        // 暂存 / 旧版备份都清掉，目录里只剩目标 App。
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.installDir.path) == [UpdateFixtures.appName])
        #expect(try String(contentsOf: s.log, encoding: .utf8).contains("installed"))
    }

    @Test func 替换后的App仍然通过签名校验() async throws {
        let s = try await setUp()
        let sut = UpdateInstaller(workDirectory: s.dir.appendingPathComponent("work"))
        try sut.launchInstaller(
            newApp: s.new, destination: s.old, pid: try UpdateFixtures.deadPID(), logURL: s.log,
            relaunch: false
        ).waitUntilExit()
        let verify = await UpdateInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", s.old.path])
        #expect(verify.status == 0, "\(verify.output)")
    }

    @Test func 新包不存在时保留旧版并且不留垃圾() async throws {
        let s = try await setUp()
        let missing = s.dir.appendingPathComponent("not-exist/\(UpdateFixtures.appName)")
        let sut = UpdateInstaller(workDirectory: s.dir.appendingPathComponent("work"))
        let process = try sut.launchInstaller(
            newApp: missing, destination: s.old, pid: try UpdateFixtures.deadPID(), logURL: s.log,
            relaunch: false)
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        let marker = s.old.appendingPathComponent("Contents/marker.txt")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.installDir.path) == [UpdateFixtures.appName])
    }

    @Test func 脚本会等旧进程退出再动手() async throws {
        let s = try await setUp()
        // 起一个 2 秒后才退出的进程当「旧 App」。
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["2"]
        try sleeper.run()

        let sut = UpdateInstaller(workDirectory: s.dir.appendingPathComponent("work"))
        let process = try sut.launchInstaller(
            newApp: s.new, destination: s.old, pid: sleeper.processIdentifier, logURL: s.log,
            relaunch: false)
        try await Task.sleep(for: .milliseconds(700))
        let marker = s.old.appendingPathComponent("Contents/marker.txt")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old", "旧进程还活着时不应替换")

        process.waitUntilExit()
        #expect(try String(contentsOf: marker, encoding: .utf8) == "new")
    }

    @Test func 原地安装的拦截条件() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Jietu.app")
        #expect(UpdateInstaller.inPlaceInstallBlocker(for: translocated) != nil)
        #expect(UpdateInstaller.inPlaceInstallBlocker(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")) != nil)
        #expect(UpdateInstaller.inPlaceInstallBlocker(for: URL(fileURLWithPath: "/tmp/not-an-app")) != nil)
        let writable = UpdateFixtures.tempDir().appendingPathComponent(UpdateFixtures.appName)
        #expect(UpdateInstaller.inPlaceInstallBlocker(for: writable) == nil)
    }

    @Test func 子进程助手合并输出并返回退出码() async {
        let ok = await UpdateInstaller.run("/bin/sh", ["-c", "echo out; echo err 1>&2"])
        #expect(ok.status == 0)
        #expect(ok.output.contains("out") && ok.output.contains("err"))
        let fail = await UpdateInstaller.run("/bin/sh", ["-c", "exit 3"])
        #expect(fail.status == 3)
        let missing = await UpdateInstaller.run("/no/such/binary", [])
        #expect(missing.status != 0)
    }
}
