#if canImport(Testing)
import Foundation
import SwiftUI
import Testing
@testable import ProsodyCore

@Suite("Theme contrast")
struct ThemeContrastTests {
    private static let legacyIDs: Set<String> = [
        "graphite", "pearl", "midnight", "aurora", "fjord", "tidal", "pine", "matcha",
        "dune", "terracotta", "rosewater", "plum", "amethyst", "copper", "solar",
        "linen", "sea-salt", "daybreak", "celadon", "lavender-mist", "apricot",
        "hibiscus", "cornflower", "citron", "opal", "obsidian", "blue-hour", "deep-sea",
        "lichen", "redwood", "espresso", "mulberry", "ultramarine", "eclipse",
        "verdigris", "glass"
    ]

    private static let newIDs: Set<String> = [
        "smoked-glass", "sea-glass", "clear-glass", "amber-glass", "iris-glass", "rose-glass",
        "cloud", "chalk", "canvas", "slate", "stone", "fog",
        "oled-true-black", "cobalt-ink", "navy-ink", "carbon-cyan", "ink-violet",
        "deep-navy", "royal-ink", "midnight-cyan", "ink-plum", "coastal-fog", "kelp",
        "moss", "fern", "rainforest", "glacier", "harbor", "lagoon", "driftwood",
        "evergreen", "risograph-red", "blueprint", "newsprint", "letterpress", "gouache",
        "watercolor", "vermilion", "cerulean", "magenta-press", "neon-nocturne",
        "signal-red", "signal-amber", "radar-green", "ultraviolet", "arcade", "laser-pink",
        "nightwatch", "beacon", "starlight", "basalt", "granite", "quartz", "clay",
        "ochre", "umber", "jade", "sandstone", "moss-agate"
    ]

