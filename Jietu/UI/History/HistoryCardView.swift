import AppKit
import SwiftUI

/// 历史卡片快捷操作栏上的动作。
enum HistoryQuickAction: CaseIterable {
    case copy, pin, reveal, edit

    var title: String {
        switch self {
        case .copy: L10n.historyCopy
        case .pin: L10n.historyPin
        case .reveal: L10n.historyReveal
        case .edit: L10n.historyEdit
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .pin: "pin"                      // 与浮窗 / 原地工具栏的「钉图」同一枚
        case .reveal: "folder"
        case .edit: "pencil.tip.crop.circle"
        }
    }

    var help: String {
        switch self {
        case .copy: L10n.historyCopyTooltip
        case .pin: L10n.historyPinTooltip
        case .reveal: L10n.historyRevealTooltip
        case .edit: L10n.historyEditTooltip
        }
    }
}

/// 单张截图预览卡片。
struct HistoryCardView: View {
    let item: HistoryItem
    var onSelect: (HistoryItem) -> Void
    var onRevealInFinder: ((HistoryItem) -> Void)?
    var onCopy: ((HistoryItem) -> Void)?
    var onPin: ((HistoryItem) -> Void)?

    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            // 标头信息行：拍摄时间 + 分辨率或大小
            HStack(spacing: 6) {
                Text(item.timeFormatted)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer(minLength: 4)

                if let info = item.isVideo
                    ? item.fileSizeDescription : (item.resolutionDescription ?? item.fileSizeDescription)
                {
                    Text(info)
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 2)

            // 缩略图视窗（等比适配，深色衬底防反光）
            ZStack {
                shape
                    .fill(Theme.Colors.iconPlaceholder)

                if let image = item.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 110)
                        .clipShape(shape)
                } else {
                    Text(L10n.historyCannotRead)
                        .font(Theme.Typography.rowSubtitle)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                // 录屏条目：封面正中挂一枚「▶ 0:12」——一眼看出这是段视频、多长
                // （和录屏收工那张浮窗卡片同一套语言）。
                if let duration = item.videoDuration {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(QuickAccessVideoView.durationText(duration))
                            .font(Theme.Typography.numeric)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(.black.opacity(0.55)))
                }
            }
            .overlay(
                shape.strokeBorder(
                    isHovered ? Theme.Colors.accent.opacity(0.4) : Theme.Colors.cardStroke,
                    lineWidth: Theme.Size.hairline
                )
            )

            // 快捷操作栏
            HStack(spacing: 8) {
                Spacer()

                ForEach(
                    item.quickActions(
                        canCopy: onCopy != nil,
                        canPin: onPin != nil,
                        canReveal: onRevealInFinder != nil
                    ),
                    id: \.self
                ) { action in
                    actionButton(action)
                }
            }
            .opacity(isHovered ? 1.0 : 0.75)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.08) : Theme.Colors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    isHovered ? Theme.Colors.accent.opacity(0.5) : Theme.Colors.cardStroke,
                    lineWidth: Theme.Size.hairline
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(item)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// 操作栏里的按钮：动作由 `HistoryItem.quickActions` 决定，这里只管各自动作长什么样。
    @ViewBuilder
    private func actionButton(_ action: HistoryQuickAction) -> some View {
        switch action {
        case .copy:
            Button {
                onCopy?(item)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                chip(
                    symbol: copied ? "checkmark" : action.symbol,
                    title: copied ? L10n.historyCopied : action.title,
                    tint: copied ? Theme.Colors.success : Theme.Colors.textSecondary
                )
            }
            .buttonStyle(.plain)
            .help(action.help)

        case .pin:
            Button { onPin?(item) } label: {
                chip(symbol: action.symbol, title: action.title, tint: Theme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(action.help)

        case .reveal:
            Button { onRevealInFinder?(item) } label: {
                chip(symbol: action.symbol, title: action.title, tint: Theme.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(action.help)

        case .edit:
            Button { onSelect(item) } label: {
                chip(symbol: action.symbol, title: action.title, tint: Theme.Colors.accent, filled: true)
            }
            .buttonStyle(.plain)
            .help(action.help)
        }
    }

    /// 操作栏里那枚小胶囊（图标 + 文字）。
    private func chip(
        symbol: String,
        title: String,
        tint: Color,
        filled: Bool = false
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(filled ? tint.opacity(0.12) : Color.white.opacity(0.08))
        )
    }
}
