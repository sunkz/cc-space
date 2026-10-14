#!/usr/bin/env bash
# 造一份「点得动」的本地演示数据:真实 bare 远端 + 每个工作区下的真实克隆,
# 覆盖 clean / dirty / ahead / behind / diverged / stash 六种仓库状态。
#
# 用法:
#   ./script/make_demo_data.sh                 # 重建 /tmp/CCSpaceDemo
#   CCSPACE_DEMO_ROOT=/some/dir ./script/make_demo_data.sh
#   CCSPACE_APP_SUPPORT_DIR=/tmp/CCSpaceDemo/app-support ./run.sh
#
# 数据源是 script/readme-screenshot-fixture/*.json(仓库/工作区的 id 与命名以它为准),
# 本脚本只负责把占位路径落成真实目录并补上 git 历史,不改动 fixture 本身。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_ROOT="${CCSPACE_DEMO_ROOT:-/tmp/CCSpaceDemo}"
FIXTURE_DIR="${ROOT_DIR}/script/readme-screenshot-fixture"

# 只清"确认是演示目录"的路径:CCSPACE_DEMO_ROOT 可以指到任意目录,
# 误指 $HOME 或某个挂载点时下面的 rm -rf 就是毁数据。已存在的目录必须带 marker 才允许清空。
case "${DEMO_ROOT}" in
    ""|"/"|"${HOME}")
        echo "拒绝把演示根目录设成: '${DEMO_ROOT}'" >&2
        exit 1
        ;;
esac
if [ -e "${DEMO_ROOT}" ] && [ ! -f "${DEMO_ROOT}/.ccspace-demo-root" ]; then
    echo "拒绝清空非演示目录(缺少 .ccspace-demo-root 标记): ${DEMO_ROOT}" >&2
    exit 1
fi

rm -rf "${DEMO_ROOT}"
mkdir -p "${DEMO_ROOT}/remotes" "${DEMO_ROOT}/seeds" "${DEMO_ROOT}/workspaces" "${DEMO_ROOT}/app-support"
# 标记文件:既是"下次允许清空"的凭据,也提醒人肉检查时这是脚本产物。
touch "${DEMO_ROOT}/.ccspace-demo-root"

python3 - "${DEMO_ROOT}" "${FIXTURE_DIR}" <<'PY'
import json
import pathlib
import subprocess
import sys
import uuid

demo_root = pathlib.Path(sys.argv[1]).resolve()
fixture = pathlib.Path(sys.argv[2])
support = demo_root / "app-support"

def load(name):
    return json.loads((fixture / name).read_text(encoding="utf-8"))

repositories = load("repositories.json")
workplaces = load("workplaces.json")
settings = load("settings.json")

def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)

def configure_identity(path):
    run("git", "-C", str(path), "config", "user.name", "CCSpace Demo")
    run("git", "-C", str(path), "config", "user.email", "demo@ccspace.local")

# 每个仓库的默认分支:fixture 里都是 main,个别仓库造 develop 让分支菜单有层次。
DEFAULT_BRANCH = {repo["repoName"]: repo.get("defaultBranch") or "main" for repo in repositories}
EXTRA_BRANCHES = {repo["repoName"]: ["release/1.0"] for repo in repositories}

# 1) 远端:每仓库一个 bare 库,先推默认分支,再推若干长期分支。
#    gitURL 一并改写成这个真实 bare 路径——克隆出来的 origin 与配置里的 URL 完全一致,
#    app 的磁盘刷新/去重才不会把演示仓库判成"来源不符"。
for repo in repositories:
    name = repo["repoName"]
    default_branch = DEFAULT_BRANCH[name]
    remote = demo_root / "remotes" / f"{name}.git"
    repo["gitURL"] = str(remote)
    seed = demo_root / "seeds" / name
    run("git", "init", "--bare", "-b", default_branch, str(remote))
    run("git", "init", "-b", default_branch, str(seed))
    configure_identity(seed)
    (seed / "README.md").write_text(f"# {name}\n\nCCSpace 演示仓库,可安全增删提交。\n", encoding="utf-8")
    (seed / "status.txt").write_text(f"{name} baseline\n", encoding="utf-8")
    (seed / "pipeline.yml").write_text(f"job: {name}\nenv: none\n", encoding="utf-8")
    run("git", "-C", str(seed), "add", ".")
    run("git", "-C", str(seed), "commit", "-m", "Initial commit")
    run("git", "-C", str(seed), "remote", "add", "origin", str(remote))
    run("git", "-C", str(seed), "push", "-u", "origin", default_branch)
    for branch in EXTRA_BRANCHES[name]:
        run("git", "-C", str(seed), "checkout", "-b", branch, default_branch)
        run("git", "-C", str(seed), "push", "-u", "origin", branch)
    run("git", "-C", str(seed), "checkout", default_branch)

# 2) 工作区:fixture 里只有 analytics-sprint 配了仓库,其余是空壳(点开什么都看不到)。
#    这里按主题给每个工作区补齐分支与仓库选择,再真实克隆,并轮转造出各种仓库状态。
STATES = ["clean", "dirty", "ahead", "behind", "diverged", "stash"]
repo_by_id = {repo["id"]: repo for repo in repositories}
id_by_name = {repo["repoName"]: repo["id"] for repo in repositories}

WORKPLACE_PLAN = {
    # 名称: (工作分支, 纳入的仓库)
    "analytics-sprint":  ("feature/analytics-dashboard", ["api-gateway", "ios-app", "release-tools", "shared-ui"]),
    "growth-experiment": ("feature/growth-experiment",   ["api-gateway", "shared-ui"]),
    "ios-release":       ("release/1.0",                 ["ios-app", "shared-ui", "docs-portal"]),
    "docs-refresh":      ("docs/refresh-2026q2",         ["docs-portal", "api-gateway"]),
    "ops-hotfix":        ("hotfix/ops-incident-4821",    ["api-gateway", "release-tools"]),
    "marketing-weekly":  ("feature/marketing-weekly",    ["docs-portal", "shared-ui"]),
}

