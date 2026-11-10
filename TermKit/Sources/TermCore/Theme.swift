import Foundation

/// Colour palette as 0xRRGGBB values so the core stays UI-framework free.
public struct Theme: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isDark: Bool
    public var background: UInt32
    public var sidebar: UInt32
    /// Cards, the composer and user message bubbles.
    public var surface: UInt32
    public var border: UInt32
    public var text: UInt32
    public var dim: UInt32
    public var accent: UInt32
    public var error: UInt32
    public var success: UInt32
    public var codeBackground: UInt32
    /// Prose in a monospaced face, for the terminal-style themes.
    public var monospace: Bool
    /// Phosphor-style glow behind text.
    public var glow: Bool

    public static let dark = Theme(
        id: "dark", name: "Dark", isDark: true,
        background: 0x1F1E1D, sidebar: 0x181817, surface: 0x2C2B29, border: 0x3D3C39,
        text: 0xECEBE6, dim: 0x9C9A92, accent: 0xD97757, error: 0xE5676B, success: 0x7DBE8A,
        codeBackground: 0x161615, monospace: false, glow: false)

    public static let light = Theme(
        id: "light", name: "Light", isDark: false,
        background: 0xFAF9F5, sidebar: 0xF0EEE6, surface: 0xFFFFFF, border: 0xDEDCD1,
        text: 0x1F1E1D, dim: 0x73726C, accent: 0xC96442, error: 0xBF3B3B, success: 0x2F7D4F,
        codeBackground: 0xF0EEE6, monospace: false, glow: false)

    public static let terminal = Theme(
        id: "terminal", name: "Terminal", isDark: true,
        background: 0x0D0E11, sidebar: 0x090A0C, surface: 0x17191E, border: 0x2A2D35,
        text: 0xE4E4E7, dim: 0x7C7F88, accent: 0xD9825F, error: 0xF0717A, success: 0x7FD38B,
        codeBackground: 0x121419, monospace: true, glow: false)

    public static let crtGreen = Theme(
        id: "crt-green", name: "CRT Green", isDark: true,
        background: 0x020A04, sidebar: 0x010603, surface: 0x06180B, border: 0x124A22,
        text: 0x4AF07A, dim: 0x24914A, accent: 0xB6FFC8, error: 0xFF6B5E, success: 0x4AF07A,
        codeBackground: 0x04120A, monospace: true, glow: true)

    public static let crtAmber = Theme(
        id: "crt-amber", name: "CRT Amber", isDark: true,
        background: 0x0B0700, sidebar: 0x070400, surface: 0x1A1103, border: 0x4D3508,
        text: 0xFFB43C, dim: 0xA06A14, accent: 0xFFE2A8, error: 0xFF6B5E, success: 0xFFB43C,
        codeBackground: 0x130C02, monospace: true, glow: true)

    public static let all: [Theme] = [.dark, .light, .terminal, .crtGreen, .crtAmber]

    public static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .dark
    }
}
