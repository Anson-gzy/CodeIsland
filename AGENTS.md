---
description: codeisland、CodeIsland、刘海面板、灵动岛、液态玻璃：wxtsky/CodeIsland 的本地 clone，原型把展开态背景换成原生 Liquid Glass
---
# codeisland

上游：https://github.com/wxtsky/CodeIsland （SwiftPM，最低 macOS 14）。

- 构建：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product CodeIsland`
- 看展开态：`.build/debug/CodeIsland --preview multi`（场景见 `Sources/CodeIsland/DebugHarness.swift`；`--collapsed` 看收起态）。preview 也会读到本机真实的 agent 会话
- 液态玻璃原型：`NotchPanelView.swift` 里的 `IslandBackground` + `ClearLensGlass`。展开且 macOS 26+ 用 `NSGlassEffectView`，私有 `_variant = 11`（背景不模糊、只有边缘折射，参考图要的就是这个）；公开的 SwiftUI `.glassEffect` 和 AppKit `.clear`/`.regular` 都会把背景糊掉。黑色渐变放在玻璃的 contentView 里，玻璃顶边推到窗口外只露底部圆角。收起态和旧系统仍是纯黑
- 截图验证：后面垫一张清晰的彩条/文字图才看得出模糊与折射；测试窗口用完按进程名 `pkill -x` 关掉

## AskIsland（`AskIsland/`，独立的 SwiftPM 包）

只做一件事的刘海面板：agent 要用户选、答、动手（操作电脑/手机、输密码、登录）时在刘海弹出，用户在上面作答。规格见 `AskIsland/SPEC.md`。
- 接口：`ask-island ask|do|notify`（等用户答完打印结果；退出码 0 答了、2 没运行、3 拒绝、4 超时、5 关闭）；Claude 的 AskUserQuestion 和权限请求经 `ask-island hook` 进来。没有 MCP（用户要一种接口，CLI 各客户端都能用）
- 安装：`AskIsland/scripts/install.sh`（release 构建 → `~/Applications/AskIsland.app` + LaunchAgent `local.askisland` + `~/.local/bin/ask-island` + Claude hooks，hook 同时写进 maat 模板）
- 测试：`cd AskIsland && swift test`；`scripts/smoke-app.sh` 起 App 走一次真实 HTTP。界面验证：`ASK_ISLAND_ENDPOINT=<临时路径> .build/debug/AskIsland --demo`，垫彩条图截图
- 坑：hosting view 要 `sizingOptions = []`（否则展开时窗口按旧原点改尺寸，岛横向漂移）；收起态的内容必须画在刘海高度以下（刘海那一条被摄像头挡住，截图看得见实际看不见）；中文输入法下自动化敲空格会被当成选词
