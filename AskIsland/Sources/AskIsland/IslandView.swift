import SwiftUI
import AppKit
import AskIslandCore

// MARK: - Notch Shapes & Glass Background

struct NotchPanelShape: Shape {
    var topExtension: CGFloat
    var bottomRadius: CGFloat
    var minHeight: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topExtension, bottomRadius) }
        set {
            topExtension = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ext = topExtension
        let maxY = max(rect.maxY, rect.minY + minHeight)
        let br = min(bottomRadius, rect.width / 4, (maxY - rect.minY) / 2)
        let k: CGFloat = 0.62

        var p = Path()
        p.move(to: CGPoint(x: rect.minX - ext, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + ext, y: rect.minY))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + ext),
            control1: CGPoint(x: rect.maxX + ext * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + ext * 0.35)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: maxY - br))
        p.addCurve(
            to: CGPoint(x: rect.maxX - br, y: maxY),
            control1: CGPoint(x: rect.maxX, y: maxY - br * (1 - k)),
            control2: CGPoint(x: rect.maxX - br * (1 - k), y: maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + br, y: maxY))
        p.addCurve(
            to: CGPoint(x: rect.minX, y: maxY - br),
            control1: CGPoint(x: rect.minX + br * (1 - k), y: maxY),
            control2: CGPoint(x: rect.minX, y: maxY - br * (1 - k))
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + ext))
        p.addCurve(
            to: CGPoint(x: rect.minX - ext, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + ext * 0.35),
            control2: CGPoint(x: rect.minX - ext * 0.35, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}

@available(macOS 26.0, *)
struct ClearLensGlass: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .clear
        if glass.responds(to: Selector(("set_variant:"))) {
            glass.setValue(11, forKey: "_variant")
        }
        let tint = NSView()
        tint.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [1, 1, 0.85, 0.55, 0.22, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0, 0.42, 0.55, 0.7, 0.86, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        tint.layer = gradient
        glass.contentView = tint
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        glass.cornerRadius = cornerRadius
    }
}

struct IslandBackground: View {
    let shape: NotchPanelShape
    let expanded: Bool
    let notchHeight: CGFloat

    var body: some View {
        if #available(macOS 26.0, *), expanded {
            ClearLensGlass(cornerRadius: shape.bottomRadius)
                .padding(.top, -shape.bottomRadius * 2)
                .overlay(
                    shape.fill(.black)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: notchHeight * 2)
                            .frame(maxHeight: .infinity, alignment: .top)
                        )
                )
                .transition(.opacity)
        } else {
            shape.fill(.black)
        }
    }
}

// MARK: - Layout Preference Keys

struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Root Island View

struct IslandRootView: View {
    @ObservedObject var store: AskStore
    @ObservedObject var cardState: QuestionCardState
    /// Owns isCollapsed / pulseTrigger; observed so the island redraws when they change.
    @ObservedObject var controller: IslandWindowController
    var onFocusTextField: () -> Void
    var onHeightChanged: (CGFloat) -> Void

    private var isCollapsed: Bool { controller.isCollapsed }
    private var pulseTrigger: Int { controller.pulseTrigger }
    private var collapsedBinding: Binding<Bool> {
        Binding(get: { controller.isCollapsed }, set: { controller.isCollapsed = $0 })
    }

    var body: some View {
        Group {
            if store.pending.isEmpty {
                Color.clear
                    .frame(width: 0, height: 0)
                    .onAppear {
                        onHeightChanged(0)
                    }
            } else if isCollapsed {
                CollapsedIslandView(
                    count: store.pending.count,
                    pulseTrigger: pulseTrigger,
                    onExpand: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            controller.isCollapsed = false
                        }
                    }
                )
                .onAppear {
                    onHeightChanged(ScreenDetector.notchHeight + CollapsedIslandView.stripHeight)
                }
            } else if let request = store.pending.first {
                ExpandedIslandView(
                    request: request,
                    store: store,
                    cardState: cardState,
                    isCollapsed: collapsedBinding,
                    onFocusTextField: onFocusTextField,
                    onHeightChanged: onHeightChanged
                )
            }
        }
        // The window is sized by the controller; pin content to the top edge under the notch.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Collapsed Island View

