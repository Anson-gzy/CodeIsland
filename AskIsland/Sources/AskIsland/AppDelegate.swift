import AppKit
import AskIslandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AskStore()
    var server: AskServer?
    var serverError: String?
    var islandController: IslandWindowController?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Start server
        let server = AskServer(store: store)
        self.server = server
        do {
            _ = try server.start()
        } catch {
            self.serverError = error.localizedDescription
        }

        // Setup Island window
        let controller = IslandWindowController(store: store)
        self.islandController = controller
        controller.setup()

        // Setup status item
        setupStatusItem()

        // Handle --demo
        if CommandLine.arguments.contains("--demo") {
            startDemoRequests()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if serverError != nil {
                button.image = NSImage(
                    systemSymbolName: "exclamationmark.triangle",
                    accessibilityDescription: "AskIsland Warning"
                )
            } else {
                button.image = NSImage(
                    systemSymbolName: "bubble.left.and.exclamationmark.bubble.right",
                    accessibilityDescription: "AskIsland"
                )
            }
        }

        let menu = NSMenu()

        if let err = serverError {
            let errorItem = NSMenuItem(title: "服务启动失败: \(err)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        let questionItem = NSMenuItem(title: "测试：提问", action: #selector(testQuestionAction), keyEquivalent: "")
        questionItem.target = self
        menu.addItem(questionItem)

        let actionItem = NSMenuItem(title: "测试：让我操作", action: #selector(testActionAction), keyEquivalent: "")
        actionItem.target = self
        menu.addItem(actionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func testQuestionAction() {
        Task { @MainActor in
            let q = AskQuestion(
                header: "环境",
                question: "选择要部署的目标集群：",
                options: [AskOption(label: "Staging 集群"), AskOption(label: "Production 集群")],
                multiSelect: false,
                allowText: true
            )
            let req = AskRequest(
                kind: .question,
                title: "部署目标选择",
                detail: "测试请求：请选择目标集群或在其他中输入自定义集群",
                questions: [q],
                source: AskSource(agent: "test", cwd: "/tmp/test/askisland")
            )
            _ = await store.submit(req)
        }
    }

    @objc private func testActionAction() {
        Task { @MainActor in
            let req = AskRequest(
                kind: .action,
                title: "在手机上确认两步验证",
                detail: "1. 打开手机中的身份验证器 App\n2. 点击允许本次登录请求",
                actionKind: .phone,
                source: AskSource(agent: "test", cwd: "/tmp/test/askisland")
            )
            _ = await store.submit(req)
        }
    }

    @objc private func quitAction() {
        server?.stop()
        NSApp.terminate(nil)
    }

    private func startDemoRequests() {
        Task { @MainActor in
            let q1 = AskQuestion(
                header: "单选",
                question: "部署到哪个环境？",
                options: [AskOption(label: "Staging"), AskOption(label: "Production")],
                multiSelect: false,
                allowText: false
            )
            let q2 = AskQuestion(
                header: "多选",
                question: "启用哪些附加服务？",
                options: [
                    AskOption(label: "Redis 缓存", description: "用于加速会话和热点数据"),
                    AskOption(label: "Elasticsearch", description: "全文检索与日志分析"),
                    AskOption(label: "Prometheus 监控", description: "指标采集与告警")
                ],
                multiSelect: true,
                allowText: true
            )
            let req1 = AskRequest(
                kind: .question,
                title: "确认部署配置",
                detail: "请仔细核对以下部署环境与依赖组件选项",
                questions: [q1, q2],
                source: AskSource(agent: "claude", cwd: "/tmp/demo/my-project")
            )
            _ = await store.submit(req1)
        }

        Task { @MainActor in
            let req2 = AskRequest(
                kind: .action,
                title: "在手机上确认两步验证",
                detail: "1. 打开手机中的身份验证器 App\n2. 点击允许本次登录请求",
                actionKind: .phone,
                source: AskSource(agent: "claude", cwd: "/tmp/demo/my-project")
            )
            _ = await store.submit(req2)
        }

        Task { @MainActor in
            let req3 = AskRequest(
                kind: .notify,
                title: "构建任务已就绪",
                detail: "所有预检步骤已通过，等待执行",
                source: AskSource(agent: "claude", cwd: "/tmp/demo/my-project")
            )
            _ = await store.submit(req3)
        }
    }
}
