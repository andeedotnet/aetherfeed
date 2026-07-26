import AppKit
import SwiftUI

extension Color {
    /// Creates a color from a "#RRGGBB" hex string; nil for empty/invalid input.
    init?(hex: String?) {
        guard var string = hex?.trimmingCharacters(in: .whitespaces), !string.isEmpty else {
            return nil
        }
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self = Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Serializes to "#RRGGBB" in the sRGB space; nil if the color can't be resolved.
    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
