import AppKit
import Testing
@testable import Jietu

/// CaptureOutput.crop 在不同缩放因子下的边界测试——重点验证 Retina 缩放。
///
/// @author ygw
@Suite("截图输出 Retina 裁剪")
struct CaptureOutputRetinaTests {

    @Test("1x 缩放下裁剪像素与点坐标一致")
    func crop1xScale() {
        let image = TestImage.solidColor(width: 100, height: 100, r: 0, g: 128, b: 128)
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            nominalScaleFactor: 1,
            image: image
        )
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        let cropped = CaptureOutput.crop(snapshot, toLocalRect: rect)
        #expect(cropped != nil)
        #expect(cropped!.width == 50)
        #expect(cropped!.height == 50)
    }

    @Test("2x Retina 裁剪像素尺寸是点尺寸的两倍")
    func crop2xRetina() {
        // 200×200 像素图代表 100×100 点的屏幕（2x Retina）
        let image = TestImage.solidColor(width: 200, height: 200)
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            nominalScaleFactor: 2,
            image: image
        )
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        let cropped = CaptureOutput.crop(snapshot, toLocalRect: rect)
        #expect(cropped != nil)
        #expect(cropped!.width == 100, "2x Retina 下 50pt 宽应裁出 100px")
        #expect(cropped!.height == 100, "2x Retina 下 50pt 高应裁出 100px")
    }

    @Test("3x 缩放裁剪像素尺寸是点尺寸的三倍")
    func crop3xScale() {
        let image = TestImage.solidColor(width: 300, height: 300, r: 64, g: 64, b: 64)
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            nominalScaleFactor: 3,
            image: image
        )
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cropped = CaptureOutput.crop(snapshot, toLocalRect: rect)
        #expect(cropped != nil)
        #expect(cropped!.width == 300)
        #expect(cropped!.height == 300)
    }

    @Test("非整数缩放因子正确计算像素范围")
    func cropFractionalScale() {
        // 150×150 像素图代表 100×100 点的屏幕（effectiveScale = 1.5）
        let image = TestImage.solidColor(width: 150, height: 150)
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            nominalScaleFactor: 1,
            image: image
        )
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cropped = CaptureOutput.crop(snapshot, toLocalRect: rect)
        #expect(cropped != nil)
        #expect(cropped!.width == 150)
        #expect(cropped!.height == 150)
    }

    @Test("超出图像边界的选区被夹回有效范围")
    func cropClampedToImageBounds() {
        let image = TestImage.solidColor(width: 200, height: 200)
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            nominalScaleFactor: 2,
            image: image
        )
        // 选区超出右边和上边
        let rect = CGRect(x: 80, y: 80, width: 50, height: 50)
        let cropped = CaptureOutput.crop(snapshot, toLocalRect: rect)
        #expect(cropped != nil, "超出边界时应裁剪到可用范围而非返回 nil")
        #expect(cropped!.width <= 200)
        #expect(cropped!.height <= 200)
    }

    @Test("零面积选区返回 nil")
    func cropZeroAreaReturnsNil() {
        let image = TestImage.solidColor(width: 200, height: 200)
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            nominalScaleFactor: 2,
            image: image
        )
        let cropped = CaptureOutput.crop(snapshot, toLocalRect: .zero)
        #expect(cropped == nil, "零面积选区应返回 nil")
    }

    @Test("Retina 下 Y 轴翻转正确")
    func crop2xYAxisFlip() throws {
        // 上半红、下半蓝的 2x Retina 图
        let image = TestImage.horizontalBands(
            width: 200, height: 200,
            rows: Array(repeating: (255, 0, 0) as (UInt8, UInt8, UInt8), count: 100)
                + Array(repeating: (0, 0, 255) as (UInt8, UInt8, UInt8), count: 100)
        )
        let snapshot = DisplaySnapshot(
            displayID: 1,
            screenFrameInPoints: CGRect(x: 0, y: 0, width: 100, height: 100),
            nominalScaleFactor: 2,
            image: image
        )
        // local 坐标系左下角原点，选上半区（y=50..100）→ CGImage 上顶部（红色区域）
        let cropped = try #require(
            CaptureOutput.crop(snapshot, toLocalRect: CGRect(x: 0, y: 50, width: 100, height: 50))
        )
        let sample = try #require(PixelSampler.sample(cropped, atPixel: CGPoint(x: 1, y: 1)))
        #expect(sample.red == 255, "上半区应为红色")
        #expect(sample.blue == 0)
    }
}
