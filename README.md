# Codex Pulse

一款原生 macOS Codex 用量工具。黑色悬浮面板、冰蓝色额度圆环、菜单栏百分比，以及账号历史用量趋势。

界面截图和本机验证快照属于本地构建产物，默认不纳入公开源码仓库。

## 下载

前往仓库的 [Releases](https://github.com/mrzhouxl/codex-pulse/releases) 页面，下载最新的 `Codex-Pulse-*.zip`，解压后将 `Codex Pulse.app` 拖入“应用程序”。当前自动构建版本面向 Apple Silicon，并需要 macOS 14 或更新版本。

每次推送代码都会运行测试并生成可下载的构建产物；推送形如 `v1.5.0` 的版本标签后，GitHub Actions 会自动创建一个 Release。当前构建尚未加入 Developer ID 签名和公证，首次打开时 macOS 可能显示安全提示。

## 使用

打开 `dist/Codex Pulse.app`。首次运行展示主面板，之后常驻菜单栏。

本机已安装版本：`~/Applications/Codex Pulse.app`，可以从 Finder 的用户应用程序目录打开。

- **菜单栏**：点击小圆环查看额度，右键可打开主面板、隐藏悬浮条或退出。
- **悬浮条**：拖动顶部手柄吸附到屏幕左右边缘，点击额度组打开详情；底部箭头打开主面板。
- **紧凑贴边**：三个额度组时尺寸为 54 × 234 pt；紧贴物理屏幕边缘，内侧保留圆角。图标下显示剩余百分比，悬停或点开可看名称。
- **主面板**：查看 Codex、Spark、Reserve 等官方实际返回的额度组。
- **今日 Token 用量**：按本机时区从当天零点累计，每 10 秒自动更新；点击数字进入输入、缓存输入、输出和请求次数明细。
- **用量统计**：切换 7 天 / 30 天，鼠标移到柱状图查看某日用量；可导出全部已返回记录为 CSV。
- **偏好设置**：调整刷新频率、不透明度、菜单栏显示，按需开启低额度提醒、开机启动。
- 关闭主窗口后，菜单栏与悬浮条继续运行。`⌘Q` 完全退出，`⌘R` 刷新，`⌘,` 打开设置。
- 应用采用单实例保护：即使分别打开项目内和已安装的副本，也只保留一个运行实例，并唤起已有主面板。倒计时和数据刷新不会重新置顶已显示的悬浮条。

需要 macOS 14 或更新版本，以及安装并登录 ChatGPT 账号的 Codex 桌面应用或 Codex CLI。当前构建面向 Apple Silicon；可在 Intel Mac 从源码重新编译。

应用自动查找 `/Applications/Codex.app`、`/Applications/ChatGPT.app`、用户应用目录、Homebrew 及 nvm 的 Codex 程序。也可以在设置中手动选择。

## 数据口径

- 通过官方 Codex App Server 的 `account/read`、`account/rateLimits/read`、`account/usage/read` 获取真实数据。
- 圆环和进度条均表示**剩余比例**。多个周期并存时，紧凑圆环显示剩余最少的周期；详情完整显示所有周期。
- 圆环只对弧长做平滑过渡，底环和进度弧共享同一圆心；切换额度组或卡片高度变化不会拉偏圆环。遵循系统“减少动态效果”设置。
- 优先使用 `rateLimitsByLimitId`，兼容旧版单额度返回。周期长度由服务端提供，不预设五小时或每周。
- 重置倒计时到期后显示“等待官方更新”，不会自行把额度恢复为 100%。
- Token 用量和订阅额度分开计量，不推算还能请求多少次，也不把 Token 换算成订阅费用。
- 日用量按服务返回的日期显示。没有记录显示“暂无记录”，与零用量区分；近期总量为时段内已返回记录之和。
- 官方每日 Token 数据可能晚于实时额度更新，仍按服务返回日期展示在“官方历史趋势”。
- “今日 Token 用量”独立读取这台 Mac 的 Codex 用量事件，包含当前 Codex 数据目录中的所有账号，不代表当前账号在其他设备或云端的全部用量；不与官方历史相加。它以本机时区的事件时间计入当天，跨日自动重新统计。
- 本机总 Token = 输入 + 输出；缓存输入已包含在输入中，推理输出已包含在输出中，不重复相加。现代记录按响应 ID 去重；旧版通知用累计差值兼容并标注“本机估算”。没有记录目录显示未知，不伪装为 0。
- 本机读取覆盖当天有变动的新旧会话和归档会话，增量处理新写入内容，不反复读取全部历史。统计尚未写入记录的正在生成部分会在记录落盘后更新。旧版估算与官方计费口径可能不同。
- 网络失败保留当前会话的上次数据，圆环变暗并显示状态。冷启动时先核实账号，再读取该账号的本地历史缓存，避免显示其他账号的数据。
- 服务端暂不支持历史接口时，额度功能仍可使用，历史区域显示无数据或已缓存记录。

接口参考：[Codex App Server](https://learn.chatgpt.com/docs/app-server)。本应用是独立工具，不是 OpenAI 官方应用。

## 隐私与权限

登录和令牌刷新由官方 Codex 程序处理。本应用不解析或复制 `auth.json`，不保存密码或登录令牌。今日统计仅读取会话记录的标识、时间和 Token 计数字段；对话正文不解码、不保存、不上传。

官方用量快照保存在 `~/Library/Application Support/Codex Pulse/`，按账号 ID 隔离，文件权限为 `600`。今日统计索引只保留在内存中，数据目录使用 `CODEX_HOME`，默认 `~/.codex`。偏好使用 macOS UserDefaults。没有自建服务器或遥测服务；官方 Codex 子进程使用其自身的网络与登录机制。

通知和开机启动默认关闭，可在偏好设置中开启。仅通知额度变化，不会购买额度或消耗重置信用。

## 构建与验证

使用 Swift 5.9+、macOS 14+ SDK，无第三方依赖：

```sh
swift build -c release
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift test --disable-sandbox
```

构建输出位于 `.build/`，面向当前 Mac 自用；对外分发应另行完成 Developer ID 签名与公证。

签名、公证、集成冒烟测试等本机辅助脚本不纳入公开仓库；公开仓库只保留可复现的源代码和单元测试。

## 结构

- `Sources/PulseCore`：官方返回模型、额度计算、日期与提醒去重。
- `Sources/PulseCore/LocalUsage.swift`：今日用量的本地增量读取、按本机时区分日与响应去重。
- `Sources/CodexPulse/CodexClient.swift`：官方子进程、JSON-RPC、超时与连接生命周期。
- `Sources/CodexPulse/PulseStore.swift`：数据同步、账号隔离缓存、通知、导出与设置。
- `Sources/CodexPulse/App.swift`：菜单栏、窗口管理、贴边与多显示器恢复。
- 其余 SwiftUI 文件：主面板、图表、设置、悬浮条和详情组件。
