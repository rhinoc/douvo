<div align="center">
  <br />
  <img src="./docs/assets/douvo-icon.png" alt="Douvo icon" width="96" height="96" />
  <h1>Douvo</h1>
  <p>
    一个使用豆包 ASR，并可选大模型纠错的轻量 macOS 语音输入工具。<br />
    按一下快捷键，说话，整理转写结果，然后插入到你正在使用的应用里。
  </p>
  <p>
    <a href="./README.md">English</a>
    &nbsp;·&nbsp;
    <a href="./LICENSE">License</a>
    &nbsp;·&nbsp;
    <a href="./CONTRIBUTING.md">Contributing</a>
  </p>
  <br />
</div>

## 能力展示

<table>
  <tr>
    <td align="center">
      <img src="./docs/assets/demo.gif" width="380" alt="Douvo 录音并插入文本到其他应用" />
      <br />
      <sub>输入到当前应用</sub>
    </td>
    <td align="center">
      <img src="./docs/assets/readme/reduce-emotion.gif" width="380" alt="Douvo 在 AI 纠错中弱化情绪化表达" />
      <br />
      <sub>弱化情绪化表达</sub>
    </td>
  </tr>
</table>

## 功能

- 🎙️ **在任何应用里输入** — 按一个键，说话，然后把转写文本插入当前光标位置。
- 🧠 **插入前自动整理** — 可选 AI 纠错，处理错词、标点、去水词、语气和输出风格。
- 🗂️ **使用自己的词库** — 添加项目术语、路径、名称和产品词，让纠错贴合你的工作。
- ⚙️ **本地或远端 AI 可选** — 可在设备上运行 MLX 模型，也可以添加本地模型文件夹或远端 LLM provider。
- 🪶 **保持轻量工作流** — 菜单栏入口、录音悬浮窗、剪贴板保护和本地诊断日志。

## 免责声明

本项目依赖豆包 Web 产品的现有行为，**不是**豆包官方 API、SDK 或官方集成。

- 你需要拥有有效的豆包账号，并自行完成登录。
- 豆包可能随时调整网页、登录流程、WebSocket 协议、ASR 数据格式、限流规则或访问策略。
- 语音识别由豆包服务端处理。使用前请自行确认豆包的服务条款和隐私政策。
- 应用会把提取到的登录参数保存在本机，以便在不常驻浏览器窗口的情况下连接 ASR WebSocket。
- 如果启用远端 AI 纠错，转写文本会发送到你配置的 provider 和 endpoint。
- 本地 AI 纠错使用从 Hugging Face 下载或从本地文件夹加载的 MLX 模型。
- 使用风险由使用者自行承担。维护者不对服务可用性、账号问题、数据损失、违反第三方规则或其他使用后果负责。
- 本项目与豆包或字节跳动没有从属、背书或赞助关系。

## 大概原理

Douvo 使用豆包 Web 产品完成登录和语音识别，然后可选使用本地或远端大模型整理最终文本。

```mermaid
flowchart TD
    A[内嵌 WKWebView 登录豆包] --> B[本地保存豆包 cookies 和浏览器标识]
    B --> C[通过菜单栏应用触发录音]
    C --> D[AVAudioEngine 采集麦克风音频]
    D --> E[发送 16 kHz PCM 分片到豆包 Web ASR]
    E --> F[悬浮窗显示实时识别结果]
    F --> G[收到最终 ASR 文本]
    G --> H{是否开启 AI Correction?}
    H -- 否 --> L[应用确定性的标点和词库 fallback]
    H -- 本地 --> I[在设备上运行本地 MLX 模型]
    H -- 远端 --> J[把文本发送到用户配置的远端 LLM provider]
    I --> K[清洗、校验并归一化纠错结果]
    J --> K
    K --> L
    L --> M[通过 pasteboard 和 Command-V 插入最终文本]
    M --> N[安全时恢复原剪贴板文本]
    G --> O[写入本地 trace、耗时和日志用于诊断]
```

## 安装

使用 Homebrew：

```bash
brew tap rhinoc/tap
brew install --cask douvo
```

