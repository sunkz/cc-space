# AGENTS.md

## 项目概述

CCSpace 是一个 **macOS 原生应用**（Swift 6.0 / SwiftUI，最低支持 macOS 14），用于多 Git 仓库的工作区管理：配置常用仓库、按需组合创建工作区、并行克隆、统一管理分支与同步状态。

这是一个 **Swift Package Manager** 项目（非 Xcode 工程），没有 `.xcodeproj`；构建、运行、测试全部通过 `swift` 命令或 `./run.sh` 完成。

## 常用命令

```bash
./run.sh            # 构建并启动 app（默认行为）
./run.sh build      # 仅构建 debug 产物
./run.sh test       # 运行单元测试（推荐：内部与 CI 一致直接驱动 xctest）
./run.sh lint       # 校验 shell 脚本语法 + 以 warnings-as-errors 编译
./run.sh clean      # 清理 .build/ 与 dist/

swift build         # 直接用 SwiftPM 构建（CI 中最常用的快速编译验证）
swift test          # ⚠️ 勿用：部分工具链会确定性死锁（2026-09），测试一律走 ./run.sh test
```

- **提交前务必** `./run.sh lint`（warnings 会被当作错误）。
- 仅做快速编译验证时 `swift build` 足够；改动涉及 SwiftPM 依赖或 ObjC 桥接时跑 `./run.sh build`。

## 架构分层

源码在 `Sources/CCSpace/` 下，严格分层，**不要跨层直接依赖**：

| 层 | 目录 | 职责 | 注意事项 |
|---|---|---|---|
| **App 入口** | `CCSpace.swift` | `@main`，请求通知权限，挂载 `RootSplitView` | |
| **AppState** | `AppState/` | `AppViewModel`（导航/选中状态，`@MainActor`）、`AppRoute`、`SidebarSelection` | 路由与选中状态统一在这里，View 不直接改 route |
| **Models** | `Models/` | 纯数据结构（`Workplace`、`AppSettings`、`RepositoryConfig` 等），值类型 | |
| **Stores** | `Stores/` | `ObservableObject`，持久化领域状态（`SettingsStore`/`RepositoryStore`/`WorkplaceStore`），基于 `JSONFileStore` | View 持有 `@StateObject` |
| **Services** | `Services/` | 无 UI 的业务逻辑（`GitService`、`SyncCoordinator`、`WorkplaceRuntimeService`、`NotificationService`、`UpdateChecker` 等），多为 `Sendable`/`actor` | View 不直接调 git，必须经 Store/Coordinator |
| **Views** | `Views/` | SwiftUI 视图 | 只负责展示与转发，业务逻辑下沉到 Service/Store |

依赖方向：`Views → AppState/Stores → Services → Models`。Service 之间可相互协作，但 **View 不应直接 new Service 做业务**（除了由 `RootSplitView` 顶层持有并注入）。

## 关键约定

### Swift / SwiftUI
- 全项目 `@MainActor` 为默认心智模型；Service 若被 `async` 调用则保持 `Sendable`。
- 外部 git 进程通过 `GitProcessRunner`（`Services/GitProcessRunner.swift`）执行，固定用 `/usr/bin/git`（按候选路径探测），**不要**引入第三方 git 库。
- ObjC 异常捕获桥接在 `Sources/ObjCExceptionCatch`（普通 `import ObjCExceptionCatch`；SwiftPM 未开启 library evolution，不要用 `@_implementationOnly`，会告警），仅 `GitProcessRunner` 等调用 Cocoa 进程 API 时用于兜底。
- Git 错误信息要本地化为中文（见 `GitService.localizeMessage`）；面向用户的所有文案为**简体中文**。
- 数据持久化统一走 `JSONFileStore`（`Services/JSONFileStore.swift`），不要在 Service 里手写 `JSONEncoder` 落盘。

### 测试
- 运行测试用 `./run.sh test`（run.sh 与 CI 均直接驱动 `xcrun xctest`，以绕开 2026-09 起 swift-package 测试执行器的确定性死锁）；**不要**直接 `swift test`。
- 测试在 `Tests/CCSpaceTests/`，命名 `<Subject>Tests.swift`；新增公开类型或纯函数逻辑通常都应有对应测试。
- 共享夹具/工具在 `Tests/CCSpaceTests/TestSupport/`。
- UI 行为（SwiftUI）通常通过抽取纯 `PresentationState`/`Support` 结构体来测试，而不是驱动 View。

### 脚本与发布
- `release.sh [patch|minor|major|x.y.z]` 打 tag 推送，GitHub Actions 构建 universal binary 并发 Release——**不要本地手动打包发布**。
- README 截图由 `script/generate_readme_screenshots.sh`（`./run.sh readme-screenshots`）基于 `script/readme-screenshot-fixture/` 演示数据重建，仅覆盖 README 当前引用的图。

## 已知坑点

- 平台：仅 macOS 14+，**不要**引入 iOS-only API（如 `UIKit`）。
- `.zcode/`、`.build/`、`dist/`、`.swiftpm/` 均已被 gitignore，改动产物不要提交。
- SwiftPM 重新解析依赖较慢；若只改 Swift 源码，优先 `swift build` 而非打开 Xcode。
