#if os(macOS)
import AppKit
import SwiftUI

/// Lets split-view lists shrink with the window so they scroll instead of
/// clipping off the top. Does not add extra top padding.
struct MacHostingSizingFix: NSViewRepresentable {
    func makeNSView(context: Context) -> MacHostingSizingFixView {
        MacHostingSizingFixView()
    }

    func updateNSView(_ nsView: MacHostingSizingFixView, context: Context) {
        nsView.relaxHostingSizing()
    }
}

final class MacHostingSizingFixView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relaxHostingSizing()
    }

    func relaxHostingSizing() {
        var ancestor: NSView? = self
        while let view = ancestor {
            let name = NSStringFromClass(type(of: view))
            if name.contains("HostingView"), view.responds(to: Selector(("setSizingOptions:"))) {
                view.setValue(NSHostingSizingOptions.minSize.rawValue, forKey: "sizingOptions")
            }
            ancestor = view.superview
        }
    }
}

extension View {
    func hmMacListFillsColumn() -> some View {
        frame(minHeight: 0, maxHeight: .infinity)
            .background {
                MacHostingSizingFix()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
#else
import SwiftUI

extension View {
    func hmMacListFillsColumn() -> some View { self }
}
#endif