Douvo 以 macOS DMG 形式发布。到 **[GitHub Releases](https://github.com/rhinoc/douvo/releases)** 下载最新的 **`douvo-<version>-macos.dmg`**。

1. 打开 DMG。
2. 把 **`Douvo.app`** 拖到 **Applications** 快捷方式上。
3. 弹出磁盘镜像，然后从 **Applications** 或 Spotlight 启动 **Douvo**。

DMG 里只有 `Douvo.app` 和 **Applications** 快捷方式。Homebrew Cask 安装的也是同一个 DMG 产物。

应用内自动更新由 Sparkle 处理，使用的也是 GitHub Releases 上发布的同一个 DMG 文件。

### 首次启动与 Gatekeeper

浏览器和 Homebrew 下载的应用都可能带有 Gatekeeper **quarantine** 标记（`com.apple.quarantine`）。如果 macOS 提示 Douvo 无法打开，或提示来自未识别开发者，请先把 app 安装到 **Applications**，然后移除 quarantine 标记。

移除已安装 app 的 quarantine 标记：

```bash
xattr -dr com.apple.quarantine /Applications/Douvo.app
```

### 本地构建

快速开发运行：

```bash
swift run Douvo
```

本地测试 app bundle 时，可以自己打包：

```bash
./scripts/build-app.sh
open .build/release/Douvo.app
```

打包脚本会生成并签名本地 `.app`：

```text
.build/release/Douvo.app
```

本地 app bundle 构建需要代码签名身份。可以设置 `CODESIGN_IDENTITY`，或安装名为 `Douvo Local Code Signing` 的本地签名身份。构建脚本也会打包本地 AI 纠错需要的 MLX Metal library。

开发环境、测试、PR 规则和发布边界请看 **[CONTRIBUTING.md](./CONTRIBUTING.md)**。

## 权限

完整使用前，需要授予两个 macOS 权限：

1. **麦克风** — 用来采集语音。
2. **辅助功能** — 用来监听全局触发键，以及向当前应用发送 Command-V。

如果授予辅助功能权限后触发键仍不可用，先退出并重新打开打包后的 `.app`。如果仍然无效，可以在 **系统设置 -> 隐私与安全性 -> 辅助功能** 中删除旧的 Douvo 项，再重新添加当前 app bundle，然后重启应用。

本地 AI 纠错在设备上运行。远端 AI 纠错会把转写文本发送到你配置的远端 provider，并把该 provider 的 API key 存在 Keychain。

## 使用方式

1. 点击菜单栏图标，选择 **Log In**。
2. 在弹出的窗口里完成豆包登录。
3. 把光标放到任意文本输入框。
4. 按触发键开始录音。
5. 说话。
6. 再按一次触发键，停止录音并插入文本。
7. 录音过程中按 **Escape** 可以取消。

菜单栏里的 **Settings...** 可以修改触发键、选择麦克风、刷新登录凭据、复制诊断信息或打开日志。

### AI Correction

打开 **Settings... -> Correction** 配置转写后处理：

- 选择 **Local** 下载内置 MLX 模型，或添加本地 MLX 模型文件夹。
- 选择 **Remote** 添加 provider、base URL、model name 和 API key。
- 添加用户词库，覆盖项目术语、文件路径、产品名称和常见 ASR 错词。
- 配置标点、去水词、情绪弱化和输出风格。
- 使用 Correction Debug 测试一段输入，并查看本地 trace。

## 参考项目

本项目参考了以下开源项目：

- [lilong7676/doubao-murmur](https://github.com/lilong7676/doubao-murmur)
  - 基于 WebView 的豆包登录流程。
  - 提取豆包 cookies 和浏览器标识，用于原生 ASR 访问。
  - 通过原生 WebSocket 连接豆包 Web ASR。
  - 16 kHz PCM 音频流和结束帧行为。
  - macOS 菜单栏语音输入交互。
- [Open-Less/openless](https://github.com/Open-Less/openless)
  - 面向当前光标位置的全局语音输入产品方向。
  - 菜单栏 / 托盘式语音输入工作流。
  - Settings 与 Diagnose 的组织方式。
  - 文本插入可靠性思路，包括粘贴 fallback 和剪贴板恢复。

本仓库没有 vendoring 这两个项目。它们的代码和 license 仍归各自作者所有。

## Contributing

开发环境、代码风格、测试、凭据处理和发布说明都放在 **[CONTRIBUTING.md](./CONTRIBUTING.md)**。

## License

Douvo 使用 **MIT License** 发布。见 **[LICENSE](./LICENSE)**。
