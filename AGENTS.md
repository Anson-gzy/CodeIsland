---
description: codeisland、CodeIsland、刘海面板、灵动岛、液态玻璃：wxtsky/CodeIsland 的本地 clone，原型把展开态背景换成原生 Liquid Glass
---
# codeisland

上游：https://github.com/wxtsky/CodeIsland （SwiftPM，最低 macOS 14）。

- 构建：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product CodeIsland`
- 看展开态：`.build/debug/CodeIsland --preview multi`（场景见 `Sources/CodeIsland/DebugHarness.swift`；`--collapsed` 看收起态）。preview 也会读到本机真实的 agent 会话
- 液态玻璃原型：`NotchPanelView.swift` 里的 `IslandBackground` + `ClearLensGlass`。展开且 macOS 26+ 用 `NSGlassEffectView`，私有 `_variant = 11`（背景不模糊、只有边缘折射，参考图要的就是这个）；公开的 SwiftUI `.glassEffect` 和 AppKit `.clear`/`.regular` 都会把背景糊掉。黑色渐变放在玻璃的 contentView 里，玻璃顶边推到窗口外只露底部圆角。收起态和旧系统仍是纯黑
- 截图验证：后面垫一张清晰的彩条/文字图才看得出模糊与折射；测试窗口用完按进程名 `pkill -x` 关掉