    /// Snapshot of the Alpha 8 palette table. These IDs and tokens are persisted
    /// or consumed by existing surfaces and must not drift during catalog growth.
    private static let legacyPalettes: [String: [UInt32]] = [
        "graphite": [0x17191D, 0x30353D, 0x292D33, 0x1D2026, 0xE1E6ED, 0xAEBCCC, 0x20242A, 0xF3F5F8, 0xBDC5CF],
        "pearl": [0xF7F6F2, 0xE0E6EA, 0xFCFCFA, 0xEDEEEB, 0x435668, 0x5F7485, 0xFFFFFF, 0x252E38, 0x53616D],
        "midnight": [0x10182D, 0x223B60, 0x1B2943, 0x121E34, 0xADCFFF, 0x7F9FDB, 0x152440, 0xEDF3FF, 0xB1C2DC],
        "aurora": [0x10232A, 0x30233F, 0x20333A, 0x182A32, 0x97EBD2, 0xBBA9ED, 0x142D29, 0xEBF9F5, 0xB0CFCB],
        "fjord": [0xECF3F5, 0xCCDDE5, 0xF5F9FA, 0xDCE9ED, 0x285F76, 0x477D8A, 0xFFFFFF, 0x203C49, 0x455F6A],
        "tidal": [0x102C36, 0x194D58, 0x1C3C46, 0x14313C, 0x99E3EC, 0x7DCBB7, 0x173A40, 0xEAF8FA, 0xADD0D6],
        "pine": [0x182B25, 0x324A32, 0x293D32, 0x1C3027, 0xC4DEA5, 0x91BF9D, 0x263A26, 0xF0F6E9, 0xC0CDB5],
        "matcha": [0xF1F3E6, 0xD9E1C4, 0xFAFBF2, 0xE4EAD7, 0x486136, 0x6F7850, 0xFFFFFF, 0x303C28, 0x536147],
        "dune": [0xF7F0E2, 0xE5D3B6, 0xFCF7EC, 0xEEE3CD, 0x805B35, 0x89683F, 0xFFFFFF, 0x433526, 0x695640],
        "terracotta": [0xFAEEE5, 0xEACABA, 0xFFF5EE, 0xF0DBCD, 0x9A4835, 0xA65B42, 0xFFFFFF, 0x4F302B, 0x744E42],
        "rosewater": [0xFAEFF2, 0xE7CEDA, 0xFFF6F8, 0xF0DFE7, 0x96466C, 0xA1608B, 0xFFFFFF, 0x4F3042, 0x714F64],
        "plum": [0x281D30, 0x4A2C43, 0x3B2B41, 0x2C2034, 0xEAC2D8, 0xCCADD9, 0x3D263B, 0xFBF0F7, 0xD3B8CE],
        "amethyst": [0x221E3D, 0x453363, 0x342C4E, 0x292240, 0xD7C4FF, 0xA9BBF5, 0x30234B, 0xF5F1FF, 0xC9BFDF],
        "copper": [0x2C221F, 0x4C352B, 0x3C2F29, 0x30241F, 0xF0C09A, 0xD1A989, 0x402B1F, 0xFBF1E7, 0xD5BFB0],
        "solar": [0xFCF4DB, 0xF0DEAD, 0xFFF9E9, 0xF3E7C6, 0x815E18, 0x8B691F, 0xFFFFFF, 0x483A20, 0x6F5A2F],
        "linen": [0xF7F5EE, 0xE9E3D5, 0xFDFBF5, 0xF0EBE0, 0x385468, 0x515E6E, 0xFFFFFF, 0x2D3439, 0x515A5E],
        "sea-salt": [0xEFF8F8, 0xCCE8EA, 0xF9FCFC, 0xE2F0F2, 0x23576C, 0x2D6367, 0xFFFFFF, 0x233B44, 0x48616A],
        "daybreak": [0xECF3FC, 0xF2DBCB, 0xFDF7F1, 0xEDF0F5, 0x80482F, 0x705062, 0xFFFFFF, 0x3A343D, 0x60545D],
        "celadon": [0xECF6EF, 0xCCE5D7, 0xF7FBF7, 0xDFEEE5, 0x275A49, 0x3C6253, 0xFFFFFF, 0x263D33, 0x4B6053],
        "lavender-mist": [0xF4F1FA, 0xDFD7F0, 0xFCF9FF, 0xEBE4F5, 0x573F82, 0x5D5384, 0xFFFFFF, 0x342B49, 0x594D6F],
        "apricot": [0xFFF2E6, 0xF6D9BC, 0xFFF9F1, 0xF9E5D1, 0x854820, 0x845637, 0xFFFFFF, 0x493027, 0x6B5042],
        "hibiscus": [0xFFF0F4, 0xF5D3DE, 0xFFF8FA, 0xFAE2EA, 0x8A3157, 0x854762, 0xFFFFFF, 0x492637, 0x6C4B5B],
        "cornflower": [0xEDF1FF, 0xD1DDF7, 0xF8F9FF, 0xE2E8FC, 0x354E92, 0x46578D, 0xFFFFFF, 0x2A3754, 0x4F5B75],
        "citron": [0xF8F7DD, 0xE7E8AE, 0xFCFCEB, 0xEEF0CB, 0x515A22, 0x60652E, 0xFFFFFF, 0x363B26, 0x535B3A],
        "opal": [0xEEF8F6, 0xE8DFF2, 0xF9F9FF, 0xE5ECEE, 0x4D4277, 0x2C5D65, 0xFFFFFF, 0x303146, 0x56576D],
        "obsidian": [0x111214, 0x25282C, 0x1F2124, 0x17191C, 0xEEE4D2, 0xBFC7D3, 0x201D19, 0xF5F3F0, 0xBBBFC7],
        "blue-hour": [0x1B2839, 0x3A405B, 0x29384D, 0x233045, 0xC5D4FF, 0xCABCE6, 0x1D263A, 0xF3F6FF, 0xC2CCDF],
        "deep-sea": [0x0B2330, 0x123C4F, 0x15313F, 0x112835, 0x9CE3F8, 0x7ADBCF, 0x102F3A, 0xEBF8FF, 0xAFCCD8],
        "lichen": [0x22291B, 0x3A4428, 0x303925, 0x262E1F, 0xD2E59B, 0xB9CC91, 0x293119, 0xF3F6E8, 0xC2CCAE],
        "redwood": [0x321F21, 0x4D2D31, 0x412B2E, 0x372326, 0xFFC3B0, 0xE9ABA6, 0x442323, 0xFFF0EB, 0xDFC0B8],
        "espresso": [0x201713, 0x372B24, 0x2E231D, 0x271D18, 0xF3D6AB, 0xDCC2A6, 0x33251B, 0xFBF4EB, 0xD1C2B6],
        "mulberry": [0x351A34, 0x592A48, 0x47243E, 0x3B1F36, 0xFDC5E1, 0xEFB4E4, 0x402238, 0xFFF2F9, 0xDEC1D5],
        "ultramarine": [0x191C43, 0x2D3973, 0x242C59, 0x1D234D, 0xC2C8FF, 0xA3CEF9, 0x20274A, 0xF2F3FF, 0xC2C9EA],
        "eclipse": [0x171721, 0x30283A, 0x252333, 0x1D1C2A, 0xF9DC8F, 0xE3BB78, 0x2D251A, 0xF8F3ED, 0xCDC1CB],
        "verdigris": [0x172A2A, 0x2C4540, 0x233A37, 0x1C312D, 0xA9E2CB, 0xDBCB91, 0x20342D, 0xEBF7F2, 0xB9D1C6],
        "glass": [0xEFF4FA, 0xDDE7F2, 0xF7FAFF, 0xE8EFF7, 0x1D466D, 0x2B5177, 0xFFFFFF, 0x202C3B, 0x354456]
    ]

