import SwiftUI
import AppKit
import AskIslandCore

// MARK: - Animation & Transitions

enum NotchAnimation {
    /// Open / grow: a soft spring with a little overshoot, like the notch stretching into a capsule.
    static var open: Animation {
        .spring(response: 0.5, dampingFraction: 0.78)
    }
    /// Close / shrink: nearly critically damped, a touch of settle so it does not stop dead at the notch.
    static var close: Animation {
        .spring(response: 0.52, dampingFraction: 0.9)
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
            removal: .blurFade.combined(with: .scale(scale: 0.94, anchor: .top))
                .animation(.easeOut(duration: 0.18))
        )
    }
}

// MARK: - Glass

/// Variant-11 glass retuned to read as a thick, slightly frosted slab: the backdrop's private
/// `glassBackground` filter gets a light blur and deeper refraction bands, and the white specular rim
/// (layer "@3") is thinned. Values are re-applied on every layout because the glass rebuilds its layers
/// and filters when its shape changes (macOS 27.2).
@available(macOS 26.0, *)
final class ThickGlassView: NSGlassEffectView {
    static let blurRadius = 3.0
    static let refractionHeight = 86.0
    static let refractionAmount = -110.0
    static let outerRefractionHeight = 36.0
    static let outerRefractionAmount = 22.0
    /// Brightest the backdrop may show through (0...1): mid grey, like Voice Pill's glass.
    static let faceWhite = 0.68

    /// 0...1, scales the refraction bands. They are fixed in points, so on a shrinking panel they would cover
    /// the whole slab and smear everything behind it; the morph fades them out with the glass.
    var strength: Double = 1


    private func retune() {
        if let layer { tune(layer) }
    }

    /// Private NSGlassEffectView hook called when the window gains or loses key. Its stock work rebuilds the
    /// backdrop filters with the default values for the new state (blur 0, thin refraction when inactive), so
    /// clicking the panel or anywhere else flashed a clearer glass and then our blur came back a moment later.
    /// The island should look the same with or without focus: skip the rebuild and keep our values.
    @objc func _windowChangedKeyState() {
        retune()
    }
    override func layout() {
        super.layout()
        retune()
    }

    /// Focus changes reach the glass as a new `_effectiveGlassMaterialContext`; the stock filters are rebuilt
    /// a few frames later, outside any hook we get. Hold our values over every frame until it has settled.
    override func didChangeValue(forKey key: String) {
        super.didChangeValue(forKey: key)
        if key == "_effectiveGlassMaterialContext" { holdTuning() }
    }

    private var holdTimer: Timer?
    private func holdTuning(for duration: TimeInterval = 0.5) {
        retune()
        holdTimer?.invalidate()
        let end = Date().addingTimeInterval(duration)
        holdTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, Date() < end else { timer.invalidate(); return }
                self.retune()
            }
        }
        RunLoop.main.add(holdTimer!, forMode: .common)
    }

    /// A shape change (corner radius, size) rebuilds the backdrop filters after layout, on the way to the
    /// next commit, so a layout-time retune alone misses it and the stock heavy blur shows for the whole
    /// morph. Retune now and again right after the current transaction has been committed.
    func retuneAfterShapeChange() {
        retune()
        DispatchQueue.main.async { [weak self] in self?.retune() }
    }

    /// Focusing a text field makes the panel key and the app active; the glass then rebuilds its filters
    /// for the new state without a layout pass, and the blur jumped back to the stock value. Re-apply on
    /// those changes too (now and once the glass has settled).
    private var stateObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        stateObservers = []
        guard let window else { return }
        let names: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didBecomeKeyNotification, window),
            (NSWindow.didResignKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, nil),
            (NSApplication.didResignActiveNotification, nil),
        ]
        for (name, object) in names {
            stateObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.retune()
                    for delay in [0.05, 0.25] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.retune() }
                    }
                }
            })
        }
    }

    /// Rim highlight width: the rim's private CASDFKeyFillHighlightEffect draws it `keyHeight` / `fillHeight`
    /// points wide (3.5 by default) with a soft glow `diffuseHeightScale` times that (8). Narrower here.
    static let rimHeight = 1.5
    static let rimDiffuseScale = 4.0

    private func thinRim(_ rim: CALayer) {
        guard let effect = rim.value(forKey: "effect") as? NSObject,
              effect.responds(to: Selector(("setKeyHeight:"))) else { return }
        effect.setValue(Self.rimHeight, forKey: "keyHeight")
        effect.setValue(Self.rimHeight, forKey: "fillHeight")
        effect.setValue(Self.rimDiffuseScale, forKey: "diffuseHeightScale")
        rim.setValue(effect, forKey: "effect")
    }

    private func tune(_ layer: CALayer) {
        if layer.name == "@3" {
            thinRim(layer)  // the thin white highlight along the bottom edge, as in the reference
        }
        if String(describing: type(of: layer)) == "CABackdropLayer",
           layer.filters?.contains(where: { ($0 as AnyObject).value(forKey: "name") as? String == "glassBackground" }) == true {
            let k = "filters.glassBackground."
            layer.setValue(Self.blurRadius, forKeyPath: k + "inputBlurRadius")
            for i in 0..<4 { layer.setValue(1.0, forKeyPath: k + "inputBlurOpacity\(i)") }
            // Grey, not white: the backdrop's luminance is mapped into black...faceWhite, so a white window
            // behind the panel reads as mid grey and white text on it stays legible.
            layer.setValue(1.0, forKeyPath: k + "inputFaceOpacity")
            layer.setValue(Self.faceWhite, forKeyPath: k + "inputFaceColorMatrixWhite")
            layer.setValue(Self.refractionHeight * strength, forKeyPath: k + "inputInnerRefractionHeight")
            layer.setValue(Self.refractionAmount * strength, forKeyPath: k + "inputInnerRefractionAmount")
            layer.setValue(Self.outerRefractionHeight * strength, forKeyPath: k + "inputOuterRefractionHeight")
            layer.setValue(Self.outerRefractionAmount * strength, forKeyPath: k + "inputOuterRefractionAmount")
        }
        layer.sublayers?.forEach { tune($0) }
    }
}

