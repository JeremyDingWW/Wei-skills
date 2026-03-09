# ModelMesh

> Claude Code 统一执行伙伴技能 — 智能路由代码任务到 Codex，设计任务到 Gemini Designer

---

## 前置准备

### 1. 安装 Claude Code CLI

```bash
npm install -g @anthropic-ai/claude-code
```

验证安装：

```bash
claude --version
```

### 2. 安装 Codex CLI

Codex 是代码执行伙伴，负责处理编码、重构、测试等任务。

```bash
npm i -g @openai/codex
```

验证安装：

```bash
codex --version
```

> 参考：[Codex 官方文档](https://github.com/openai/codex)

### 3. 配置 Gemini API Key

Gemini Designer 是设计执行伙伴，负责 UI 设计、SVG 图标、HTML 原型等任务。

获取 API Key 后，选择以下任意一种方式配置：

**方式一：环境变量（推荐）**

```bash
export GEMINI_API_KEY="your-api-key-here"
```

永久生效（写入 shell 配置文件）：

```bash
# Zsh 用户
echo 'export GEMINI_API_KEY="your-api-key-here"' >> ~/.zshrc
source ~/.zshrc

# Bash 用户
echo 'export GEMINI_API_KEY="your-api-key-here"' >> ~/.bashrc
source ~/.bashrc
```

**方式二：配置文件**

```bash
mkdir -p ~/.config/gemini-designer
echo "your-api-key-here" > ~/.config/gemini-designer/api_key
```

**方式三：项目 .env.local 文件**

```bash
echo 'GEMINI_API_KEY=your-api-key-here' > .env.local
```

### 4. 安装依赖工具

```bash
# macOS
brew install curl jq

# Ubuntu / Debian
sudo apt-get install curl jq

# Windows (Git Bash)
# curl 通常已内置，jq 需手动下载：https://jqlang.github.io/jq/download/
```

### 5. 环境要求汇总

| 工具 | 最低要求 | 说明 |
|------|----------|------|
| Bash | 4.0+ | macOS/Linux 原生，Windows 需 Git Bash |
| Node.js | 18+ | Claude Code 和 Codex 依赖 |
| curl | 任意版本 | HTTP 请求 |
| jq | 1.6+ | JSON 解析（Gemini 必需） |
| Claude Code CLI | 最新版 | 核心工具 |
| Codex CLI | 最新版 | 代码执行伙伴 |
| Gemini API Key | — | 设计执行伙伴认证 |

---

## 安装 ModelMesh

### 克隆仓库

```bash
git clone git@github.com:JeremyDing424/ModelMesh.git
```

### 复制到 Claude Skills 目录

```bash
cp -r ModelMesh ~/.claude/skills/execution-partners
```

### 赋予脚本执行权限

```bash
# macOS / Linux
chmod +x ~/.claude/skills/execution-partners/scripts/execute.sh
chmod +x ~/.claude/skills/execution-partners/scripts/ask_codex.sh
chmod +x ~/.claude/skills/execution-partners/scripts/ask_gemini.sh

# Windows（Git Bash）
chmod +x ~/.claude/skills/execution-partners/scripts/execute.sh
chmod +x ~/.claude/skills/execution-partners/scripts/ask_codex_windows.sh
chmod +x ~/.claude/skills/execution-partners/scripts/ask_gemini.sh
```

---

## 基本使用

### 自动路由（推荐）

脚本会自动分析任务描述，将其路由到合适的执行伙伴：

```bash
~/.claude/skills/execution-partners/scripts/execute.sh "你的任务描述"
```

### 代码任务示例（自动路由到 Codex）

```bash
# 添加功能
execute.sh "Add a power function to calculator and write tests"

# 重构代码
execute.sh "Refactor UserService to use async/await"

# 修复 Bug
execute.sh "Fix the memory leak in WebSocketHandler"
```

### 设计任务示例（自动路由到 Gemini）

```bash
# 设计 HTML 页面
execute.sh "Design a login form with email and password fields" --html

# 创建 SVG 图标
execute.sh "Create an SVG icon for settings"

# 设计卡片组件并输出到文件
execute.sh "Design a card component with title and description" --html -o card.html
```

### 手动指定执行伙伴

```bash
# 强制使用 Codex
execute.sh "Design a button" --partner codex

# 强制使用 Gemini
execute.sh "Implement login" --partner gemini --html
```

---

## 参数说明

### Codex 专用参数

| 参数 | 说明 |
|------|------|
| `--file <path>` | 指定关键文件（可重复使用） |
| `--workspace <path>` | 指定工作目录（默认当前目录） |
| `--session <id>` | 恢复上一次对话（多轮任务） |
| `--reasoning <level>` | 推理强度：`low` / `medium` / `high` |
| `--read-only` | 只读模式，不修改文件 |

### Gemini 专用参数

| 参数 | 说明 |
|------|------|
| `--html` | 输出 HTML 文件 |
| `--svg` | 输出 SVG 文件 |
| `-o / --output <path>` | 指定输出文件路径 |

### 共用参数

| 参数 | 说明 |
|------|------|
| `--partner <codex\|gemini>` | 手动指定执行伙伴 |
| `--check` | 验证两个执行脚本是否已安装且有执行权限，安装排查专用 |

---

## 关键词路由规则

脚本通过分析任务描述中的关键词来自动路由：

脚本使用**加权评分**机制，Score > 0 路由到 Gemini，否则路由到 Codex：

| 权重 | 信号 | 关键词示例 |
|------|------|-----------|
| +2（强设计） | 明确设计意图 | `design a` `design the` `mockup` `ui design` `color palette` `landing page` |
| +1（弱设计） | 设计相关词 | `icon` `svg` `html` `layout` `color` `palette` `visual` `style` |
| -1（代码上下文） | 中和歧义词 | `handler` `middleware` `controller` `service` `hook` `component` `validate` |
| -2（强代码） | 明确代码意图 | `refactor` `write tests` `unit test` `fix bug` `implement` `debug` |

> 若评分为 0 或无法判断，默认路由到 **Codex**。

---

## 常见问题

### `Command not found`

脚本没有执行权限，运行：

```bash
chmod +x ~/.claude/skills/execution-partners/scripts/execute.sh
```

### `Partner script not found`

Codex 或 Gemini Designer skill 未安装，确认两者都已复制到 `~/.claude/skills/` 目录。

### Gemini API 报错

- 检查 `GEMINI_API_KEY` 是否正确设置
- 检查 `GOOGLE_GEMINI_BASE_URL` 是否指向正确的 API 端点
- 确认 API 端点路径为 `/v1/chat/completions`

---

## 项目结构

```
ModelMesh/
├── SKILL.md               # Claude Code 技能定义文件
├── README.md              # 使用文档（本文件）
├── LICENSE                # MIT 开源协议
└── scripts/
    ├── execute.sh          # 主执行脚本（路由判断，跨平台入口）
    ├── ask_codex.sh        # Codex 执行脚本（macOS / Linux）
    ├── ask_codex_windows.sh # Codex 执行脚本（Windows / Git Bash）
    └── ask_gemini.sh       # Gemini 执行脚本（设计任务，调用 Gemini API）
```

---

## 许可证

MIT License — 详见 [LICENSE](./LICENSE) 文件。
