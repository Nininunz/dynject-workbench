// The SwiftUI part of the Inspector test host: a few shapes and a Liquid Glass capsule in an NSHostingView, so the
// picker has a SwiftUI layer tree to walk. Called from TestHost.m through ITMakeSwiftUIView().
import AppKit
import SwiftUI

struct ITSwiftUIContent: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.indigo.opacity(0.85))
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Circle().fill(Color.orange).frame(width: 36, height: 36)
                    Capsule().fill(Color.mint).frame(width: 70, height: 24)
                }
                Text("SwiftUI glass")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(10)
    }
}

@_cdecl("ITMakeSwiftUIView")
public func ITMakeSwiftUIView() -> NSView {
    let host = NSHostingView(rootView: ITSwiftUIContent())
    host.wantsLayer = true
    return host
}