/// Lens glass (private variant 11, retuned by `ThickGlassView`) tinted from the top: solid black over the
/// notch and the title row, then thinning out into the glass, whose backdrop is capped at mid grey
/// (`ThickGlassView.faceWhite`) so white text stays legible over a bright window.
@available(macOS 26.0, *)
struct ClearLensGlass: NSViewRepresentable {
    var cornerRadius: CGFloat
    var height: CGFloat
    /// Glass hidden above the screen edge (the pushed-up top corners); the tint is laid out on the rest.
    var topInset: CGFloat = 0
    /// Refraction strength, see `ThickGlassView.strength`.
    var strength: Double = 1

    final class TintView: NSView {
        let black = CAGradientLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            for g in [black] {
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
        (glass as? ThickGlassView)?.strength = strength
        guard let tint = glass.contentView as? TintView else { return }
        let h = max(height, 1)
        let total = h + topInset
        // Fractions below are of the visible height; map them onto the whole glass.
        func at(_ y: Double) -> NSNumber { NSNumber(value: (Double(topInset) + y * Double(h)) / Double(total)) }
        // Proportions measured from the reference video: solid black over the top ~47% of the panel, then
        // a long, soft fade (half linear, half smoothstep) that is gone by ~90% of the height, leaving
        // grey glass at the bottom. Pure proportions, whatever the height: a short notify card fades the
        // same way as a tall question card (mid-morph darkness is the black curtain's job in IslandSurface).
        let f0 = 0.47
        let f1 = 0.9
        let reveal = 1.0
        let steps = 14
        var blackColors: [CGColor] = [NSColor.black.cgColor]
        var blackStops: [NSNumber] = [0]
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let eased = 0.5 * t + 0.5 * t * t * (3 - 2 * t)
            let y = f0 + (f1 - f0) * t
            blackStops.append(at(y))
            blackColors.append(NSColor.black.withAlphaComponent(1 - eased * reveal).cgColor)
        }
        blackStops.append(1)
        blackColors.append(NSColor.black.withAlphaComponent(1 - reveal).cgColor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.black.colors = blackColors
        tint.black.locations = blackStops
        CATransaction.commit()
        tint.needsLayout = true
        glass.needsLayout = true
        (glass as? ThickGlassView)?.retuneAfterShapeChange()
    }
}

/// The island's surface at a given size, morphing between the collapsed notch extension (`glass` = 0:
/// solid black, small bottom radius, tiny shoulders) and the glass panel (`glass` = 1). Animatable, so
/// SwiftUI re-lays it out every frame of a spring: the shape really changes width, height and radius (a
/// scaleEffect would squash the corners and the lens edge, and NSViewRepresentable frames are not
/// interpolated on their own). The top edge is flat on the screen edge and flares out into the menu bar
/// through concave shoulders, like the hardware notch, instead of rounding inward.
struct IslandSurface: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    var glass: CGFloat
    var notchHeight: CGFloat

