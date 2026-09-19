import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 截图落地：裁剪 → 剪贴板 / 磁盘 / 快门音。
enum CaptureOutput {
    // MARK: - Crop

    /// 把某块显示器上的 local 选区（point）裁成像素图。
    ///
    /// 注意 Y 轴翻转：local 原点在左下，CGImage 原点在左上。
    static func crop(_ snapshot: DisplaySnapshot, toLocalRect rect: CGRect) -> CGImage? {
        let scale = snapshot.effectiveScale
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: (snapshot.screenFrameInPoints.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral

        let imageBounds = CGRect(origin: .zero, size: snapshot.pixelSize)
        let clamped = pixelRect.intersection(imageBounds)
        guard !clamped.isEmpty else { return nil }
        return snapshot.image.cropping(to: clamped)
    }

    // MARK: - Encode

    static func pngData(_ image: CGImage) -> Data? {
        encode(image, as: .png)
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.9) -> Data? {
        encode(image, as: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(
        _ image: CGImage,
        as type: UTType,
        options: [CFString: Any]? = nil
    ) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData,
                type.identifier as CFString,
                1,
                nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Pasteboard

    /// 同时写 PNG 与 TIFF：PNG 保真（浏览器、Slack 优先用它），
    /// TIFF 兼容性最好（原生 App、Numbers 之类只认它）。
    @discardableResult
    static func copyToPasteboard(_ image: CGImage) -> Bool {
        let item = NSPasteboardItem()
        if let png = pngData(image) {
            item.setData(png, forType: .png)
        }
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    // MARK: - Disk

    /// 保存为图片，文件名由模板展开（默认 `Jietu 2026-09-15 at 20.01.23.png`，同名自动加序号）。
    static func save(
        _ image: CGImage,
        toDirectory directory: URL,
        format: SaveFormat = .png,
        quality: Double = 0.9,
        nameTemplate: String = FilenameTemplate.defaultTemplate,
        date: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data: Data?
        switch format {
        case .png:
            data = pngData(image)
        case .jpeg:
            data = jpegData(image, quality: quality)
        }
        guard let data else {
            throw CaptureOutputError.encodingFailed
        }

        let url = try uniqueURL(
            in: directory, nameTemplate: nameTemplate, fileExtension: format.fileExtension, date: date
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 把**已有文件**搬进保存目录（录屏的 mp4 走这条：先写临时文件，收工才落盘）。
    ///
    /// 命名规则与截图完全一致（模板 + 同名自动加序号）——两处共用 `uniqueURL`。
    static func moveFile(
        _ source: URL,
        toDirectory directory: URL,
        nameTemplate: String = FilenameTemplate.defaultTemplate,
        fileExtension: String = "mp4",
        date: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try uniqueURL(
            in: directory, nameTemplate: nameTemplate, fileExtension: fileExtension, date: date
        )
        try FileManager.default.moveItem(at: source, to: url)
        return url
    }

    /// 复制一份已有文件到保存目录（录屏「另存为 MP4」走这条：主副本留在历史目录，另存一份给用户）。
    ///
    /// 命名规则与 `moveFile` 完全一致。
    static func copyFile(
        _ source: URL,
        toDirectory directory: URL,
        nameTemplate: String = FilenameTemplate.defaultTemplate,
        fileExtension: String = "mp4",
        date: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try uniqueURL(
            in: directory, nameTemplate: nameTemplate, fileExtension: fileExtension, date: date
        )
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// 按命名模板算出一个**目录里还不存在**的文件 URL（同名就追加 -1 / -2 …）。
    static func uniqueURL(
        in directory: URL,
        nameTemplate: String,
        fileExtension: String,
        date: Date = Date()
    ) throws -> URL {
        let counter = FilenameTemplate.nextCounter(
            template: nameTemplate,
            in: directory,
            fileExtension: fileExtension
        )
        let base = FilenameTemplate.makeName(template: nameTemplate, date: date, counter: counter)
        var url = directory.appendingPathComponent("\(base).\(fileExtension)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        return url
    }

    // MARK: - Sound

    private static let shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component"
            + "/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let sound = NSSound(contentsOfFile: path, byReference: true) {
            return sound
        }
        return NSSound(named: NSSound.Name("Pop"))
    }()

    static func playShutterSound() {
        shutterSound?.stop()
        shutterSound?.play()
    }
}

enum CaptureOutputError: LocalizedError {
    case encodingFailed
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "截图编码失败"
        case .emptySelection: return "选区为空"
        }
    }
}