    private static let glassDarkColors: [UInt32] = [
        0x101720, 0x1A2430, 0x222D3B, 0x1A2330, 0xD9ECFF, 0xC0DCFA, 0x142233, 0xF7FBFF, 0xE4EBF3
    ]

    private static let expectedGroupCounts = [7, 10, 14, 19, 18, 13, 14]
    private static let backgrounds = Array(0..<4)
    private static let foregrounds = [7, 8]
    private static let accents = [4, 5]
    private static let onAccent = 6

    private static let newThemes = ProsodyTheme.allCases.filter { !legacyIDs.contains($0.id) }

    @Test("persisted identifiers, uniqueness, and adaptive palettes are stable")
    func identifiersAndAdaptivePalettes() {
        let themes = ProsodyTheme.allCases
        #expect(themes.count == 95)
        #expect(Set(themes.map(\.id)) == Self.legacyIDs.union(Self.newIDs))
        #expect(Self.newThemes.count == 59)
        #expect(Set(Self.newThemes.map(\.id)) == Self.newIDs)
        #expect(Set(Self.newThemes.map(\.palette.colors)).count == Self.newThemes.count)
        #expect(Set(Self.newThemes.map(\.palette.name)).count == Self.newThemes.count)
        #expect(themes.filter { $0.isAdaptive } == [.glass, .clearGlass, .amberGlass, .irisGlass, .roseGlass])

        for theme in themes {
            let light = theme.palette(for: .light)
            let dark = theme.palette(for: .dark)
            #expect(light.colors.count == 9)
            #expect(dark.colors.count == 9)
            #expect(!light.name.isEmpty)
            #expect(!light.detail.isEmpty)

            if theme.isAdaptive {
                #expect(!light.dark)
                #expect(dark.dark)
                #expect(light.colors != dark.colors)
            } else {
                #expect(light == theme.palette)
                #expect(dark == theme.palette)
            }
        }
    }

    @Test("legacy IDs and palette tokens remain unchanged")
    func legacyPaletteTokens() {
        #expect(Self.legacyPalettes.count == Self.legacyIDs.count)
        #expect(Set(Self.legacyPalettes.keys) == Self.legacyIDs)

        for theme in ProsodyTheme.allCases where Self.legacyIDs.contains(theme.id) {
            #expect(theme.palette.colors == Self.legacyPalettes[theme.id] ?? [])
        }
        #expect(ProsodyTheme.glass.palette(for: .dark).colors == Self.glassDarkColors)
    }

