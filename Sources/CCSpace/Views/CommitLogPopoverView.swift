import SwiftUI

struct CommitLogPopoverView: View {
    let repositoryName: String
    let commits: [GitCommitEntry]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                loadingView
            } else if commits.isEmpty {
                emptyView
            } else {
                commitList
            }
        }
        .frame(width: 420, height: 360)
    }

    private var header: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text(repositoryName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Text("\(commits.count) 条提交")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack {
            Spacer()
            Text("暂无提交记录")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var commitList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(commits) { commit in
                    CommitRowView(commit: commit)
                    if commit.id != commits.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }
}

private struct CommitRowView: View {
    let commit: GitCommitEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.blue)
                Text(commit.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(commit.date.relativeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private extension Date {
    var relativeDescription: String {
        let now = Date.now
        let interval = now.timeIntervalSince(self)
        guard interval >= 0 else { return "刚刚" }

        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)

        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if hours < 24 { return "\(hours) 小时前" }
        if days < 30 { return "\(days) 天前" }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
