import SwiftUI

/// 工具条控件的悬停外形；底部操作组用胶囊，工具栏用圆角。
///
/// @author ixxxxoooo
enum BarButtonChrome {
    case capsule
    case rounded

    func shape() -> AnyShape {
        switch self {
        case .capsule:
            return AnyShape(Capsule())
        case .rounded:
            return AnyShape(
                RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous))
        }
    }
}

/// 工具条控件：**默认裸露，悬停才出现高亮**；选中态用 `controlSurface` 常驻填充。
///
/// 悬停状态收在控件自己这里，宿主不会因为指针移动而重绘。
/// 快捷键与 tooltip 直接落在内部 Button 上——套在容器外不可靠。
///
/// @author ixxxxoooo
struct BarButton<Label: View>: View {
    var chrome: BarButtonChrome = .capsule
    /// 常驻选中态（分段 / 工具选中）。
    var isSelected = false
    /// 悬停提示。
    var help: String?
    /// 可选快捷键。
    var key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var hovered = false

    var body: some View {
        let shape = chrome.shape()
        Button(action: action) {
            label
                .contentShape(shape)
                .background(shape.fill(fill))
        }
        .buttonStyle(.plain)
        // 去掉键盘焦点那圈蓝环：工具条靠悬停 / 选中底表达状态，蓝色焦点环只会打架。
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: Theme.Duration.hover), value: hovered)
        .keyboardShortcut(if: key, modifiers: modifiers)
        .helpIfPresent(help)
    }

    /// 选中常驻；否则悬停压一层比选中更淡的墨。
    private var fill: Color {
        if isSelected { return Theme.Colors.controlSurface }
        return hovered ? Theme.Colors.rowHover : .clear
    }
}

/// 一个纯图标工具按钮，尺寸统一走工具栏 token。
///
/// @author ixxxxoooo
struct BarIconButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var isSelected = false
    var chrome: BarButtonChrome = .rounded
    /// 悬停提示；不给就用 `title`。带快捷键的按钮把组合键一起说清楚。
    var help: String?
    var key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    let action: () -> Void

    var body: some View {
        BarButton(
            chrome: chrome,
            isSelected: isSelected,
            help: help ?? title,
            key: key,
            modifiers: modifiers,
            action: action
        ) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint ?? Theme.Colors.textSecondary)
                .frame(
                    width: Theme.Size.toolbarButtonWidth,
                    height: Theme.Size.toolbarButtonHeight
                )
        }
    }
}

extension Hotkey {
    /// SwiftUI `.keyboardShortcut` 要的那个字符；功能键之类取不到字符时为 nil。
    var keyEquivalent: KeyEquivalent? {
        guard let menuKey, let character = menuKey.first else { return nil }
        return KeyEquivalent(character)
    }

    /// SwiftUI `.keyboardShortcut` 要的修饰键集合。
    ///
    /// 从 `cocoaModifiers` 转，而不是直接读 Carbon 位：`Carbon.HIToolbox` 里
    /// 也有一个 `EventModifiers`，引进来会与 SwiftUI 的这个撞名。
    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        let flags = cocoaModifiers
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

extension View {
    /// 有快捷键才挂上，省掉调用点的可选分支。
    @ViewBuilder
    func keyboardShortcut(if key: KeyEquivalent?, modifiers: EventModifiers = .command) -> some View {
        if let key {
            keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }

    /// 有提示文案才挂上，避免空 tooltip。
    @ViewBuilder
    func helpIfPresent(_ text: String?) -> some View {
        if let text {
            help(text)
        } else {
            self
        }
    }
}
