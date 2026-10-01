# Homebrew 0.10.13 实机验收

日期：2026-10-01。环境：当前 Apple Silicon Mac；实际安装路径
`/Applications/27B Launcher.app`，版本 0.10.13（42）。

结论：现有模型的日常使用链路 PASS；不宣称所有首次安装、系统和网络场景均已实机验收。

## 安装与问题修复

退出旧应用后，删除了经过身份和非符号链接检查的
`~/Applications/27B Launcher.app`。保留 `~/Library/Application Support/Bonsai2`
的 7.84 GB 模型、运行时、设置和钥匙串内容。

Homebrew 0.10.12 实际启动时暴露了 SwiftPM 资源查找崩溃：其自动生成的
`Bundle.module` 访问器按命令行布局查找资源，无法定位 app 的
`Contents/Resources/Launcher27B_Launcher27B.bundle`。
0.10.13 使用应用内资源定位，命令行测试继续使用 SwiftPM 访问器。
CI 和发布流程新增运行实际打包可执行文件的启动检查。没有修改已发布包或移动旧 tag。

Homebrew 完成 0.10.12 → 0.10.13 升级，旧版本应用被替换；实际启动进程路径是
`/Applications/27B Launcher.app/Contents/MacOS/Launcher27B`。

## 实机检查

| 检查 | 结果与证据 |
| --- | --- |
| Homebrew 收据 | `brew info --cask` 显示已安装 0.10.13 |
| 签名与公证 | `codesign --verify --deep --strict`、`stapler validate` 均通过；`spctl` accepted / Notarized Developer ID |
| 打开应用 | 正常显示现有模型仪表盘，无资源崩溃 |
| 启动模型 | 从已停止进入运行中；`/health` 返回 `{"status":"ok"}`；仅监听 127.0.0.1 |
| 实际聊天 | 内置 Browser 发送 `Reply exactly: Homebrew installation test passed.`，收到完整预期回复；页面显示 25 输出 tokens、15.43 t/s |
| 指标 | 仪表盘记录 2,765 tokens，活动请求恢复为 0，上下文峰值 2,764 / 32K |
| 退出与接管 | Cmd+Q 后启动器进程退出、模型 PID 42209 保持健康；重新打开应用后显示运行中并接管该进程 |
| 重启 | 按钮显示正在重启并禁用并发操作；新模型 PID 43189，健康恢复，指标重置 |
| 停止 | 显示已停止、启动按钮可用；模型进程消失，端口健康请求不再可达 |
| 语言 | 设置实际切换并显示简体中文、繁体中文、English、Español 文本，无资源崩溃 |
| 外观与无障碍 | 深色、浅色和无障碍开关的状态及渲染正常；恢复跟随系统、关闭无障碍 |
| 模型校验 | 应用校验模型、视觉投影、OrcaBonsai 共 3 文件全部正常 |
| 更改位置入口 | 打开原生目录选择器并取消；现有目录保持不变 |
| LAN 确认 | 切换所有网络接口先显示风险确认；取消后仍仅本机，无网络暴露 |
| 数据保留 | 原有 7.84 GB 模型可直接启动；旧本地 app 已不存在 |

测试结束恢复简体中文、跟随系统、无障碍关闭、仅本机、OrcaBonsai 2.0×、
登录自动运行关闭。模型恢复为测试前的停止状态；Homebrew 应用保持安装。

## 自动验证与边界

- 全量本地测试：263 tests / 26 suites PASS，48.241 秒。
- 本地化专项：14 tests PASS。
- [源代码 CI](https://github.com/mreasonyang/27b-launcher/actions/runs/36808152141)：PASS，包含打包启动检查。
- [正式发布](https://github.com/mreasonyang/27b-launcher/actions/runs/36808587005)：PASS，签名、公证、发布与 Tap 更新成功。
- [公开版本](https://github.com/mreasonyang/27b-launcher/releases/tag/v0.10.13)。

本次复用已有模型，未删除模型来重跑首次完整下载，未执行真实存储迁移、
登录/重启系统、局域网暴露或密钥轮换，也未在其他 Mac 上测试。
关闭窗口与日志窗口没有取得足够的独立 UI 证据，未计为通过。
这些路径不能用单元测试通过替代实际验收。

## 补充：全新应用安装与 DMG 安装

同日补测公开 0.10.13 的安装过程及核心功能；保留现有模型与设置，
所以“全新”指应用与 Homebrew 收据不存在，不代表空用户账户或首次模型下载。

### Homebrew 全新安装

1. 停止模型、退出应用，执行正常 `brew uninstall --cask`。
2. 确认 `/Applications/27B Launcher.app` 与 Caskroom 收据目录均不存在，模型数据仍存在。
3. 执行 `brew install --cask mreasonyang/27b-launcher/27b-launcher`，成功安装 0.10.13。
4. 实际打开应用、加载模型、在内置 Browser 聊天，收到 `Fresh Homebrew install passed.`。
5. 重启后模型 PID 从 44484 变为 44859，健康检查恢复正常；停止后进程退出、界面显示已停止。
6. 签名、公证票据及 Gatekeeper 检查通过。

结论：应用全新安装与核心链路 PASS。Homebrew 输出的其他 Tap 弃用/信任提示不影响本 Cask 安装，未修改其他 Tap。

### DMG 手动安装

1. 从公开 GitHub Release 重新下载 DMG，SHA-256 与 Cask 一致；镜像校验及公证票据通过。
2. 正常卸载 Homebrew 应用，确认 Applications 目标为空，挂载 DMG。
3. Finder 拖拽未产生目标文件；改用 Finder 选中应用、复制、打开镜像内的 Applications 别名、粘贴，实际复制成功。
4. 确认目标版本 0.10.13，签名、公证和 Gatekeeper 均通过；卸载镜像后从 `/Applications` 启动应用。

5. 模型加载正常，内置 Browser 收到 `DMG install passed.` 完整回复。
6. 重启模型 PID 从 45328 变为 45534，健康检查恢复正常；停止后模型进程退出，界面显示已停止。
7. 退出应用，将 DMG 测试副本移入本地 QA 目录，再通过 Homebrew 正常安装恢复日常使用。

结论：DMG Finder 复制安装及核心功能 PASS。拖拽动作未计为通过；自动化的两次拖拽没有产生文件，未发现应用复制安装本身的失败。
安装时未关闭 Gatekeeper 或移除 quarantine。由于当前用户此前已授权过同版本应用，
不宣称全新用户的首次 Gatekeeper 弹窗已重新验证。
