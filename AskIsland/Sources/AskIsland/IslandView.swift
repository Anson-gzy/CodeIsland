import SwiftUI
import AppKit
import AskIslandCore

// MARK: - Animation & Transitions

enum NotchAnimation {
    /// Open / grow: a soft spring with a little overshoot, like the notch stretching into a capsule.
    static var open: Animation {
        .spring(response: 0.5, dampingFraction: 0.78)
    }
    /// Close / shrink: critically damped so the capsule never dips below the notch on the way back.
    static var close: Animation {
        .spring(response: 0.4, dampingFraction: 1.0)
    }
}

private struct BlurFadeModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 10 : 0)
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

    /// Content morphs with the glass: it comes in blurred and slightly small from the top, and leaves
    /// by blurring out quickly so the next content can resolve inside the reshaping capsule.
    static var islandCard: AnyTransition {
        .asymmetric(
            insertion: .blurFade.combined(with: .scale(scale: 0.92, anchor: .top))
                .animation(NotchAnimation.open.delay(0.06)),
            removal: .blurFade.animation(.easeOut(duration: 0.16))
        )
    }
}

// MARK: - Glass

/// Variant-11 glass retuned to read as a thick, slightly frosted slab: the backdrop's private
/// `glassBackground` filter gets a light blur and a deeper inner refraction band, and the white specular
/// rim (layer "@3") stays on. Values are re-applied on every layout because the glass rebuilds its layers
/// and filters when its shape changes (macOS 27.2).
@available(macOS 26.0, *)
final class ThickGlassView: NSGlassEffectView {
    static let blurRadius = 5.0
    static let refractionHeight = 48.0
    static let refractionAmount = -75.0

    override func layout() {
        super.layout()
        if let layer { tune(layer) }
    }

    private func tune(_ layer: CALayer) {
        if String(describing: type(of: layer)) == "CABackdropLayer",
           layer.filters?.contains(where: { ($0 as AnyObject).value(forKey: "name") as? String == "glassBackground" }) == true {
            let k = "filters.glassBackground."
            layer.setValue(Self.blurRadius, forKeyPath: k + "inputBlurRadius")
            for i in 0..<4 { layer.setValue(1.0, forKeyPath: k + "inputBlurOpacity\(i)") }
            layer.setValue(Self.refractionHeight, forKeyPath: k + "inputInnerRefractionHeight")
            layer.setValue(Self.refractionAmount, forKeyPath: k + "inputInnerRefractionAmount")
        }
        layer.sublayers?.forEach { tune($0) }
    }
}

/// Lens glass (private variant 11, retuned by `ThickGlassView`) tinted from the top: solid black over the
/// notch and the title row, then thinning out into a milky white haze, so the lower part reads as frosted
/// white glass rather than a hole in the panel.
@available(macOS 26.0, *)
struct ClearLensGlass: NSViewRepresentable {
    var cornerRadius: CGFloat
    /// Points from the top that stay solid black (notch + title row).
    var solidHeight: CGFloat
    var height: CGFloat

    final class TintView: NSView {
        let black = CAGradientLayer()
        let milk = CAGradientLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            for g in [milk, black] {
                g.startPoint = CGPoint(x: 0.5, y: 1)
                g.endPoint = CGPoint(x: 0.5, y: 0)
                layer?.addSublayer(g)
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            black.frame = bounds
            milk.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = ThickGlassView()
        glass.style = .clear
        if glass.responds(to: Selector(("set_variant:"))) {
            glass.setValue(11, forKey: "_variant")
        }
        let tint = TintView()
        tint.autoresizingMask = [.width, .height]
        glass.contentView = tint
        apply(to: glass)
        return glass
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        apply(to: glass)
    }

    private func apply(to glass: NSGlassEffectView) {
        glass.cornerRadius = cornerRadius
        guard let tint = glass.contentView as? TintView else { return }
        let h = max(height, 1)
        // Locations in points, converted to fractions of the current height so the black band keeps its
        // size while the capsule grows; a small capsule (collapsed pill) is black all the way down.
        func at(_ y: CGFloat) -> NSNumber { NSNumber(value: Double(min(max(y / h, 0), 1))) }
        let s = solidHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.black.colors = [1.0, 1.0, 0.72, 0.4, 0.22, 0.16].map { NSColor.black.withAlphaComponent($0).cgColor }
        tint.black.locations = [at(0), at(s), at(s + 36), at(s + 90), at(s + 170), at(h)]
        tint.milk.colors = [0.0, 0.0, 0.17, 0.28].map { NSColor.white.withAlphaComponent($0).cgColor }
        tint.milk.locations = [at(0), at(s), at(s + 120), at(h)]
        CATransaction.commit()
        tint.needsLayout = true
        glass.needsLayout = true
    }
}

/// The island's glass at a given size. Animatable, so SwiftUI re-lays it out every frame of a spring:
/// the capsule really changes width, height and corner radius (a scaleEffect would squash the corners
/// and the lens edge, and NSViewRepresentable frames are not interpolated on their own).
struct IslandGlass: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var solidHeight: CGFloat

    static let maxRadius: CGFloat = 56

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(width, height) }
        set { width = newValue.first; height = newValue.second }
    }

    var body: some View {
        let radius = min(Self.maxRadius, height / 2, width / 2)
        Group {
            if #available(macOS 26.0, *) {
                ClearLensGlass(cornerRadius: radius, solidHeight: solidHeight, height: height)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black)
            }
        }
        .frame(width: width, height: height)
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

    private var collapsedWidth: CGFloat { notchWidth + 90 }
    private var collapsedHeight: CGFloat { notchHeight + CollapsedIslandView.stripHeight }

    /// Size of the one glass capsule in each state; the springs in `body` morph between them.
    private var glassSize: CGSize {
        switch currentState {
        case .hidden: return CGSize(width: notchWidth, height: notchHeight)
        case .collapsed: return CGSize(width: collapsedWidth, height: collapsedHeight)
        case .expanded: return CGSize(width: 480, height: expandedHeight)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // One capsule for every state: it stretches out of the notch into the pill and on into the
            // panel, all corners round, its top edge on the screen's top edge (behind the menu bar strip).
            IslandGlass(width: glassSize.width, height: glassSize.height, solidHeight: notchHeight + 40)
                .opacity(currentState == .hidden ? 0 : 1)
                .allowsHitTesting(false)

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
                .frame(width: collapsedWidth, height: collapsedHeight, alignment: .top)
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
