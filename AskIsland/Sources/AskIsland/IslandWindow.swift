import AppKit
import SwiftUI
import Combine
import AskIslandCore

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Take key status before the click is dispatched, so the first click on any control acts at once
    /// (views that don't accept first mouse would otherwise swallow it as a "focus the window" click).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { makeKey() }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        // If a text field or field editor has focus, let it handle the key event
        if let fieldEditor = firstResponder as? NSTextView, fieldEditor.isFieldEditor {
            super.keyDown(with: event)
            return
        }

        if IslandWindowController.shared?.handleKeyDown(event) == true {
            return
        }

        super.keyDown(with: event)
    }
}

private class IslandHostingView<Content: View>: NSHostingView<Content> {
    private var applyingDeferred = false
    private var pendingConstraintsValue: Bool?
    private var pendingLayoutValue: Bool?

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if applyingDeferred {
                super.needsUpdateConstraints = newValue
                return
            }
            if pendingConstraintsValue == nil, super.needsUpdateConstraints == newValue { return }
            let alreadyScheduled = pendingConstraintsValue != nil
            pendingConstraintsValue = newValue
            guard !alreadyScheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let value = self.pendingConstraintsValue else { return }
                self.pendingConstraintsValue = nil
                self.applySuperNeedsUpdateConstraints(value)
            }
        }
    }

    private func applySuperNeedsUpdateConstraints(_ value: Bool) {
        applyingDeferred = true
        super.needsUpdateConstraints = value
        applyingDeferred = false
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if applyingDeferred {
                super.needsLayout = newValue
                return
            }
            if pendingLayoutValue == nil, super.needsLayout == newValue { return }
            let alreadyScheduled = pendingLayoutValue != nil
            pendingLayoutValue = newValue
            guard !alreadyScheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let value = self.pendingLayoutValue else { return }
                self.pendingLayoutValue = nil
                self.applySuperNeedsLayout(value)
            }
        }
    }

    private func applySuperNeedsLayout(_ value: Bool) {
        applyingDeferred = true
        super.needsLayout = value
        applyingDeferred = false
    }
}

@MainActor
final class IslandWindowController: ObservableObject {
    static weak var shared: IslandWindowController?

    let store: AskStore
    let cardState = QuestionCardState()

    var panel: KeyablePanel?
    private var cancellables = Set<AnyCancellable>()
    private var knownRequestIds = Set<String>()
    private var previousApp: NSRunningApplication?

    @Published var isCollapsed: Bool = false
    @Published var pulseTrigger: Int = 0

    /// Clickable size of the island (top-centered in the panel), reported by the root view. The panel is
    /// much larger than the island, so it only takes mouse events while the pointer is over the island.
    var hitSize: CGSize = .zero {
        didSet { updateMousePassThrough() }
    }
    private var pointerTimer: Timer?

    var isPendingEmpty: Bool {
        store.pending.isEmpty
    }

    init(store: AskStore) {
        self.store = store
        IslandWindowController.shared = self
    }

    func setup() {
        // Track frontmost app before we are ever focused
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            self.previousApp = front
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self = self else { return }
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self.previousApp = app
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateWindowFrame()
            }
        }

        let rootView = IslandRootView(
            store: store,
            cardState: cardState,
            controller: self,
            onFocusTextField: { [weak self] in
                self?.makeKeyAndActivateApp()
            }
        )

        let hostingView = IslandHostingView(rootView: rootView)
        // Fixed window frame; hostingView does not resize the window
        hostingView.sizingOptions = []

        let screen = ScreenDetector.preferredScreen
        let screenFrame = screen.frame
        let width: CGFloat = 560  // 480 island + room for the spring overshoot
        let height: CGFloat = screenFrame.height * 0.7
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - height
        let fixedFrame = NSRect(x: x, y: y, width: width, height: height)

        let panel = KeyablePanel(
            contentRect: fixedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
        panel.setFrame(fixedFrame, display: true)

        self.panel = panel
        panel.orderFrontRegardless()

        store.$pending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pending in
                self?.handlePendingChange(pending)
            }
            .store(in: &cancellables)
    }

    func makeKeyAndActivateApp() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        panel?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handlePendingChange(_ pending: [AskRequest]) {
        let newRequests = pending.filter { !knownRequestIds.contains($0.id) }
        let currentIds = Set(pending.map(\.id))

        if !newRequests.isEmpty {
            if knownRequestIds.isEmpty {
                // Expanding for the first arrival
                withAnimation(NotchAnimation.open) {
                    isCollapsed = false
                }
                panel?.orderFrontRegardless()
            } else if isCollapsed {
                // Keep collapsed and pulse badge once
                pulseTrigger += 1
            }
        }

        knownRequestIds = currentIds

        if pending.isEmpty {
            // Reactivate previously frontmost app
            if let app = previousApp, !app.isTerminated {
                app.activate()
            }
            previousApp = nil

            panel?.ignoresMouseEvents = true
            pointerTimer?.invalidate()
            pointerTimer = nil
        } else {
            panel?.orderFrontRegardless()
            // Poll the pointer only while something is showing (no wakeups on an idle Mac).
            if pointerTimer == nil {
                pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateMousePassThrough() }
                }
            }
        }
        updateMousePassThrough()
    }

    /// Clicks outside the island fall through to whatever is underneath.
    func updateMousePassThrough() {
        guard let panel else { return }
        guard !store.pending.isEmpty, hitSize.width > 0 else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let f = panel.frame
        let island = NSRect(x: f.midX - hitSize.width / 2, y: f.maxY - hitSize.height,
                            width: hitSize.width, height: hitSize.height)
        let ignore = !island.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    func updateWindowFrame() {
        guard let panel = panel else { return }
        let screen = ScreenDetector.preferredScreen
        let screenFrame = screen.frame
        let width: CGFloat = 560  // 480 island + room for the spring overshoot
        let height: CGFloat = screenFrame.height * 0.7
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - height
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let request = store.pending.first else { return false }

        // Esc: collapse
        if event.keyCode == 53 {
            withAnimation(NotchAnimation.close) {
                isCollapsed = true
            }
            return true
        }

        switch request.kind {
        case .question:
            // Return: submit if enabled
            if event.keyCode == 36 || event.characters == "\r" {
                if cardState.isSubmitEnabled(for: request) {
                    cardState.submit(for: request, store: store)
                    return true
                }
                return false
            }

            // 1-9: toggle option of first unanswered question
            if let chars = event.characters, let firstChar = chars.first,
               firstChar >= "1" && firstChar <= "9",
               let digit = Int(String(firstChar)) {
                let optionIndex = digit - 1
                if cardState.toggleOption(for: request, optionIndex: optionIndex) {
                    return true
                }
            }

        case .action:
            break

        case .notify:
            if event.keyCode == 36 || event.characters == "\r" {
                store.resolve(request.id, AskResponse(id: request.id, status: .dismissed))
                return true
            }
        }

        return false
    }
}
