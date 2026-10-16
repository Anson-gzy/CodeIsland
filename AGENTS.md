---
description: codeisland、CodeIsland、刘海面板、灵动岛、液态玻璃：wxtsky/CodeIsland 的本地 clone，原型把展开态背景换成原生 Liquid Glass
---
# codeisland

上游：https://github.com/wxtsky/CodeIsland （SwiftPM，最低 macOS 14）。

- 构建：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product CodeIsland`
- 看展开态：`.build/debug/CodeIsland --preview multi`（场景见 `Sources/CodeIsland/DebugHarness.swift`；`--collapsed` 看收起态）。preview 也会读到本机真实的 agent 会话
- 液态玻璃原型：`NotchPanelView.swift` 里的 `IslandBackground`。展开且 macOS 26+ 用 `.glassEffect(.clear, in: NotchPanelShape)`，上半部分纯黑、往下长渐变到透明玻璃（对照用户给的参考图）；收起态和旧系统仍是纯黑
