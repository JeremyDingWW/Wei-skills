# ModelMesh 开发会话记录

## 项目背景

ModelMesh 是一个 Claude Code skill 路由层，将任务智能分发给两个执行伙伴：
- **Codex**：代码任务（实现、重构、测试、修 bug）
- **Gemini Designer**：设计任务（UI、HTML、SVG、配色）

仓库地址：`https://github.com/JeremyDing424/ModelMesh`
本地克隆路径：`/Users/jeremy/Desktop/Code/ModelMesh_clone/`

---

## 已完成的工作

### 1. 优化了 `scripts/execute.sh`

**修复的问题：**
- `${var,,}` 在 macOS 默认 bash 3.2 不兼容 → 改用 `tr '[:upper:]' '[:lower:]'`
- `--model` 原本只传给 Codex → 改为共用参数，同时注入两个 partner
- 空数组在 `set -u` 模式下报错 → 改用 `"${arr[@]+"${arr[@]}"}` 安全展开
- 单个关键词误判（如 `button`/`form`/`page` 触发 Gemini）→ 改为**加权评分系统**
- 无预检机制 → 新增 `--check` 参数
- 参数缺值无提示 → 改用 `:?` 语法

**路由评分逻辑（加权）：**
- `design a ` / `mockup` / `ui design` / `landing page` 等 → +2（强设计信号）
- `icon` / `svg` / `html` / `color` 等 → +1（弱设计信号）
- `handler` / `validate` / `controller` / `service` 等 → -1（代码上下文，抵消设计词）
- `refactor` / `write tests` / `fix bug` / `memory leak` 等 → -2（强代码信号）
- 最终 score > 0 → Gemini，否则 → Codex

**自测结果：14/14 通过**（包含之前会误判的 button/form/page 场景）

### 2. 精简了 `SKILL.md`

- 从 300 行精简到 ~150 行
- 优化了 `description` 字段（提升 skill 触发准确率）
- 新增歧义词处理说明（Decision Matrix）
- 新增 `--check` 命令说明

### 3. 生成了 `使用说明.md`

中文使用文档，包含前置准备、安装步骤、参数说明等。

---

## 未完成 / 待处理

### 当前卡点：`ask_codex.sh` 不存在

`execute.sh` 是路由脚本，它调用的真正 Codex 执行脚本路径是：
```
$HOME/.claude/skills/codex/scripts/ask_codex.sh
```
但这个文件在当前机器上不存在（`~/.claude/skills/` 里没有 codex skill）。

### 两个解决方案（待实现）

**方案 A（推荐）** — 修改 `execute.sh`，支持就近查找脚本：

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_SCRIPT="${SCRIPT_DIR}/ask_codex.sh"
# 找不到则回退到全局路径
[[ ! -x "$CODEX_SCRIPT" ]] && CODEX_SCRIPT="$HOME/.claude/skills/codex/scripts/ask_codex.sh"
```

这样只需把 `ask_codex.sh` 放到 `ModelMesh_clone/scripts/` 下就能跑，无需修改全局目录结构。

**方案 B** — 按原路径安装：
把 `ask_codex.sh` 放到 `~/.claude/skills/codex/scripts/` 下，不改 `execute.sh`。

### 后续计划

- [ ] 实现方案 A（修改 `execute.sh` 路径查找逻辑）
- [ ] 将 `ask_codex.sh` 放入 `scripts/` 目录并测试
- [ ] 端到端验证：实际调用 Codex 跑通一个任务
- [ ] 注册为 Claude Code skill

---

## 文件结构

```
ModelMesh_clone/
├── SKILL.md          # Claude Code 技能定义（已优化）
├── README.md         # 英文文档
├── 使用说明.md        # 中文使用说明（已生成）
├── SESSION_NOTES.md   # 本文件
├── LICENSE
├── CHANGELOG.md
├── CONTRIBUTING.md
├── GITHUB_SETUP.md
└── scripts/
    └── execute.sh    # 路由脚本（已优化，待补充 ask_codex.sh）
```
