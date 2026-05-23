import SwiftUI

struct SidebarView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var workplaceStore: WorkplaceStore
    let syncStates: [RepositorySyncState]
    let hasUpdate: Bool
    let onCreateWorkplace: () -> Void
    let onTogglePinned: (Workplace) -> Void
    let onDuplicateWorkplace: (Workplace) -> Void
    let onToggleArchived: (Workplace) -> Void
    @State private var searchText = ""

    private var presentationState: SidebarPresentationState {
        SidebarPresentationState(
            workplaces: workplaceStore.workplaces,
            searchText: searchText
        )
    }

    var body: some View {
        List(selection: $appViewModel.sidebarSelection) {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("设置")
                    if hasUpdate {
                        Spacer()
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("有可用更新")
                    }
                }
                .tag(SidebarSelection.route(.settings))
            }

            Section {
                ForEach(presentationState.activeWorkplaces) { workplace in
                    workplaceRow(workplace)
                        .tag(SidebarSelection.workplace(workplace.id))
                }
            } header: {
                HStack {
                    Text("工作区")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .overlay(alignment: .trailing) {
                    Button {
                        onCreateWorkplace()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: .command)
                    .offset(x: -11)
                }
                .padding(.bottom, 6)
            }

            if !presentationState.archivedWorkplaces.isEmpty {
                Section("已归档") {
                    ForEach(presentationState.archivedWorkplaces) { workplace in
                        workplaceRow(workplace)
                            .tag(SidebarSelection.workplace(workplace.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar)
        .navigationTitle("CCSpace")
    }

    @ViewBuilder
    private func workplaceRow(_ workplace: Workplace) -> some View {
        let rowPresentationState = SidebarWorkplaceRowPresentationState(
            workplace: workplace,
            syncStates: syncStates
        )

        HStack(spacing: 8) {
            Image(systemName: workplace.isArchived ? "archivebox" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(workplace.name)
                .lineLimit(1)
            Spacer()
            HStack(spacing: rowPresentationState.accessorySpacing) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .opacity(rowPresentationState.showsPinnedIndicator ? 1 : 0)
                    .frame(width: rowPresentationState.pinIndicatorColumnWidth)
                    .accessibilityHidden(!rowPresentationState.showsPinnedIndicator)
                if let color = rowPresentationState.statusIndicatorColor {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
                Text(rowPresentationState.repositoryCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(
                        width: rowPresentationState.repositoryCountColumnWidth,
                        alignment: .trailing
                    )
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onTogglePinned(workplace)
            } label: {
                Label(
                    workplace.isPinned ? "取消置顶" : "置顶工作区",
                    systemImage: workplace.isPinned ? "pin.slash" : "pin"
                )
            }
            .help(workplace.isPinned ? "取消后按字母排序" : "置顶后始终显示在列表顶部")

            Button {
                onDuplicateWorkplace(workplace)
            } label: {
                Label("复制工作区", systemImage: "doc.on.doc")
            }
            .help("以当前配置为模板创建新工作区")

            Button {
                onToggleArchived(workplace)
            } label: {
                Label(
                    workplace.isArchived ? "取消归档" : "归档工作区",
                    systemImage: workplace.isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }
            .help(workplace.isArchived ? "从归档中恢复到活跃列表" : "归档后工作区不会被删除，可随时恢复")
        }
    }
}
