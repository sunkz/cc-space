import Foundation

/// 新建分支的基线:currentHead 用 HEAD、localBranch 直接作 rev、
/// remoteBranch 收裸名且必须先 fetch 刷新 `origin/x` 再作 rev(否则可能是过期的本地跟踪引用)。
enum BranchBaseKind: Equatable, Sendable {
    case currentHead
    case localBranch(String)
    case remoteBranch(String)
}
