import SwiftUI
import AppKit
import AskIslandCore

// MARK: - Animation & Transitions

enum NotchAnimation {
    /// 展开面板：微弹，有少许回弹感
    static var open: Animation {
        .spring(response: 0.42, dampingFraction: 0.82)
    }
    /// 收起面板：临界阻尼，无过冲（防止 NotchPanelShape 底边露出刘海）
    static var close: Animation {
        .spring(response: 0.38, dampingFraction: 1.0)
    }
}

private struct BlurFadeModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 5 : 0)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(
            active: BlurFadeModifier(active: true),
            identity: BlurFadeModifier(active: false)
        )
    }

    static var islandCard: AnyTransition {
        .blurFade.combined(with: .scale(scale: 0.96, anchor: .top))
    }
}

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
            control1: CGPoint(x: rect.minX - ext, y: rect.minY + ext * 0.35),
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
        gradient.colors = [1.0, 1.0, 0.75, 0.5, 0.4, 0.35].map { NSColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0, 0.2, 0.35, 0.55, 0.8, 1].map { NSNumber(value: Double($0)) }
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        tint.layer = gradient
        tint.autoresizingMask = [.width, .height]
        glass.contentView = tint
        glass.cornerRadius = cornerRadius
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        glass.cornerRadius = cornerRadius
        glass.contentView?.layer?.frame = glass.bounds
    }
}

struct IslandBackground: View {
    let shape: NotchPanelShape
    let expanded: Bool
    let notchHeight: CGFloat

    var body: some View {
        if #available(macOS 26.0, *), expanded {
            ClearLensGlass(cornerRadius: 56)
                .padding(.top, -56 * 2)
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

enum IslandState: Equatable {
    case hidden
    case collapsed
    case expanded
}

struct IslandRootView: View {
    @ObservedObject var store: AskStore
    @ObservedObject var cardState: QuestionCardState
    /// Owns isCollapsed / pulseTrigger; observed so the island redraws when they change.
    @ObservedObject var controller: IslandWindowController
    var onFocusTextField: () -> Void

    @State private var measuredExpandedHeight: CGFloat = 0

    private var isCollapsed: Bool { controller.isCollapsed }
    private var pulseTrigger: Int { controller.pulseTrigger }
    private var collapsedBinding: Binding<Bool> {
        Binding(get: { controller.isCollapsed }, set: { controller.isCollapsed = $0 })
    }

    private var currentState: IslandState {
        if store.pending.isEmpty {
            return .hidden
        } else if controller.isCollapsed {
            return .collapsed
        } else {
            return .expanded
        }
    }

    private var isExpanded: Bool {
        currentState == .expanded
    }

    private var screen: NSScreen {
        ScreenDetector.preferredScreen
    }

    private var notchHeight: CGFloat {
        ScreenDetector.topBarHeight(for: screen)
    }

    private var notchWidth: CGFloat {
        ScreenDetector.notchWidth(for: screen)
    }

    private var maxPanelHeight: CGFloat {
        screen.frame.height * 0.7
    }

    private var expandedHeight: CGFloat {
        let h = measuredExpandedHeight > 0 ? measuredExpandedHeight : min(240, maxPanelHeight)
        return min(max(h, notchHeight + 60), maxPanelHeight)
    }

    private var glassScaleX: CGFloat {
        isExpanded ? 1.0 : (notchWidth / 480.0)
    }

    private var glassScaleY: CGFloat {
        isExpanded ? 1.0 : (notchHeight / expandedHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Glass background laid out at final size (480 x expandedHeight)
            // Animated with scaleEffect anchored at top from notch width/height ratios to 1
            IslandBackground(
                shape: NotchPanelShape(
                    topExtension: 14,
                    bottomRadius: 24,
                    minHeight: notchHeight
                ),
                expanded: true,
                notchHeight: notchHeight
            )
            .frame(width: 480, height: expandedHeight, alignment: .top)
            .clipped()
            .scaleEffect(x: glassScaleX, y: glassScaleY, anchor: .top)
            .opacity(isExpanded ? 1.0 : 0.0)
            .allowsHitTesting(isExpanded)

            // Collapsed pill
            if currentState == .collapsed {
                CollapsedIslandView(
                    count: store.pending.count,
                    pulseTrigger: pulseTrigger,
                    onExpand: {
                        withAnimation(NotchAnimation.open) {
                            controller.isCollapsed = false
                        }
                    }
                )
                .frame(width: notchWidth + 24, height: notchHeight + CollapsedIslandView.stripHeight, alignment: .top)
                .background(
                    NotchPanelShape(
                        topExtension: 3,
                        bottomRadius: 12,
                        minHeight: notchHeight
                    )
                    .fill(.black)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(NotchAnimation.open) {
                        controller.isCollapsed = false
                    }
                }
                .transition(.islandCard)
            }

            // Expanded card content
            if isExpanded, let request = store.pending.first {
                ExpandedIslandView(
                    request: request,
                    store: store,
                    cardState: cardState,
                    isCollapsed: collapsedBinding,
                    onFocusTextField: onFocusTextField,
                    onHeightChanged: { height in
                        measuredExpandedHeight = height
                    }
                )
                .frame(width: 480, height: expandedHeight, alignment: .top)
                .id(request.id)
                .transition(.islandCard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(currentState == .expanded ? NotchAnimation.open : NotchAnimation.close, value: currentState)
        .animation(NotchAnimation.open, value: store.pending.first?.id)
        .animation(NotchAnimation.open, value: measuredExpandedHeight)
    }
}

// MARK: - Collapsed Island View

struct CollapsedIslandView: View {
    let count: Int
    let pulseTrigger: Int
    let onExpand: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    /// The hardware notch hides everything drawn at its height, so the badge sits in a strip below it.
    static let stripHeight: CGFloat = 26

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
        VStack(spacing: 0) {
            // Top spacer under notch
            Spacer()
                .frame(height: notchHeight + 4)

            // Header bar
            HStack(spacing: 6) {
                Text(agentName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                if let folder = lastPathComponent {
                    Text("·")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                    Text(folder)
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                }

                if store.pending.count > 1 {
                    Text("·")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                    Text("1/\(store.pending.count)")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer()

                Button(action: {
                    withAnimation(NotchAnimation.close) {
                        isCollapsed = true
                    }
                }) {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)

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
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                // The lower card sits on clear glass; a tight dark halo keeps text legible over any wallpaper.
                .shadow(color: .black.opacity(0.9), radius: 1.5)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightPreferenceKey.self, value: geo.size.height)
                    }
                )
            }
        }
        .frame(width: 480)
        .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
            if height > 0 {
                self.measuredContentHeight = height
                let total = min(height + notchHeight + 40, maxPanelHeight)
                onHeightChanged(total)
            }
        }
    }
}