    static let panelRadius: CGFloat = 40
    static let pillRadius: CGFloat = 12
    static let panelShoulder: CGFloat = 14
    static let pillShoulder: CGFloat = 4

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), glass) }
        set { width = newValue.first.first; height = newValue.first.second; glass = newValue.second }
    }

    static func radius(width: CGFloat, height: CGFloat, glass: CGFloat) -> CGFloat {
        let r = pillRadius + (panelRadius - pillRadius) * glass
        return max(0, min(r, height / 2, width / 2))
    }

    var body: some View {
        let g = min(max(glass, 0), 1)
        let radius = Self.radius(width: width, height: height, glass: g)
        let shoulder = Self.pillShoulder + (Self.panelShoulder - Self.pillShoulder) * g
        // Black notch shape: covers everything while collapsed, then pulls back to the band under the notch
        // (where the glass tint is black anyway) so only its flared shoulders remain over the glass.
        // Eased (g^3) so the black closes over the glass early on the way down and the shrinking capsule
        // reads as the dark notch, not a grey slab; on the way up the glass opens only near full size.
        let gb = g * g * g
        let solidTo = height + (notchHeight - height) * gb
        let fadeTo = height + (notchHeight * 2 - height) * gb
        ZStack(alignment: .top) {
            if #available(macOS 26.0, *), g > 0.001 {
                // Top corners pushed above the screen edge: only the bottom corners (and their rim) show.
                ClearLensGlass(cornerRadius: radius, height: height, topInset: radius * 2, strength: Double(gb))
                    .frame(width: width, height: height + radius * 2)
                    .offset(y: -radius * 2)
                    // No .opacity(g): any alpha below 1 on the backdrop drops the retuned filter for a frame or
                    // two and the system's heavy blur flashes through. The black curtain covers it instead.
            }
            NotchShape(bottomRadius: radius, shoulder: shoulder)
                .fill(.black)
                .frame(width: width + shoulder * 2, height: height)
                .mask(alignment: .top) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: min(solidTo / max(height, 1), 1)),
                            .init(color: .clear, location: min(fadeTo / max(height, 1), 1) + 0.0001),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .frame(width: width + shoulder * 2, height: height, alignment: .top)
    }
}

