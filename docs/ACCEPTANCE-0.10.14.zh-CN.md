# 0.10.14（43）发布与安装回归

2026-10-01，当前 Apple Silicon Mac，保留已有模型、设置与密钥。
本版本包含用户提交的 README 和使用指南整理，应用逻辑未变。

- 本地 263 tests / 26 suites PASS，48.111 秒。
- [源代码 CI](https://github.com/mreasonyang/27b-launcher/actions/runs/36814037998)：首次后台日志故障测试在 4 秒内未收到回调；同一提交重跑成功，未放宽测试或改应用逻辑。
- [正式发布](https://github.com/mreasonyang/27b-launcher/actions/runs/36814869310)：签名、公证、打包启动检查、发布、Tap 更新 PASS。
- DMG SHA-256：`522da4fc63b75d235f3411d5b3bcb7ff8c3798be8bafbee38f3325e6b3550634`。

| 路径 | 实机结果 |
| --- | --- |
| Homebrew 升级 | 正常执行 0.10.13 → 0.10.14，应用版本 0.10.14 / build 43；打开、加载模型、聊天返回 `Homebrew 0.10.14 passed.`、停止均通过 |
| DMG 安装 | 重新下载公开包；卸载 Homebrew 应用确认目标为空；通过 Finder 复制到 Applications，卸载镜像后运行；打开、加载模型、聊天返回 `DMG 0.10.14 passed.`、停止后模型进程退出均通过 |
| 签名 | 两条路径的 strict/deep codesign、stapler、Gatekeeper accepted / Notarized Developer ID 均通过 |
| 最终恢复 | DMG 测试副本保存在本地 QA 目录，重新执行 Homebrew install 恢复日常安装；模型停止、设置和模型数据保留 |

本次为简单主流程回归，未重跑首次模型下载、图片识别、存储迁移、登录启动或 LAN 访问。
DMG 使用 Finder 复制粘贴安装，未宣称拖拽手势验收。截图保存在本地 `.build/qa-0.10.14/`。