for workplace in workplaces:
    plan = WORKPLACE_PLAN.get(workplace["name"])
    if plan is None:
        continue
    branch, repo_names = plan
    workplace["path"] = str(demo_root / "workspaces" / workplace["name"])
    workplace["branch"] = branch
    workplace["selectedRepositoryIDs"] = [id_by_name[n] for n in repo_names if n in id_by_name]

state_cycle = iter(STATES * 4)

for workplace in workplaces:
    wp_dir = pathlib.Path(workplace["path"])
    wp_dir.mkdir(parents=True, exist_ok=True)
    branch = workplace["branch"]
    for repo_id in workplace["selectedRepositoryIDs"]:
        repo = repo_by_id.get(repo_id)
        if repo is None:
            continue
        name = repo["repoName"]
        default_branch = DEFAULT_BRANCH[name]
        remote = demo_root / "remotes" / f"{name}.git"
        local = wp_dir / name
        seed = demo_root / "seeds" / name

        # 工作区分支只在种子库里造一次,推给远端后各处克隆共用。
        run("git", "-C", str(seed), "fetch", "origin", "--prune")
        probe = subprocess.run(
            ["git", "-C", str(seed), "rev-parse", "--verify", "--quiet", f"origin/{branch}"],
            capture_output=True, text=True,
        )
        if probe.returncode != 0:
            run("git", "-C", str(seed), "checkout", "-b", branch, f"origin/{default_branch}")
            (seed / "status.txt").write_text(f"{name} baseline\n{branch} baseline\n", encoding="utf-8")
            run("git", "-C", str(seed), "add", "status.txt")
            run("git", "-C", str(seed), "commit", "-m", f"{branch}: baseline")
            run("git", "-C", str(seed), "push", "-u", "origin", branch)
            run("git", "-C", str(seed), "checkout", default_branch)

        run("git", "clone", str(remote), str(local))
        configure_identity(local)
        run("git", "-C", str(local), "checkout", branch)

        state = next(state_cycle)
        if state == "dirty":
            (local / "status.txt").write_text(f"{name} baseline\n{branch} baseline\n未提交的改动\n", encoding="utf-8")
            (local / "scratch-notes.md").write_text("临时文件,演示未跟踪状态。\n", encoding="utf-8")
        elif state == "ahead":
            (local / "status.txt").write_text(f"{name} baseline\n{branch} baseline\n本地领先\n", encoding="utf-8")
            run("git", "-C", str(local), "add", "status.txt")
            run("git", "-C", str(local), "commit", "-m", "本地领先一笔提交")
        elif state in ("behind", "diverged"):
            worker = demo_root / "remote-workers" / f"{workplace['name']}-{name}"
            run("git", "clone", str(remote), str(worker))
            configure_identity(worker)
            run("git", "-C", str(worker), "checkout", branch)
            (worker / "status.txt").write_text(f"{name} baseline\n{branch} baseline\n远端领先\n", encoding="utf-8")
            run("git", "-C", str(worker), "add", "status.txt")
            run("git", "-C", str(worker), "commit", "-m", "远端领先一笔提交")
            run("git", "-C", str(worker), "push")
            if state == "diverged":
                (local / "status.txt").write_text(f"{name} baseline\n{branch} baseline\n本地另一笔\n", encoding="utf-8")
                run("git", "-C", str(local), "add", "status.txt")
                run("git", "-C", str(local), "commit", "-m", "分叉:本地这笔与远端冲突")
            (worker / "pipeline.yml").write_text(f"job: {name}\nenv: demo\n", encoding="utf-8")
            run("git", "-C", str(worker), "add", "pipeline.yml")
            run("git", "-C", str(worker), "commit", "-m", "远端顺手改了下个提交要的内容")
            run("git", "-C", str(worker), "push")
            run("git", "-C", str(local), "fetch", "origin")
            # behind 只 fetch 不合并,让"落后 N 个提交"可见;diverged 保留本地分叉。
            subprocess.run(["rm", "-rf", str(worker)], check=False)
        elif state == "stash":
            (local / "status.txt").write_text(f"{name} baseline\n{branch} baseline\n被暂存的改动\n", encoding="utf-8")
            run("git", "-C", str(local), "stash", "push", "-m", "演示用 stash:改到一半")
            (local / "README.md").write_text(f"# {name}\n\n改到一半又被 stash 走了。\n", encoding="utf-8")
            run("git", "-C", str(local), "stash", "push", "-m", "第二条 stash")
            run("git", "-C", str(local), "stash", "pop")   # 留一条在列表里,另一条已弹回
            run("git", "-C", str(local), "checkout", "--", "README.md")

# 5) 落盘:sync-states 交给 app 自己扫真实仓库生成,这里只给空数组。
settings["workplaceRootPath"] = str(demo_root / "workspaces")

def dump(name, data):
    (support / name).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

dump("settings.json", settings)
dump("repositories.json", repositories)
dump("workplaces.json", workplaces)
dump("sync-states.json", [])

clones = sorted(
    f"{p.parent.parent.name}/{p.parent.name}" for p in demo_root.glob("workspaces/*/*/.git")
)
print(f"演示数据已生成: {demo_root}")
print(f"  工作区 {len(workplaces)} 个 / 仓库配置 {len(repositories)} 个")
print(f"  真实克隆 {len(clones)} 份: " + ", ".join(clones))
PY