struct CollapsedIslandView: View {
    let count: Int
    let pulseTrigger: Int
    let onExpand: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    private var notchHeight: CGFloat {
        ScreenDetector.notchHeight
    }

    private var notchWidth: CGFloat {
        ScreenDetector.notchWidth + 24
    }

    /// The hardware notch hides everything drawn at its height, so the badge sits in a strip below it.
    static let stripHeight: CGFloat = 26

    var body: some View {
        let shape = NotchPanelShape(topExtension: 3, bottomRadius: 12, minHeight: notchHeight + Self.stripHeight)

        ZStack {
            // Black pill
            shape.fill(.black)

            // Orange badge, below the notch
            HStack(spacing: 6) {
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.orange)
                    )
                    .scaleEffect(pulseScale)
                Text("Needs you")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
            }
            .frame(height: Self.stripHeight)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: notchWidth, height: notchHeight + Self.stripHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            onExpand()
        }
        .onChange(of: pulseTrigger) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) {
                pulseScale = 1.35
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.2)) {
                    pulseScale = 1.0
                }
            }
        }
    }
}

// MARK: - Expanded Island View

struct ExpandedIslandView: View {
    let request: AskRequest
    @ObservedObject var store: AskStore
    @ObservedObject var cardState: QuestionCardState
    @Binding var isCollapsed: Bool
    var onFocusTextField: () -> Void
    var onHeightChanged: (CGFloat) -> Void

    @State private var measuredContentHeight: CGFloat = 0

    private var notchHeight: CGFloat {
        ScreenDetector.notchHeight
    }

    private var maxPanelHeight: CGFloat {
        ScreenDetector.preferredScreen.frame.height * 0.7
    }

    private var agentName: String {
        if let agent = request.source?.agent, !agent.isEmpty {
            return agent
        }
        return "Agent"
    }

    private var lastPathComponent: String? {
        if let cwd = request.source?.cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return nil
    }

    var body: some View {
        let shape = NotchPanelShape(topExtension: 14, bottomRadius: 24, minHeight: notchHeight)
        let totalFittedHeight = measuredContentHeight > 0
            ? min(measuredContentHeight + notchHeight + 16, maxPanelHeight)
            : min(240, maxPanelHeight)

        VStack(spacing: 0) {
            // Top spacer under notch
            Spacer()
                .frame(height: notchHeight + 4)

            // Header bar
            HStack(spacing: 6) {
                Text(agentName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))

                if let folder = lastPathComponent {
                    Text("·")
                        .foregroundColor(.white.opacity(0.4))
                    Text(folder)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }

                if store.pending.count > 1 {
                    Text("·")
                        .foregroundColor(.white.opacity(0.4))
                    Text("1/\(store.pending.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.2))
                        )
                }

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isCollapsed = true
                    }
                }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Card body
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    switch request.kind {
                    case .question:
                        QuestionCardView(
                            request: request,
                            store: store,
                            cardState: cardState,
                            onFocusTextField: onFocusTextField
                        )
                    case .action:
                        ActionCardView(
                            request: request,
                            store: store,
                            onFocusTextField: onFocusTextField
                        )
                    case .notify:
                        NotifyCardView(
                            request: request,
                            store: store
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                // The lower card sits on clear glass; a tight dark halo keeps text legible over any wallpaper.
                .shadow(color: .black.opacity(0.9), radius: 1.5)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightPreferenceKey.self, value: geo.size.height + 40)
                    }
                )
            }
        }
        .frame(width: 480)
        .frame(height: max(totalFittedHeight, notchHeight + 60))
        .background(
            IslandBackground(
                shape: shape,
                expanded: true,
                notchHeight: notchHeight
            )
        )
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            if height > 0 {
                self.measuredContentHeight = height
                let newTotal = min(height + notchHeight + 16, maxPanelHeight)
                onHeightChanged(newTotal)
            }
        }
    }
}
