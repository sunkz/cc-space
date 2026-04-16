import SwiftUI

struct SidebarView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var workplaceStore: WorkplaceStore
    let hasUpdate: Bool
    let onCreateWorkplace: () -> Void
    @State private var searchText = ""

    private var filteredWorkplaces: [Workplace] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return workplaceStore.workplaces }
        return workplaceStore.workplaces.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
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
                ForEach(filteredWorkplaces) { workplace in
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
                    .offset(x: -11)
                }
                .padding(.bottom, 6)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, placement: .sidebar)
        .navigationTitle("CCSpace")
    }

    @ViewBuilder
    private func workplaceRow(_ workplace: Workplace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(workplace.name)
                .lineLimit(1)
            Spacer()
            Text("\(workplace.selectedRepositoryIDs.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