    @Test("catalog taxonomy covers every theme exactly once")
    func catalogTaxonomy() {
        #expect(ThemeCatalog.sections.map(\.group) == ThemeGroup.allCases)
        #expect(ThemeCatalog.sections.map(\.entries.count) == Self.expectedGroupCounts)
        #expect(ThemeCatalog.entries.count == ProsodyTheme.allCases.count)
        #expect(ThemeCatalog.palettes.count == ProsodyTheme.allCases.count)
        #expect(Set(ThemeCatalog.entries.map(\.theme)) == Set(ProsodyTheme.allCases))
        #expect(Set(ThemeCatalog.entries.map(\.theme)).count == ThemeCatalog.entries.count)
        #expect(Set(ThemeCatalog.entries.map(\.palette.name)).count == ThemeCatalog.entries.count)
        #expect(ThemeGroup.allCases.map(\.title) == [
            "System & Glass", "Essentials", "Ink & OLED", "Coast & Forest",
            "Studio & Print", "Night & Signal", "Mineral & Earth"
        ])
    }

    @Test(arguments: ProsodyTheme.allCases.filter { !$0.isAdaptive })
    func fixedThemeContrast(theme: ProsodyTheme) {
        assertOpaqueContrast(theme.palette, context: theme.rawValue)
    }

    @Test("every new palette meets opaque contrast")
    func newThemeContrast() {
        for theme in Self.newThemes {
            assertOpaqueContrast(theme.palette, context: theme.rawValue)
        }
    }

    @Test("True Black OLED is pattern-free and uses opaque black surfaces")
    func trueBlackOLED() {
        let palette = ProsodyTheme.oledTrueBlack.palette
        #expect(palette.pattern == nil)
        #expect(palette.colors[0..<4].allSatisfy { $0 == 0x000000 })
        #expect(!ProsodyTheme.oledTrueBlack.isAdaptive)
        #expect(ProsodyTheme.oledTrueBlack.palette(for: .light) == palette)
        #expect(ProsodyTheme.oledTrueBlack.palette(for: .dark) == palette)
        assertOpaqueContrast(palette, context: "oled-true-black")
    }

    @Test(arguments: ProsodyTheme.allCases.filter { $0.material != nil }, [ColorScheme.light, .dark])
    func glassOpaqueFallbackContrast(theme: ProsodyTheme, scheme: ColorScheme) {
        let palette = theme.palette(for: scheme)
        assertOpaqueContrast(palette, context: "\(theme.id)-\(scheme)")
        if theme == .clearGlass {
            #expect(theme.material == .clear)
            let isGrayscale = palette.colors.allSatisfy { hex in
                let red = (hex >> 16) & 0xff
                let green = (hex >> 8) & 0xff
                let blue = hex & 0xff
                return red == green && green == blue
            }
            #expect(isGrayscale)
        }
    }

    private func assertOpaqueContrast(_ palette: ThemePalette, context: String) {
        let colors = palette.colors
        for backgroundIndex in Self.backgrounds {
            for foregroundIndex in Self.foregrounds {
                #expect(
                    Self.contrast(colors[foregroundIndex], colors[backgroundIndex]) >= 4.5,
                    "\(context): low text contrast for fg \(foregroundIndex) on bg \(backgroundIndex)"
                )
            }
        }
        for accentIndex in Self.accents {
            #expect(
                Self.contrast(colors[Self.onAccent], colors[accentIndex]) >= 4.5,
                "\(context): low on-accent contrast for accent \(accentIndex)"
            )
        }
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(
            Double((hex >> 16) & 0xFF),
            Double((hex >> 8) & 0xFF),
            Double(hex & 0xFF)
        ) / 255
    }

    private static func luminance(_ rgb: SIMD3<Double>) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.x) + 0.7152 * linear(rgb.y) + 0.0722 * linear(rgb.z)
    }

    private static func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        contrast(luminance(rgb(first)), luminance(rgb(second)))
    }
}
#endif
