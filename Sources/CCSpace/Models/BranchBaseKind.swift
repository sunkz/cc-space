import Foundation

/// 新建分支的基线种类(分支弹窗行尾 ➕ 的隐式基线)。
///
/// 视图层不再用裸 `String?` 表达基线:远端页签同样提供创建入口后,
/// "本地分支 x" 与 "远端分支 x" 必须可区分——前者直接作 rev,
/// 后者要先 fetch 刷新 `origin/x` 引用再作 rev,否则拿到的可能是过期的
/// 本地跟踪引用。
enum BranchBaseKind: Equatable, Sendable {
    /// 无显式基线:从当前 HEAD 创建(`checkout -b <name>`)。
    case currentHead
    /// 以本地分支为基线(`checkout -b <name> <branch>`)。
    case localBranch(String)
    /// 以远端分支为基线,收裸名(`fetch` 刷新后 `checkout -b <name> origin/<branch>`)。
    case remoteBranch(String)
}
