# Codex 配置 · cc-gl

一个用 **Swift + SwiftUI** 编写的原生 macOS 配置管理工具，支持收藏 API 线路、状态栏快捷切换、YOLO 权限设置和可选的 iCloud 加密同步。

只需保存常用的 Base URL 与 API Key，就能从主窗口或状态栏切换 Codex 配置，无需反复手动编辑文件。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)
![UI SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)

![Codex 配置主界面，使用隔离演示数据](Resources/preview.png)

## 功能

- **本地收藏**：管理线路名称、Base URL 和 API Key；密钥保存到 macOS 钥匙串。
- **状态栏切换**：选择收藏并确认即可应用，关闭主窗口后仍可操作；当前地址与密钥均匹配的收藏显示 ✓。
- **精确修改与恢复**：保留无关配置、注释和格式，提供最近一步备份及外部文件冲突检测。
- **YOLO 模式**：独立设置全局审批与沙箱选项，不应用编辑区未保存的线路。
- **iCloud 加密同步**：可选同步收藏与密钥，支持离线修改合并和冲突副本。
- **模型侦探社**：按需调用第三方检测服务，以原生动画展示进度与结果。
- **隔离演示**：使用临时目录和假密钥体验界面，不读取真实 Codex 文件或钥匙串。

无 WebView、数据库或远程 SwiftPM 依赖。状态栏与主窗口运行在同一应用进程，退出应用后停止本地后台活动。

## 快速开始

### 环境要求

- macOS **13 或更新版本**。
- 构建需要 Xcode / Swift **5.9 或更新版本**，以及可用的 macOS SDK。
- 已有受支持的 `~/.codex/config.toml` 和 `~/.codex/auth.json`，详见[兼容范围](#兼容范围)。

### 从源码构建

```bash
git clone https://github.com/weixiao0524/cc-gl.git
cd cc-gl
swift test
./scripts/build-app.sh
open dist/CodexConfig.app
```

生成 DMG 安装包：

```bash
./scripts/build-app.sh --dmg
```

构建结果位于 `dist/`，默认仅包含当前机器架构。可将 `CodexConfig.app` 拖入「应用程序」。默认使用本地 ad-hoc 签名，尚未进行 Developer ID 公证。

### 使用方法

1. 打开应用，自动读取当前用户的 Codex 配置，首次读取不写文件。
2. 输入名称、完整 Base URL 和 API Key，点击 **保存到收藏**。
3. 在主窗口点击 **应用此配置**，或从状态栏菜单选择收藏，确认后写入。
4. **重启 Codex 或相关会话**，让它读取新配置。

保存收藏不会自动应用。状态栏切换使用收藏中已保存的值，保留编辑区未保存的内容。✓ 表示与当前本地文件匹配，不代表正在运行的 Codex 会话已重新加载；完全相同的多条收藏都会标记。

`⌘N` 新增收藏，`⌘S` 保存收藏。关闭主窗口后应用保留在状态栏；从菜单选择 **退出 Codex 配置** 或按 `⌘Q` 退出。

体验隔离演示：

```bash
open -n dist/CodexConfig.app --args --demo
```

## 兼容范围

本工具管理已有的自定义 API Key 提供方，要求：

- `model_provider` 指向已有自定义提供方，并设置 `requires_openai_auth = true`。
- 使用文件认证，`auth.json` 已有字符串类型的根级 `OPENAI_API_KEY`。
- 目标文件位于当前用户的 `~/.codex`。

线路切换只修改当前提供方的 `base_url` 和 `OPENAI_API_KEY`，不新增或切换 provider，不修改模型、MCP 或其他字段，也不自动补全 `/v1`。

暂不支持账号登录令牌、`keyring` / `auto` 认证、命令认证、内置提供方的 `openai_base_url`、旧式 `profile` 选择器或指向其他目录的 `CODEX_HOME`。文件缺失、语法不正确或配置不受支持时会提示原因，不自动重建文件。

命令行、项目配置及受托管策略可能覆盖全局设置。详细说明见[使用与技术文档](docs/usage.md)。

## 数据与恢复

| 内容 | 存储方式 |
| --- | --- |
| 收藏名称、地址与同步元数据 | `~/Library/Application Support/CodexConfig/` |
| 收藏 API Key | macOS 钥匙串 |
| 可选 iCloud 同步 | AES-256-GCM 加密，密码经 PBKDF2-HMAC-SHA256 派生密钥 |
| 最近一步恢复快照 | 本地 `last-change.json`，目录权限 `0700`、文件权限 `0600` |

恢复快照包含原始认证数据，是受文件权限保护的**本地明文备份**，不要分享或提交应用数据目录。恢复只支持最近一步，检测到其他程序修改文件时会拒绝覆盖。

启用 iCloud 同步需要选择专用文件夹并设置同步密码。同步不会自动应用线路，也不同步 YOLO 设置。密码遗忘后无法直接恢复加密内容；冲突、历史记录与跨 Mac 使用说明见[完整文档](docs/usage.md#icloud-跨-mac-同步)。

## 可选模型检测

![模型侦探社，模拟状态的浅色与深色预览](Resources/detective-preview.png)

点击 **模型检测**，选择检测对象并阅读费用与隐私说明，确认后启动。检测使用 `meowllm.top` 的第三方服务，不是本地鉴真：

- API Key 会发送给该网站；请求地址和检测结果会公开，调用费用由对应 API 账户承担。
- 不自动检测，不修改 Codex 配置。匹配度是网站的指纹推断，不是身份概率或真实性保证。
- 本地模型、内网地址及自定义端口不适用；第三方接口变化可能导致功能不可用。
- 退出应用不会自动停止远端计费任务；检测中应先停止并等待服务端确认。

接口描述见 [OpenAPI 文档](docs/openapi/meowllm.yaml)，数据流和故障处理见[完整说明](docs/usage.md#模型检测说明11-起支持)。

## 开发与验证

```bash
swift test                                  # 离线测试，可选测试默认跳过
swift test --filter StatusMenuTests          # 状态栏切换与当前收藏标记
./scripts/build-app.sh --dmg                 # Release 应用与安装包
```

测试覆盖精确文件修改、事务回滚、外部冲突、收藏、同步加密与合并、检测状态、动画及状态栏切换。测试使用临时文件与假密钥；未完成两台真实 Mac 的 iCloud 端到端验收，也未使用真实 Key 验证付费检测。

```text
Sources/
  CodexConfigApp/       SwiftUI 界面、状态栏与应用状态
  CodexConfigCore/      配置解析、文件事务、收藏、同步与检测
  CTOMLPatch/           内置 toml++ 3.4.0 与 C ABI 封装
Tests/                 核心逻辑与应用测试
Resources/             图标、Info.plist 与界面截图
scripts/               构建、打包与图标生成
docs/                  详细说明与第三方接口描述
```

## 反馈与贡献

欢迎通过 [Issues](https://github.com/weixiao0524/cc-gl/issues) 报告问题或提出建议。请附 macOS 版本、复现步骤与脱敏后的错误信息，不要上传 API Key、认证文件或恢复快照。

提交代码前请运行 `swift test`；涉及配置写入的改动应保留精确修改、备份和冲突检测行为。

## 第三方许可

内置的 [toml++](https://github.com/marzer/tomlplusplus) 使用 MIT 许可证，见 [第三方许可证](Sources/CTOMLPatch/LICENSE)。该许可证仅适用于对应第三方代码；本项目其余代码尚未指定开源许可证。
