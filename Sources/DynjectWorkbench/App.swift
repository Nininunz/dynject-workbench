import AppKit
import DynjectCore
import SwiftUI

@main
struct DynjectWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = WorkbenchModel(env: AppEnvironment.current())

    var body: some Scene {
        Window("Dynject Workbench", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    delegate.model = model
                    model.start()
                    if let dir = model.env.smokeTestReportDirectory {
                        await SmokeTest(model: model, reportDirectory: dir).run()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Dynject Workbench") {
                    let credits = NSAttributedString(
                        string: "\(WorkbenchInfo.licenseNotice)\n\n\(WorkbenchInfo.engineCredit)",
                        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                     .foregroundColor: NSColor.labelColor])
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkbenchModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// An open install review's unpacked package goes with the app.
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.installReview = nil
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.env.smokeTestReportDirectory == nil,
              model.hasUnsavedConfig || model.plistIsDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit with unsaved changes?"
        alert.informativeText = "Unsaved config or plist edits will be lost. Nothing has been written to disk."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
