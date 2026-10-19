import Foundation

/// Where the app runs, for the few places the Mac differs from an iPad:
/// on the Mac each session is a window of its own, the keyboard is always
/// there, and a window behind another app is still on screen.
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif
}

import SwiftUI

extension View {
    /// A sheet on the Mac is a fixed-size panel in the middle of the window,
    /// too small for a form of any length; this gives it a size closer to
    /// what an iPad shows. Elsewhere the sheet is left as it was.
    @ViewBuilder
    func macSheetSize(width: CGFloat = 620, height: CGFloat = 760) -> some View {
        if Platform.isMac, #available(iOS 18, macCatalyst 18, *) {
            frame(idealWidth: width, idealHeight: height)
                .presentationSizing(.fitted)
        } else {
            self
        }
    }
}

extension View {
    /// Keeps the navigation bar, and the buttons on it, in place while the
    /// content scrolls. iOS 27 otherwise tucks it away on scrolling down,
    /// and on a wide iPhone (the iPhone Duo open) that takes Close, Save
    /// and Cancel with it until the user scrolls back to the top.
    @ViewBuilder
    func keepsNavigationBarOnScroll() -> some View {
        if #available(iOS 27, macCatalyst 27, *) {
            toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            self
        }
    }
}
