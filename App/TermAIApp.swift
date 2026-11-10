import SwiftUI
import TermCore
import TermSSH
import UIKit

@main
struct TermAIApp: App {
    @State private var model = TermAIApp.makeModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }

    @MainActor
    private static func makeModel() -> AppModel {
        let files = FileManager.default
        let defaults = UserDefaults.standard
        let deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        let copy: (String) -> Void = { UIPasteboard.general.string = $0 }

        // Screenshot mode (`-demoScreen chat -theme dark`): sample content, nothing read from or written to real storage.
        if let screen = defaults.string(forKey: "demoScreen").flatMap(DemoScreen.init(rawValue:)) {
            let scratch = files.temporaryDirectory.appendingPathComponent("termai-demo-\(UUID().uuidString)")
            let workspace = scratch.appendingPathComponent("workspace")
            try? files.createDirectory(at: workspace, withIntermediateDirectories: true)
            let dependencies = AppDependencies(
                storage: Storage(directory: scratch.appendingPathComponent("support")), secrets: InMemorySecretStore(),
                workspace: workspace, deviceName: deviceName, copy: copy)
            return AppModel(dependencies: dependencies, demo: screen, theme: defaults.string(forKey: "theme"))
        }

        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TermAI")
        let workspace = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        try? files.createDirectory(at: workspace, withIntermediateDirectories: true)
        let dependencies = AppDependencies(
            storage: Storage(directory: support), secrets: KeychainStore(), workspace: workspace,
            connector: SSHConnector(), deviceName: deviceName, copy: copy)
        return AppModel(dependencies: dependencies)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// SwiftUI colours and fonts for the active theme.
struct Palette {
    let theme: Theme
    let size: Double

    var background: Color { Color(hex: theme.background) }
    var sidebar: Color { Color(hex: theme.sidebar) }
    var surface: Color { Color(hex: theme.surface) }
    var border: Color { Color(hex: theme.border) }
    var text: Color { Color(hex: theme.text) }
    var dim: Color { Color(hex: theme.dim) }
    var accent: Color { Color(hex: theme.accent) }
    var error: Color { Color(hex: theme.error) }
    var success: Color { Color(hex: theme.success) }
    var code: Color { Color(hex: theme.codeBackground) }

    private var design: Font.Design { theme.monospace ? .monospaced : .default }

    var body: Font { .system(size: size, design: design) }
    var bodyBold: Font { .system(size: size, weight: .semibold, design: design) }
    var small: Font { .system(size: max(size - 2, 10), design: design) }
    var smallBold: Font { .system(size: max(size - 2, 10), weight: .semibold, design: design) }
    var caption: Font { .system(size: max(size - 3, 10), design: design) }
    var mono: Font { .system(size: max(size - 2, 10), design: .monospaced) }
    var monoBody: Font { .system(size: size, design: .monospaced) }

    func heading(_ level: Int) -> Font {
        .system(size: size + (level == 1 ? 5 : level == 2 ? 3 : 1), weight: .bold, design: design)
    }
}

extension AppModel {
    var palette: Palette { Palette(theme: theme, size: settings.fontSize) }
}

extension PermissionMode {
    /// Short form for tight rows: the chips under the composer and the picker in Settings.
    var chipTitle: String {
        switch self {
        case .ask: return "Ask"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .bypass: return "Bypass"
        }
    }

    var symbol: String {
        switch self {
        case .ask: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .plan: return "map"
        case .bypass: return "bolt"
        }
    }
}
