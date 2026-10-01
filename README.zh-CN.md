<p align="center">
  <img src="design/27b-launcher-icon-1024.png" width="128" height="128" alt="27B Launcher 图标">
</p>

# 27B Launcher

**在 Mac 上本地运行 Bonsai 2 27B 大模型，原生、轻巧、开箱即用。**

27B Launcher 是一款专为 Apple Silicon Mac 打造的原生桌面应用。集成了自动化模型下载、后台推理服务与桌面控制面板。无需配置复杂的 Python 环境或命令行工具，即可在本地流畅运行 27B 参数级大模型与多模态视觉理解。全部推理均在本地芯片完成，无需云端账户，保护数据隐私。

[English](README.md) · **简体中文**

[快速开始](#快速开始) · [系统要求](#系统要求) · [常见问题](#常见问题)

> **签名提示**：官方 Release 安装包已通过 Apple Developer ID 签名并公证；应用未设置内置自动更新，可通过 Homebrew 或下载新版 DMG 升级。

---

## 界面预览

<p align="center">
  <img src="docs/media/dashboard-zh-CN.jpg" width="860" alt="27B Launcher 中文工作台">
</p>

### 本地网页对话与识图

开箱即用的 Web 对话界面，支持文字交互与图片内容理解：

<p align="center">
  <img src="docs/media/local-chat-zh-CN.gif" width="628" alt="在浏览器中与本地 Bonsai 2 对话演示">
</p>

---

## 核心特性

- **开箱即用引导**：首次运行自动下载固定版本的模型、视觉组件、LoRA 适配器与 llama.cpp 运行时，支持断点续传与 SHA-256 完整性校验。
- **原生桌面控制台**：常驻 Dock，直观启停与重启服务，实时查看 Token 生成速度、内存与上下文使用量。
- **内置 Web 对话**：一键在浏览器中打开聊天页，支持输入文字与上传图片进行视觉分析。
- **标准 OpenAI 兼容 API**：提供标准的本地 `/v1` 接口，可直接接入 NextChat、Chatbox、Open WebUI、Cursor 等任意客户端。
- **OrcaBonsai 自由度调节**：内置 OrcaBonsai LoRA 适配器，减少合规过度拦截；支持一键开关及 0.5×～2.0× 强度微调。
- **安全存储迁移**：支持将约 8 GB 的模型一键迁移至外接高速 SSD，复制校验后再切换，安全省心。
- **原生系统体验**：支持简体中文、繁體中文、English、Español；跟随系统自动切换深色/浅色外观；支持无障碍模式与开机自启。
- **零数据上报**：完全离线运行，不收集任何用户隐私、使用习惯或崩溃日志。

---

## 组件构成说明

27B Launcher 会自动下载并协同运行以下组件，无需手动配置：

| 组件 | 文件与大小 | 用途与说明 |
| --- | --- | --- |
| **Bonsai 2 27B 主模型** | `Ternary-Bonsai-2-27B-PQ2_0.gguf`<br>约 7.21 GB | Prism ML 的 270 亿参数基座语言模型，采用紧凑的三值（Ternary）权重。负责核心的文本理解、写作、总结和代码辅助。 |
| **视觉投影组件** | `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`<br>约 0.63 GB | Bonsai 2 配套的多模态图像编码组件。让你能在聊天中发送截图或照片并针对图片提问（用于理解图片，非生成图片）。 |
| **OrcaBonsai LoRA** | `bonsai-abliterate-lora.gguf`<br>约 9.68 MB | Continuum AI 开发的低秩适配器（LoRA）。针对基座模型的过度拒答倾向进行了定向优化，可在控制台中随时启用及调节强度。 |
| **Prism llama.cpp 运行时** | 预编译 macOS arm64 二进制包<br>约 11.7 MB | 针对 Apple Silicon 定制优化的本地推理引擎，负责加载模型权重并提供高性能推理与 API 服务。 |

> **关于 OrcaBonsai 适配器**：  
> 控制台中默认开启该模块（强度 2.0×）。若需要原汁原味的模型表现，可随时关闭该开关。修改强度或开关状态时，应用会自动平滑重启模型服务。详细版本与来源信息请参阅 [第三方组件列表](docs/THIRD_PARTY.md)。

---

## 系统要求

| 项目 | 要求 |
| --- | --- |
| **设备架构** | Apple Silicon 芯片（M1 / M2 / M3 / M4 系列），**不支持 Intel Mac** |
| **系统版本** | macOS 14 (Sonoma) 或更高版本 |
| **统一内存** | **最低 16 GB**，推荐 **32 GB 或更高**（16 GB 机型在较长上下文时请注意内存占用） |
| **存储空间** | 首次下载需约 7.86 GB，建议预留 **15 GB 以上可用空间**（用于解压及运行缓存） |

---

## 快速开始

### 1. 安装应用

#### 方式 A：通过 Homebrew 安装（推荐）

```sh
brew tap mreasonyang/27b-launcher https://github.com/mreasonyang/27b-launcher
brew install --cask mreasonyang/27b-launcher/27b-launcher
open "/Applications/27B Launcher.app"
```

#### 方式 B：下载 DMG 安装包

访问 [Releases 页面](https://github.com/mreasonyang/27b-launcher/releases/latest) 下载最新的 `.dmg` 文件，打开后将 **27B Launcher.app** 拖入 **Applications（应用程序）** 文件夹。

#### 方式 C：从源码构建（面向开发者）

```sh
git clone https://github.com/mreasonyang/27b-launcher.git
cd 27b-launcher
swift test
./scripts/install.sh
open "$HOME/Applications/27B Launcher.app"
```

> 详细的升级、卸载与维护说明请查阅 [Homebrew 安装指南](docs/HOMEBREW.md)。

---

### 2. 首次启动与模型准备

1. 打开 **27B Launcher**，应用会自动弹出首次设置引导。
2. 确认磁盘空间与存储路径（默认为 `~/Library/Application Support/Bonsai2/`）。
3. 点击 **「下载并准备」**，启动器会自动完成组件下载、SHA-256 校验和启动。
   - 支持暂停与断点续传；也可选择「稍后设置」，下次启动时点击「继续设置」即可恢复。
4. 模型就绪后，点击 **「开始聊天」** 即可在默认浏览器中体验对话。

---

### 3. 连接第三方客户端 (OpenAI 兼容 API)

除了内置网页聊天外，27B Launcher 提供了标准的 OpenAI 兼容接口，可无缝接入各类常用客户端（如 Chatbox、NextChat、Open WebUI、Bob 等）：

- **API 地址 (Base URL)**：`http://127.0.0.1:8080/v1`
- **模型名称 (Model)**：在启动器面板中点击一键复制「模型 ID」（或填写 `Bonsai-2-27B`）
- **API Key**：本地模式下无需密码；若客户端要求必填，可随意输入任意字符（例如 `local`）

---

### 4. 局域网共享 (可选)

如果你希望在同局域网下的手机、平板或其他电脑上使用该模型：

1. 在主界面将网络监听范围切换为 **「所有网络接口 (0.0.0.0)」**。
2. 开启后，系统出于安全考量会自动生成一个 API Bearer Key 并存入 macOS Keychain（钥匙串），内置网页端将关闭。
3. 其他设备通过 `http://<你的Mac局域网IP>:8080/v1` 访问，并在客户端的 API Key 中填入控制面板中生成的密钥。

---

## 常见问题与使用贴士

### 窗口关闭、退出与停止服务的区别？
- **关闭主窗口 (Cmd+W 或红叉)**：仅隐藏界面，后台模型推理服务和正在进行的下载继续保持运行。再次点击 Dock 图标即可重新呼出面板。
- **退出应用 (Quit / Cmd+Q)**：退出控制台。注意：已在运行的底层推理进程仍会继续运行以保证 API 不中断。
- **停止模型 (Stop)**：在控制台点击 **「停止」** 按钮，会彻底终止后台推理进程并完全释放内存占用。

### 如何将模型搬到外接 SSD？
打开 **设置 (Cmd+,) → 存储**，选择新的目标文件夹即可。启动器会采用「先安全复制并逐文件校验、再原子切换、最后清理旧目录」的策略，整个过程支持取消，确保模型文件绝对安全。

### 模型崩溃或无法启动怎么办？
- 若底层进程异常退出，控制台会提示并允许一键重试。连续多次失败会自动暂停重启以防止死循环。
- 可点击控制台右上角的日志图标查看详细报错输出。
- 如怀疑文件损坏，可在设置中执行「完整性检查」，应用会自动重下损坏的文件。

---

## 隐私声明

27B Launcher 秉持隐私至上原则：
- **完全本地运行**：除从官方渠道（GitHub 与 Hugging Face）下载模型文件外，不向任何第三方服务器发送请求。
- **无遥测上报**：没有内置任何分析追踪、行为统计或崩溃日志收集代码。
- **安全密钥存储**：局域网访问密钥严格保存在 macOS 系统钥匙串中。

更多存储路径与安全细节请参阅 [隐私与本地存储说明](docs/PRIVACY.md)。

---

## 开源许可与致谢

- 启动器源码基于 [MIT License](LICENSE) 开源。
- 所下载的模型、权重与第三方运行时遵循其各自的上游开源协议，详情参见 [第三方组件清单](docs/THIRD_PARTY.md)：
  - **Bonsai 2 27B** by [Prism ML](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf)
  - **OrcaBonsai** by [Continuum AI](https://github.com/Continuum-AI-Corp/OrcaBonsai-27B-Uncensored)
  - **Prism llama.cpp runtime** by [PrismML-Eng](https://github.com/PrismML-Eng/llama.cpp)
