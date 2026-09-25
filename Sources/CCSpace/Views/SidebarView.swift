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
    @AppStorage("SidebarView.workplaceSortMode") private var workplaceSortMode: WorkplaceSortMode = .name

    private var presentationState: SidebarPresentationState {
        SidebarPresentationState(
            workplaces: workplaceStore.workplaces,
            searchText: searchText,
            sortMode: workplaceSortMode
        )
    }

    private var failedWorkplaceIDs: Set<UUID> {
        Set(syncStates.filter { $0.status == .failed }.map(\.workplaceID))
    }

    var body: some View {
        // presentationState 与 failedWorkplaceIDs 都是每次访问全量重算的计算属性:
        // body 顶部各取一次沿渲染路径复用,避免一次渲染重复过滤/排序、逐行重建 Set。
        let state = presentationState
        let failedIDs = failedWorkplaceIDs
        return VStack(spacing: 0) {
            List(selection: $appViewModel.sidebarSelection) {
                Section {
                    ForEach(state.activeWorkplaces) { workplace in
                        workplaceRow(workplace, failedWorkplaceIDs: failedIDs)
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
                        HStack(spacing: 10) {
                            Menu {
                                Picker("排序方式", selection: $workplaceSortMode) {
                                    ForEach(WorkplaceSortMode.allCases) { mode in
                                        Text(mode.title).tag(mode)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .controlSize(.small)
                            .frame(width: 22, height: 22)
                            .accessibilityLabel("排序方式")
                            .ccspaceQuickHelp("选择工作区排序方式")

                            Button {
                                onCreateWorkplace()
                            } label: {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                            // 不用 Cmd+N:macOS 惯例是"新建窗口",占用后用户按不出
                            // 预期行为且没有对应菜单项告知。Cmd+Shift+N 与"新增"语义一致。
                            .keyboardShortcut("n", modifiers: [.command, .shift])
                            .accessibilityLabel("新增工作区")
                        }
                        // 修正 header 与行的尾随缩进差,使新建按钮与行尾置顶图标中心线上下对齐(-9 为离屏实测值)。
                        .offset(x: -9)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                }

                if !state.archivedWorkplaces.isEmpty {
                    Section("已归档") {
                        ForEach(state.archivedWorkplaces) { workplace in
                            workplaceRow(workplace, failedWorkplaceIDs: failedIDs)
                                .tag(SidebarSelection.workplace(workplace.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "搜索工作区名称或分支")
            .toolbar {
                ToolbarItem {
                    Button {
                        appViewModel.showRoute(.settings)
                    } label: {
                        Image(systemName: "gearshape")
                            .overlay(alignment: .topTrailing) {
                                if hasUpdate {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 2, y: -2)
                                        .accessibilityLabel("有可用更新")
                                }
                            }
                    }
                    .help("设置")
                    .accessibilityLabel("设置")
                }
            }
        }
    }

    @ViewBuilder
    private func workplaceRow(
        _ workplace: Workplace,
        failedWorkplaceIDs: Set<UUID>
    ) -> some View {
        let branchName = workplace.branch?.trimmingCharacters(in: .whitespacesAndNewlines)

        SidebarWorkplaceRowView(
            workplace: workplace,
            hasFailed: failedWorkplaceIDs.contains(workplace.id),
            branchName: branchName,
            onTogglePinned: onTogglePinned,
            onDuplicateWorkplace: onDuplicateWorkplace,
            onToggleArchived: onToggleArchived
        )
    }
}