/// Flat top on the screen edge, concave shoulders flaring out by `shoulder` on both sides (drawn inside the
/// frame, so the frame is `shoulder` wider on each side than the body), straight sides, round bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    func path(in frame: CGRect) -> Path {
        let ext = shoulder
        let rect = frame.insetBy(dx: ext, dy: 0)
        let br = min(bottomRadius, rect.width / 2, rect.height / 2)
        let k: CGFloat = 0.62  // continuous-curvature corners
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - ext, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + ext, y: rect.minY))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + ext),
            control1: CGPoint(x: rect.maxX + ext * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + ext * 0.35)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addCurve(
            to: CGPoint(x: rect.maxX - br, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - br * (1 - k)),
            control2: CGPoint(x: rect.maxX - br * (1 - k), y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        p.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - br),
            control1: CGPoint(x: rect.minX + br * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - br * (1 - k))
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

/// Clip for the island's content, animated with the same spring as the surface, so content never spills
/// outside the shape while it grows or shrinks.
struct IslandClipShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var glass: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), glass) }
        set { width = newValue.first.first; height = newValue.first.second; glass = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = IslandSurface.radius(width: width, height: height, glass: min(max(glass, 0), 1))
        let body = CGRect(x: rect.midX - width / 2, y: rect.minY - r, width: width, height: height + r)
        return Path(roundedRect: body, cornerRadius: r, style: .continuous)
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
    /// Pointer over the collapsed pill: it swells a little (wider and a bit taller) as a hover cue.
    @State private var pillHovered = false
    /// Hiding (last request answered) uses the same shrink as collapsing: the surface stays opaque and
    /// shrinks into the notch as black, and only fades out once it has settled there.
    @State private var hiddenSettled = true

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

    private var collapsedWidth: CGFloat { notchWidth + 64 }
    private var collapsedHeight: CGFloat { notchHeight + CollapsedIslandView.stripHeight }

    /// Size of the one surface in each state; the springs in `body` morph between them.
    private var surfaceSize: CGSize {
        switch currentState {
        case .hidden: return CGSize(width: notchWidth, height: notchHeight)
        case .collapsed:
            return CGSize(width: collapsedWidth + (pillHovered ? 20 : 0), height: collapsedHeight + (pillHovered ? 4 : 0))
        case .expanded: return CGSize(width: 480, height: expandedHeight)
        }
    }

    /// 0 = plain black notch extension (hidden, collapsed), 1 = glass panel.
    private var glassAmount: CGFloat { currentState == .expanded ? 1 : 0 }

    /// Clickable area: the surface plus its shoulders. Everywhere else the window lets clicks through.
    private var hitSize: CGSize {
        let shoulder = currentState == .expanded ? IslandSurface.panelShoulder : IslandSurface.pillShoulder
        return CGSize(width: surfaceSize.width + shoulder * 2, height: surfaceSize.height)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // One surface for every state: it extends the notch downward into the pill and grows on into the
            // glass panel, its flat top on the screen's top edge, flaring into the menu bar at the shoulders.
            IslandSurface(
                width: surfaceSize.width,
                height: surfaceSize.height,
                glass: glassAmount,
                notchHeight: notchHeight
            )
            .opacity(currentState == .hidden && hiddenSettled ? 0 : 1)
            .allowsHitTesting(false)

            ZStack(alignment: .top) {
                // Collapsed pill
                if currentState == .collapsed {
                    CollapsedIslandView(
                        count: store.pending.count,
                        request: store.pending.first,
                        pulseTrigger: pulseTrigger,
                        hovered: pillHovered,
                        onExpand: {
                            withAnimation(NotchAnimation.open) {
                                controller.isCollapsed = false
                            }
                        }
                    )
                    .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { pillHovered = hovering }
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
            // Content is cut by the moving surface edge, so nothing spills out while it grows or shrinks.
            .clipShape(IslandClipShape(width: surfaceSize.width, height: surfaceSize.height, glass: glassAmount))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(currentState == .expanded ? NotchAnimation.open : NotchAnimation.close, value: currentState)
        .onChange(of: currentState) { _, state in
            if state != .collapsed { pillHovered = false }
            if state != .hidden {
                hiddenSettled = false  // armed before the next hide, so its first frame is already opaque
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard currentState == .hidden else { return }
                    withAnimation(.easeOut(duration: 0.15)) { hiddenSettled = true }
                }
            }
        }
        // Answering the last request also changes the id (to nil): that is a close, not a content swap.
        .animation(currentState == .hidden ? NotchAnimation.close : NotchAnimation.open, value: store.pending.first?.id)
        .animation(NotchAnimation.open, value: measuredExpandedHeight)
        .onChange(of: hitSize, initial: true) { _, size in
            controller.hitSize = size
        }
    }
}

// MARK: - Collapsed Island View

struct CollapsedIslandView: View {
    let count: Int
    var request: AskRequest?
    let pulseTrigger: Int
    var hovered = false
    let onExpand: () -> Void

    @State private var pulseScale: CGFloat = 1.0

    /// The hardware notch hides everything drawn at its height, so the content sits in a strip below it.
    static let stripHeight: CGFloat = 22

    /// What is waiting, in one glyph: the request kind, or for an action what it asks the hands to do.
    static func symbol(for request: AskRequest?) -> String {
        guard let request else { return "questionmark.bubble.fill" }
        switch request.kind {
        case .question: return "questionmark.bubble.fill"
        case .notify: return "bell.fill"
        case .action:
            switch request.actionKind {
            case .computer: return "desktopcomputer"
            case .phone: return "iphone"
            case .password: return "lock.fill"
            case .login: return "person.badge.key.fill"
            default: return "hand.raised.fill"
            }
        }
    }

    var body: some View {
        // A live-activity strip: what it is (glyph), what it says (the request's own title), how many more.
        HStack(spacing: 7) {
            Image(systemName: Self.symbol(for: request))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemBlue))  // the Submit button's blue
                .scaleEffect(pulseScale)
            Text(request?.title ?? "Needs you")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if count > 1 {
                Text("+\(count - 1)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .opacity(hovered ? 1 : 0)
                .frame(width: hovered ? 10 : 0)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.stripHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 3)
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

    /// The session's own name when the agent gave one (Claude Code's session title), else the agent.
    private var agentName: String {
        if let name = request.source?.sessionName, !name.isEmpty {
            return name
        }
        if let agent = request.source?.agent, !agent.isEmpty {
            return agent
        }
        return "Agent"
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
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

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
