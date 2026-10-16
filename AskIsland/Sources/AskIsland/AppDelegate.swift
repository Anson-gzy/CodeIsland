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
            let errorItem = NSMenuItem(title: "Server failed to start: \(err)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(NSMenuItem.separator())
        }

        let questionItem = NSMenuItem(title: "Test: Ask a Question", action: #selector(testQuestionAction), keyEquivalent: "")
        questionItem.target = self
        menu.addItem(questionItem)

        let actionItem = NSMenuItem(title: "Test: Request an Action", action: #selector(testActionAction), keyEquivalent: "")
        actionItem.target = self
        menu.addItem(actionItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    @objc private func testQuestionAction() {
        Task { @MainActor in
            let q = AskQuestion(
                header: "Cluster",
                question: "Which cluster should this deploy to?",
                options: [AskOption(label: "Staging"), AskOption(label: "Production")],
                multiSelect: false,
                allowText: true
            )
            let req = AskRequest(
                kind: .question,
                title: "Pick a deploy target",
                detail: "Test request: pick a cluster, or type a custom one under Other.",
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
                title: "Approve the 2FA prompt on your iPhone",
                detail: "1. Open the authenticator app on your phone\n2. Approve this sign-in request",
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
                header: "Single",
                question: "部署到哪个环境？",
                options: [AskOption(label: "预发环境", description: "先在 staging 上验一遍"), AskOption(label: "生产环境")],
                multiSelect: false,
                allowText: false
            )
            let q2 = AskQuestion(
                header: "Multi",
                question: "Which add-on services should be enabled?",
                options: [
                    AskOption(label: "Redis cache", description: "Speeds up sessions and hot data"),
                    AskOption(label: "Elasticsearch", description: "Full-text search and log analytics"),
                    AskOption(label: "Prometheus", description: "Metrics and alerting")
                ],
                multiSelect: true,
                allowText: true
            )
            let req1 = AskRequest(
                kind: .question,
                title: "确认部署配置",
                detail: "Model-written text keeps the model's language; only buttons and hints are English.",
                questions: [q1, q2],
                source: AskSource(agent: "claude", cwd: "/tmp/demo/my-project")
            )
            _ = await store.submit(req1)
        }

        Task { @MainActor in
            let req2 = AskRequest(
                kind: .action,
                title: "Approve the 2FA prompt on your iPhone",
                detail: "1. Open the authenticator app on your phone\n2. Approve this sign-in request",
                actionKind: .phone,
                source: AskSource(agent: "claude", cwd: "/tmp/demo/my-project")
            )
            _ = await store.submit(req2)
        }

        Task { @MainActor in
            let req3 = AskRequest(
                kind: .notify,
                title: "Build is ready",
                detail: "All preflight checks passed. Waiting to run.",
                source: AskSource(agent: "claude", cwd: "/tmp/demo/my-project")
            )
            _ = await store.submit(req3)
        }
    }
}
