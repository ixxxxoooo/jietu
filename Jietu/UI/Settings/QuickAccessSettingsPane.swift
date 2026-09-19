import AppKit
import Combine
import SwiftUI

struct QuickAccessSettingsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.quickAccessPosition) {
                    ForEach(QuickAccessPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                } label: {
                    Text(L10n.quickAccessDockPosition)
                    Text(L10n.quickAccessDockPositionDesc)
                }

                Picker(selection: $settings.quickAccessAutoCloseDelay) {
                    Text(L10n.quickAccessSeconds(1)).tag(TimeInterval(1))
                    Text(L10n.quickAccessSeconds(3)).tag(TimeInterval(3))
                    Text(L10n.quickAccessSeconds(5)).tag(TimeInterval(5))
                    Text(L10n.quickAccessSeconds(10)).tag(TimeInterval(10))
                    Text(L10n.quickAccessSeconds(30)).tag(TimeInterval(30))
                    Text(L10n.quickAccessSeconds(60)).tag(TimeInterval(60))
                    Text(L10n.quickAccessNever).tag(TimeInterval(0))
                } label: {
                    Text(L10n.quickAccessAutoClose)
                    Text(L10n.quickAccessAutoCloseDesc)
                }
            } header: {
                SettingsSectionHeader(title: L10n.quickAccessSectionTitle)
            }
        }
        .formStyle(.grouped)
    }
}

/// 标注：编辑方式 + 默认样式。
///
/// @author ixxxxoooo
