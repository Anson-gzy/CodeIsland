---
description: codeisland、AskIsland、ask-island、刘海面板、灵动岛、液态玻璃：agent 要用户选/答/动手时在刘海弹出的面板（由 wxtsky/CodeIsland 精简而来，上游其余代码已删）
---
# codeisland → AskIsland

只做一件事的刘海面板：agent 要用户选、答、动手（操作电脑/手机、输密码、登录）时在刘海弹出，用户在上面作答。代码全在 `AskIsland/`（SwiftPM，macOS 26+），规格见 `AskIsland/SPEC.md`。
上游 https://github.com/wxtsky/CodeIsland （MIT，见 `LICENSE`）的其余代码已删；要参考上游实现去看 git 历史（删除前最后一个提交 f4b1385）。

- 接口：`ask-island ask|do|notify`（等用户答完打印结果；退出码 0 答了、2 没运行、3 拒绝、4 超时、5 关闭）；Claude 的 AskUserQuestion 和权限请求经 `ask-island hook` 进来。没有 MCP（用户要一种接口，CLI 各客户端都能用）
- 安装：`AskIsland/scripts/install.sh`（release 构建 → `~/Applications/AskIsland.app` + LaunchAgent `local.askisland` + `~/.local/bin/ask-island` + Claude hooks，hook 同时写进 maat 模板）
- 测试：`cd AskIsland && swift test`；`scripts/smoke-app.sh` 起 App 走一次真实 HTTP。界面验证：`ASK_ISLAND_ENDPOINT=<临时路径> .build/debug/AskIsland --demo`，垫彩条图截图
- 玻璃：`NSGlassEffectView` 私有 `_variant = 11`（背景不模糊、边缘折射）；公开的 SwiftUI `.glassEffect` 和 AppKit `.clear`/`.regular` 都会把背景糊掉。**折射带宽度随 `cornerRadius` 增大**（r24 只剩细边，r60+ 才是厚透镜边）；variant 11 激活与否外观一样；背景层 `CABackdropLayer` 的私有滤镜 `glassBackground` 可直接调（`inputBlurRadius`、`inputInnerRefractionHeight/Amount` 等），`ThickGlassView` 每次 layout 重设；白色高光边是图层 `@3`（保留四周，用渐变遮罩去掉底部；玻璃图层树 y=0 在顶部）；形变动画用 `Animatable` 的 `IslandGlass` 逐帧改尺寸（scaleEffect 会把圆角和透镜边压扁）
- 截图验证：后面垫一张清晰的彩条/文字图才看得出模糊与折射；测试窗口用完按进程名 `pkill -x` 关掉
- 坑：hosting view 要 `sizingOptions = []`（否则展开时窗口按旧原点改尺寸，岛横向漂移）；收起态的内容必须画在刘海高度以下（刘海那一条被摄像头挡住，截图看得见实际看不见）；中文输入法下自动化敲空格会被当成选词
