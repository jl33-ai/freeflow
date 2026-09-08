import AppKit
import SwiftUI

@main
struct FreeFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            DenMenuBarView()
                .environmentObject(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.appState)
        }
    }
}

@MainActor
struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    private static let logo: NSImage = {
        let image = NSImage(contentsOf: Bundle.main.url(forResource: "DenMenu", withExtension: "png")!)!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: Self.logo).renderingMode(.template)
            if appState.isRecording { Image(systemName: "record.circle.fill") }
            else if appState.isTranscribing { Image(systemName: "ellipsis") }
        }.help("Git for Work (Den)")
    }
}
