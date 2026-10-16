import AppKit

struct ScreenDetector {
    /// Screen with a notch, if present.
    static var screenWithNotch: NSScreen? {
        NSScreen.screens.first(where: { screenHasNotch($0) })
    }

    /// Preferred screen: the one with a notch, else the main screen.
    static var preferredScreen: NSScreen {
        if let notchScreen = screenWithNotch {
            return notchScreen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    static var hasNotch: Bool {
        screenHasNotch(preferredScreen)
    }

    static func screenHasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
        }
        return false
    }

    static func topBarHeight(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            let realNotchHeight = screen.safeAreaInsets.top
            if realNotchHeight > 0 { return realNotchHeight }
        }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBarHeight > 5 { return menuBarHeight }
        if let main = NSScreen.main {
            let mainMenuBar = main.frame.maxY - main.visibleFrame.maxY
            if mainMenuBar > 5 { return mainMenuBar }
        }
        return 25
    }

    static var notchHeight: CGFloat {
        topBarHeight(for: preferredScreen)
    }

    static func notchWidth(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            if leftWidth > 0 || rightWidth > 0 {
                return screen.frame.width - leftWidth - rightWidth
            }
        }
        return fakeNotchWidth(for: screen)
    }

    static var notchWidth: CGFloat {
        notchWidth(for: preferredScreen)
    }

    private static func fakeNotchWidth(for screen: NSScreen) -> CGFloat {
        let screenW = screen.frame.width
        return min(max(screenW * 0.14, 160), 240)
    }
}
