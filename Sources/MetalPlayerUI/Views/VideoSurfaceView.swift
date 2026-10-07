import AppKit
import MetalPlayerCore
import SwiftUI

public struct VideoSurfaceView: NSViewRepresentable {
    public let engine: NativePlayerEngine
    public let onFileDrop: (String) -> Void

    public init(engine: NativePlayerEngine, onFileDrop: @escaping (String) -> Void) {
        self.engine = engine
        self.onFileDrop = onFileDrop
    }

    public func makeNSView(context: Context) -> NativeVideoHostView {
        let view = NativeVideoHostView(engine: engine)
        view.onFileDrop = onFileDrop
        return view
    }

    public func updateNSView(_ nsView: NativeVideoHostView, context: Context) {
        nsView.onFileDrop = onFileDrop
        nsView.updateMode()
    }
}
