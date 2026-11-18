import SwiftUI

/// Stable identifiers are persisted; every surface consumes the same palette.
/// Material and appearance are separate so a palette can use native glass
/// with either a fixed appearance or an adaptive light and dark variant.
public enum ProsodyTheme: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case graphite, pearl, midnight, aurora, fjord, tidal, pine, matcha
    case dune, terracotta, rosewater, plum, amethyst, copper, solar
    case linen
    case seaSalt = "sea-salt"
    case daybreak, celadon
    case lavenderMist = "lavender-mist"
    case apricot, hibiscus, cornflower, citron, opal
    case obsidian
    case blueHour = "blue-hour"
    case deepSea = "deep-sea"
    case lichen, redwood, espresso, mulberry, ultramarine, eclipse, verdigris
    case glass
    case clearGlass = "clear-glass"
    case amberGlass = "amber-glass"
    case irisGlass = "iris-glass"
    case roseGlass = "rose-glass"

    case smokedGlass = "smoked-glass"
    case seaGlass = "sea-glass"
    case cloud, chalk, canvas, slate, stone, fog
    case oledTrueBlack = "oled-true-black"
    case cobaltInk = "cobalt-ink"
    case navyInk = "navy-ink"
    case carbonCyan = "carbon-cyan"
    case inkViolet = "ink-violet"
    case deepNavy = "deep-navy"
    case royalInk = "royal-ink"
    case midnightCyan = "midnight-cyan"
    case inkPlum = "ink-plum"
    case coastalFog = "coastal-fog"
    case kelp, moss, fern, rainforest, glacier, harbor, lagoon, driftwood, evergreen
    case risographRed = "risograph-red"
    case blueprint, newsprint, letterpress, gouache, watercolor, vermilion, cerulean
    case magentaPress = "magenta-press"
    case neonNocturne = "neon-nocturne"
    case signalRed = "signal-red"
    case signalAmber = "signal-amber"
    case radarGreen = "radar-green"
    case ultraviolet, arcade
    case laserPink = "laser-pink"
    case nightwatch, beacon, starlight
    case basalt, granite, quartz, clay, ochre, umber, jade, sandstone
    case mossAgate = "moss-agate"

    public var id: String { rawValue }
    public var isAdaptive: Bool { ThemeCatalog.darkGlassPalettes[self] != nil }

    public func palette(for colorScheme: ColorScheme) -> ThemePalette {
        if colorScheme == .dark, let dark = ThemeCatalog.darkGlassPalettes[self] { return dark }
        return palette
    }

    var material: ThemeMaterial? {
        switch self {
        case .clearGlass: .clear
        case .glass, .smokedGlass, .seaGlass, .amberGlass, .irisGlass, .roseGlass: .tinted
        default: nil
        }
    }

    /// The fixed palette, or the light variant for a preview without an appearance context.
    public var palette: ThemePalette {
        ThemeCatalog.palette(for: self)
    }
}

enum ThemeMaterial {
    case clear
    case tinted
}

enum ThemeGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case systemGlass = "system-glass"
    case essentials
    case inkOLED = "ink-oled"
    case coastForest = "coast-forest"
    case studioPrint = "studio-print"
    case nightSignal = "night-signal"
    case mineralEarth = "mineral-earth"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemGlass: "System & Glass"
        case .essentials: "Essentials"
        case .inkOLED: "Ink & OLED"
        case .coastForest: "Coast & Forest"
        case .studioPrint: "Studio & Print"
        case .nightSignal: "Night & Signal"
        case .mineralEarth: "Mineral & Earth"
        }
    }
}

struct ThemeCatalogEntry: Sendable {
    let theme: ProsodyTheme
    let palette: ThemePalette
}

struct ThemeCatalogSection: Identifiable, Sendable {
    let group: ThemeGroup
    let entries: [ThemeCatalogEntry]

    var id: ThemeGroup { group }
}

/// The palette table is built once. Appearance renders projections of these
/// entries, so browsing does not allocate a second theme representation.
enum ThemeCatalog {
    static let sections: [ThemeCatalogSection] = [
        .init(group: .systemGlass, entries: [
            .init(theme: .glass, palette: .init("Frosted Glass", "Icy silver · follows system appearance", dark: false,
                colors: [0xEFF4FA, 0xDDE7F2, 0xF7FAFF, 0xE8EFF7, 0x1D466D, 0x2B5177, 0xFFFFFF, 0x202C3B, 0x354456])),
            .init(theme: .clearGlass, palette: .init("Clear Glass", "Neutral glass · follows system appearance", dark: false,
                colors: [0xECECEC, 0xDBDBDB, 0xFFFFFF, 0xE6E6E6, 0x353535, 0x4C4C4C, 0xFFFFFF, 0x1D1D1D, 0x464646])),
            .init(theme: .smokedGlass, palette: .init("Smoked Glass", "Charcoal glass with warm amber accents", dark: true,
                colors: [0x171B1F, 0x2D343B, 0x20262C, 0x171C21, 0xE7B36A, 0xB8D7E8, 0x21170A, 0xF5F7F8, 0xC3CDD4])),
            .init(theme: .seaGlass, palette: .init("Sea Glass", "Translucent aqua · soft teal controls", dark: false,
                colors: [0xEEF7F5, 0xCFE7E2, 0xF9FDFC, 0xE3F1EE, 0x1F655E, 0x2F7B8A, 0xFFFFFF, 0x173B38, 0x3E625E])),
            .init(theme: .amberGlass, palette: .init("Amber Glass", "Honey and bronze · follows system appearance", dark: false,
                colors: [0xFBF2DF, 0xF3D7A5, 0xFFF9EF, 0xF4E6CF, 0x79501D, 0x8A581C, 0xFFFFFF, 0x362817, 0x634B2D])),
            .init(theme: .irisGlass, palette: .init("Iris Glass", "Lavender and violet · follows system appearance", dark: false,
                colors: [0xF5EEFC, 0xDDD0F4, 0xFBF8FE, 0xECE3F7, 0x543D84, 0x674A97, 0xFFFFFF, 0x2F2440, 0x55436B])),
            .init(theme: .roseGlass, palette: .init("Rose Glass", "Blush and wine · follows system appearance", dark: false,
                colors: [0xFBEDF1, 0xF2CFDA, 0xFFF7FA, 0xF5E1E8, 0x793557, 0x903D68, 0xFFFFFF, 0x3B2431, 0x674053]))
        ]),
        .init(group: .essentials, entries: [
            .init(theme: .graphite, palette: .init("Graphite", "Brushed silver · sculpted charcoal", dark: true, pattern: .facets,
                colors: [0x17191D, 0x30353D, 0x292D33, 0x1D2026, 0xE1E6ED, 0xAEBCCC, 0x20242A, 0xF3F5F8, 0xBDC5CF])),
            .init(theme: .pearl, palette: .init("Pearl", "Porcelain · soft platinum · fine grain", dark: false, pattern: .paper,
                colors: [0xF7F6F2, 0xE0E6EA, 0xFCFCFA, 0xEDEEEB, 0x435668, 0x5F7485, 0xFFFFFF, 0x252E38, 0x53616D])),
            .init(theme: .linen, palette: .init("Linen", "Warm ivory · ink blue · woven lines", dark: false, pattern: .paper,
                colors: [0xF7F5EE, 0xE9E3D5, 0xFDFBF5, 0xF0EBE0, 0x385468, 0x515E6E, 0xFFFFFF, 0x2D3439, 0x515A5E])),
            .init(theme: .daybreak, palette: .init("Daybreak", "Morning blue · peach sky · sun rays", dark: false, pattern: .sunburst,
                colors: [0xECF3FC, 0xF2DBCB, 0xFDF7F1, 0xEDF0F5, 0x80482F, 0x705062, 0xFFFFFF, 0x3A343D, 0x60545D])),
            .init(theme: .cloud, palette: .init("Cloud", "Cool white · blue grey · quiet paper", dark: false, pattern: .paper,
                colors: [0xF4F7FA, 0xE1E8EF, 0xFBFDFE, 0xEAF0F5, 0x3D5A73, 0x55738C, 0xFFFFFF, 0x263746, 0x536675])),
            .init(theme: .chalk, palette: .init("Chalk", "Warm chalk · graphite · matte grain", dark: false, pattern: .paper,
                colors: [0xF8F7F2, 0xE7E3D8, 0xFDFCF8, 0xF1EFE7, 0x5A4A36, 0x7A664D, 0xFFFFFF, 0x302A22, 0x62594A])),
            .init(theme: .canvas, palette: .init("Canvas", "Raw linen · umber · woven texture", dark: false, pattern: .paper,
                colors: [0xF4EFE4, 0xE4D8C3, 0xFBF7EF, 0xEDE5D6, 0x7A4F2A, 0x8A633B, 0xFFFFFF, 0x3B2F23, 0x6A5843])),
            .init(theme: .slate, palette: .init("Slate", "Blue slate · silver · cut stone", dark: true, pattern: .facets,
                colors: [0x1A2026, 0x303A44, 0x242C34, 0x1D242B, 0x9CC7E8, 0xC5DDF0, 0x10202D, 0xF1F5F8, 0xC0CBD4])),
            .init(theme: .stone, palette: .init("Stone", "Warm stone · sand · layered grain", dark: true, pattern: .strata,
                colors: [0x24231F, 0x3B3932, 0x2D2B26, 0x27251F, 0xD8C49A, 0xB7C4C0, 0x241E12, 0xF4F0E7, 0xCBC4B5])),
            .init(theme: .fog, palette: .init("Fog", "Cool mist · blue grey · soft contours", dark: false, pattern: .contours,
                colors: [0xEDF1F2, 0xD7DFE1, 0xF8FAFA, 0xE4EAEB, 0x345966, 0x4D6F79, 0xFFFFFF, 0x263A40, 0x4C6066]))
        ]),
        .init(group: .inkOLED, entries: [
            .init(theme: .midnight, palette: .init("Midnight", "Ink blue · starlight · orbital paths", dark: true, pattern: .stars,
                colors: [0x10182D, 0x223B60, 0x1B2943, 0x121E34, 0xADCFFF, 0x7F9FDB, 0x152440, 0xEDF3FF, 0xB1C2DC])),
            .init(theme: .obsidian, palette: .init("Obsidian", "Carbon black · warm silver · fine facets", dark: true, pattern: .facets,
                colors: [0x111214, 0x25282C, 0x1F2124, 0x17191C, 0xEEE4D2, 0xBFC7D3, 0x201D19, 0xF5F3F0, 0xBBBFC7])),
            .init(theme: .blueHour, palette: .init("Blue Hour", "Steel blue · lavender · twilight contours", dark: true, pattern: .contours,
                colors: [0x1B2839, 0x3A405B, 0x29384D, 0x233045, 0xC5D4FF, 0xCABCE6, 0x1D263A, 0xF3F6FF, 0xC2CCDF])),
            .init(theme: .ultramarine, palette: .init("Ultramarine", "Deep cobalt · pale periwinkle · facets", dark: true, pattern: .crystal,
                colors: [0x191C43, 0x2D3973, 0x242C59, 0x1D234D, 0xC2C8FF, 0xA3CEF9, 0x20274A, 0xF2F3FF, 0xC2C9EA])),
            .init(theme: .eclipse, palette: .init("Eclipse", "Violet shadow · soft gold · orbital paths", dark: true, pattern: .stars,
                colors: [0x171721, 0x30283A, 0x252333, 0x1D1C2A, 0xF9DC8F, 0xE3BB78, 0x2D251A, 0xF8F3ED, 0xCDC1CB])),
            .init(theme: .oledTrueBlack, palette: .init("True Black OLED", "Pure black · electric cyan · high contrast", dark: true,
                colors: [0x000000, 0x000000, 0x000000, 0x000000, 0x7DF9FF, 0xB8FF6A, 0x001114, 0xFFFFFF, 0xD0D0D0])),
            .init(theme: .cobaltInk, palette: .init("Cobalt Ink", "Cobalt night · ice blue · crystalline lines", dark: true, pattern: .crystal,
                colors: [0x0C1530, 0x172A5A, 0x111D3C, 0x0E1835, 0x8DB9FF, 0x77E1F2, 0x081426, 0xF0F5FF, 0xB8C8E8])),
            .init(theme: .navyInk, palette: .init("Navy Ink", "Deep navy · aqua · quiet currents", dark: true, pattern: .waves,
                colors: [0x0A1826, 0x17334D, 0x102338, 0x0C1B2C, 0xA8D8FF, 0x7FE3D2, 0x061C2A, 0xEEF7FF, 0xB7CDDC])),
            .init(theme: .carbonCyan, palette: .init("Carbon Cyan", "Carbon grey · cyan · sharp facets", dark: true, pattern: .facets,
                colors: [0x111416, 0x202B2E, 0x171D1F, 0x131719, 0x69E6E0, 0x9AF3C6, 0x08211F, 0xF2F7F7, 0xBCC9C9])),
            .init(theme: .inkViolet, palette: .init("Ink Violet", "Dark violet ink · orchid · fine lattice", dark: true, pattern: .lattice,
                colors: [0x161126, 0x2C1F4A, 0x211936, 0x19132D, 0xCDB6FF, 0xF0A6DB, 0x1F1030, 0xF8F2FF, 0xC7BBD8])),
            .init(theme: .deepNavy, palette: .init("Deep Navy", "Midnight navy · amber · charted contours", dark: true, pattern: .contours,
                colors: [0x0B1420, 0x1A2F45, 0x122235, 0x0E1927, 0xE7C87A, 0x9FC8E8, 0x1F1606, 0xF4F6F8, 0xC0CCD6])),
            .init(theme: .royalInk, palette: .init("Royal Ink", "Royal indigo · gold · arched lines", dark: true, pattern: .arches,
                colors: [0x14102B, 0x2B2253, 0x1F1940, 0x17122F, 0xF2C36B, 0xE39BDD, 0x231604, 0xFAF6FF, 0xC9BFD9])),
            .init(theme: .midnightCyan, palette: .init("Midnight Cyan", "Midnight teal · cyan · star fields", dark: true, pattern: .stars,
                colors: [0x071A24, 0x12384A, 0x0C2531, 0x091D27, 0x71E8F5, 0xA7F5C7, 0x032027, 0xECFAFF, 0xB4D3DD])),
            .init(theme: .inkPlum, palette: .init("Ink Plum", "Ink plum · blush · pressed petals", dark: true, pattern: .petals,
                colors: [0x1B0F1E, 0x38203B, 0x27172A, 0x1E1121, 0xF2B6D9, 0xD4C3FF, 0x271020, 0xFBF2F8, 0xD1BDCC]))
        ]),
        .init(group: .coastForest, entries: [
            .init(theme: .fjord, palette: .init("Fjord", "Glacial slate · mist · mountain contours", dark: false, pattern: .contours,
                colors: [0xECF3F5, 0xCCDDE5, 0xF5F9FA, 0xDCE9ED, 0x285F76, 0x477D8A, 0xFFFFFF, 0x203C49, 0x455F6A])),
            .init(theme: .tidal, palette: .init("Tidal", "Deep ocean · sea glass · flowing water", dark: true, pattern: .waves,
                colors: [0x102C36, 0x194D58, 0x1C3C46, 0x14313C, 0x99E3EC, 0x7DCBB7, 0x173A40, 0xEAF8FA, 0xADD0D6])),
            .init(theme: .pine, palette: .init("Pine", "Forest shade · fern · botanical lines", dark: true, pattern: .sprigs,
                colors: [0x182B25, 0x324A32, 0x293D32, 0x1C3027, 0xC4DEA5, 0x91BF9D, 0x263A26, 0xF0F6E9, 0xC0CDB5])),
            .init(theme: .matcha, palette: .init("Matcha", "Sage paper · tea green · quiet terraces", dark: false, pattern: .terraces,
                colors: [0xF1F3E6, 0xD9E1C4, 0xFAFBF2, 0xE4EAD7, 0x486136, 0x6F7850, 0xFFFFFF, 0x303C28, 0x536147])),
            .init(theme: .seaSalt, palette: .init("Sea Salt", "Pale aqua · slate blue · gentle waves", dark: false, pattern: .waves,
                colors: [0xEFF8F8, 0xCCE8EA, 0xF9FCFC, 0xE2F0F2, 0x23576C, 0x2D6367, 0xFFFFFF, 0x233B44, 0x48616A])),
            .init(theme: .celadon, palette: .init("Celadon", "Glazed mint · eucalyptus · soft contours", dark: false, pattern: .contours,
                colors: [0xECF6EF, 0xCCE5D7, 0xF7FBF7, 0xDFEEE5, 0x275A49, 0x3C6253, 0xFFFFFF, 0x263D33, 0x4B6053])),
            .init(theme: .deepSea, palette: .init("Deep Sea", "Dark petrol blue · seafoam · currents", dark: true, pattern: .waves,
                colors: [0x0B2330, 0x123C4F, 0x15313F, 0x112835, 0x9CE3F8, 0x7ADBCF, 0x102F3A, 0xEBF8FF, 0xAFCCD8])),
            .init(theme: .lichen, palette: .init("Lichen", "Woodland olive · pale moss · sprigs", dark: true, pattern: .sprigs,
                colors: [0x22291B, 0x3A4428, 0x303925, 0x262E1F, 0xD2E59B, 0xB9CC91, 0x293119, 0xF3F6E8, 0xC2CCAE])),
            .init(theme: .verdigris, palette: .init("Verdigris", "Patinated teal · antique brass · lattice", dark: true, pattern: .lattice,
                colors: [0x172A2A, 0x2C4540, 0x233A37, 0x1C312D, 0xA9E2CB, 0xDBCB91, 0x20342D, 0xEBF7F2, 0xB9D1C6])),
            .init(theme: .coastalFog, palette: .init("Coastal Fog", "Sea mist · slate green · soft contours", dark: false, pattern: .contours,
                colors: [0xEEF3F2, 0xD4E1DF, 0xF8FBFA, 0xE4ECEA, 0x35665F, 0x4B7A76, 0xFFFFFF, 0x243B37, 0x485F5B])),
            .init(theme: .kelp, palette: .init("Kelp", "Dark kelp · lime · botanical lines", dark: true, pattern: .sprigs,
                colors: [0x12211B, 0x233B2C, 0x192C23, 0x14251D, 0xB8E38E, 0x88D6B2, 0x13220C, 0xF1F8EC, 0xBED1B7])),
            .init(theme: .moss, palette: .init("Moss", "Moss paper · olive · botanical lines", dark: false, pattern: .sprigs,
                colors: [0xEFF3E5, 0xD7E1C5, 0xF8FAF2, 0xE6ECDA, 0x4D642D, 0x637A43, 0xFFFFFF, 0x303B24, 0x53603F])),
            .init(theme: .fern, palette: .init("Fern", "Fern shade · spring green · fronds", dark: true, pattern: .sprigs,
                colors: [0x17251B, 0x2F4A2F, 0x203323, 0x19291D, 0xB9E7A2, 0x7FD4B4, 0x13220E, 0xF1F8EE, 0xBFD2B9])),
            .init(theme: .rainforest, palette: .init("Rainforest", "Rainforest · emerald · flowing ribbons", dark: true, pattern: .ribbons,
                colors: [0x0D241F, 0x1D4237, 0x143129, 0x102A23, 0x7FE2B4, 0xD0E98B, 0x072219, 0xECFAF3, 0xB4D8C8])),
            .init(theme: .glacier, palette: .init("Glacier", "Glacial blue · ice · crystalline lines", dark: false, pattern: .crystal,
                colors: [0xEDF6F8, 0xD3E7EC, 0xF8FCFD, 0xE3F0F3, 0x2D6072, 0x467A8C, 0xFFFFFF, 0x203D47, 0x4C6871])),
            .init(theme: .harbor, palette: .init("Harbor", "Harbor dusk · amber · rolling water", dark: true, pattern: .waves,
                colors: [0x12222A, 0x24424D, 0x1A3039, 0x152831, 0xE1B76F, 0x8BD7E2, 0x251805, 0xF4F8F8, 0xBFD0D3])),
            .init(theme: .lagoon, palette: .init("Lagoon", "Lagoon light · turquoise · gentle waves", dark: false, pattern: .waves,
                colors: [0xEAF7F5, 0xCBE9E4, 0xF7FCFB, 0xDFF1EE, 0x1E6B68, 0x347E7A, 0xFFFFFF, 0x183D3A, 0x3F6662])),
            .init(theme: .driftwood, palette: .init("Driftwood", "Driftwood · taupe · weathered grain", dark: false, pattern: .strata,
                colors: [0xF3F0E8, 0xDDD5C5, 0xFAF8F2, 0xEBE7DD, 0x6B5940, 0x7E6A4E, 0xFFFFFF, 0x393228, 0x655B49])),
            .init(theme: .evergreen, palette: .init("Evergreen", "Evergreen · brass · mountain contours", dark: true, pattern: .contours,
                colors: [0x0F201C, 0x1E3B31, 0x152B24, 0x11241E, 0xD4B86C, 0x8DD3AD, 0x201803, 0xF4F7F1, 0xC1D0C5]))
        ]),
        .init(group: .studioPrint, entries: [
            .init(theme: .rosewater, palette: .init("Rosewater", "Blush silk · mauve · pressed petals", dark: false, pattern: .petals,
                colors: [0xFAEFF2, 0xE7CEDA, 0xFFF6F8, 0xF0DFE7, 0x96466C, 0xA1608B, 0xFFFFFF, 0x4F3042, 0x714F64])),
            .init(theme: .amethyst, palette: .init("Amethyst", "Twilight lilac · crystalline geometry", dark: true, pattern: .crystal,
                colors: [0x221E3D, 0x453363, 0x342C4E, 0x292240, 0xD7C4FF, 0xA9BBF5, 0x30234B, 0xF5F1FF, 0xC9BFDF])),
            .init(theme: .solar, palette: .init("Solar", "Parchment · amber · radiating sunlines", dark: false, pattern: .sunburst,
                colors: [0xFCF4DB, 0xF0DEAD, 0xFFF9E9, 0xF3E7C6, 0x815E18, 0x8B691F, 0xFFFFFF, 0x483A20, 0x6F5A2F])),
            .init(theme: .lavenderMist, palette: .init("Lavender Mist", "Pale lilac · iris · curved terraces", dark: false, pattern: .terraces,
                colors: [0xF4F1FA, 0xDFD7F0, 0xFCF9FF, 0xEBE4F5, 0x573F82, 0x5D5384, 0xFFFFFF, 0x342B49, 0x594D6F])),
            .init(theme: .apricot, palette: .init("Apricot", "Peach cream · warm umber · rounded arches", dark: false, pattern: .arches,
                colors: [0xFFF2E6, 0xF6D9BC, 0xFFF9F1, 0xF9E5D1, 0x854820, 0x845637, 0xFFFFFF, 0x493027, 0x6B5042])),
            .init(theme: .hibiscus, palette: .init("Hibiscus", "Pink silk · raspberry · pressed petals", dark: false, pattern: .petals,
                colors: [0xFFF0F4, 0xF5D3DE, 0xFFF8FA, 0xFAE2EA, 0x8A3157, 0x854762, 0xFFFFFF, 0x492637, 0x6C4B5B])),
            .init(theme: .cornflower, palette: .init("Cornflower", "Periwinkle · indigo · crystalline lines", dark: false, pattern: .crystal,
                colors: [0xEDF1FF, 0xD1DDF7, 0xF8F9FF, 0xE2E8FC, 0x354E92, 0x46578D, 0xFFFFFF, 0x2A3754, 0x4F5B75])),
            .init(theme: .citron, palette: .init("Citron", "Lemon cream · olive · botanical lines", dark: false, pattern: .sprigs,
                colors: [0xF8F7DD, 0xE7E8AE, 0xFCFCEB, 0xEEF0CB, 0x515A22, 0x60652E, 0xFFFFFF, 0x363B26, 0x535B3A])),
            .init(theme: .opal, palette: .init("Opal", "Pale jade · violet · soft ribbons", dark: false, pattern: .ribbons,
                colors: [0xEEF8F6, 0xE8DFF2, 0xF9F9FF, 0xE5ECEE, 0x4D4277, 0x2C5D65, 0xFFFFFF, 0x303146, 0x56576D])),
            .init(theme: .risographRed, palette: .init("Risograph Red", "Warm paper · risograph red · ink grain", dark: false, pattern: .paper,
                colors: [0xFFF5EF, 0xF2D8CF, 0xFFFBF8, 0xF8E9E2, 0xA33D38, 0xB9564D, 0xFFFFFF, 0x472B27, 0x76544E])),
            .init(theme: .blueprint, palette: .init("Blueprint", "Blueprint blue · cyan · drafting grid", dark: true, pattern: .lattice,
                colors: [0x0B2A4A, 0x16466F, 0x10365B, 0x0D2F51, 0x9FD8FF, 0xEAD9A0, 0x07233B, 0xF1F8FF, 0xB7D1E4])),
            .init(theme: .newsprint, palette: .init("Newsprint", "Newsprint · charcoal · fine grain", dark: false, pattern: .paper,
                colors: [0xF2F0EA, 0xDCD8CE, 0xF9F7F2, 0xEAE7DF, 0x3F3A35, 0x5A5148, 0xFFFFFF, 0x292622, 0x5D574F])),
            .init(theme: .letterpress, palette: .init("Letterpress", "Cream stock · sepia ink · pressed paper", dark: false, pattern: .paper,
                colors: [0xF8F2E8, 0xE7D9C5, 0xFDF9F2, 0xF1E9DC, 0x6A3C2A, 0x8A5A3A, 0xFFFFFF, 0x3B2A20, 0x6A5544])),
            .init(theme: .gouache, palette: .init("Gouache", "Lilac paint · violet · soft arches", dark: false, pattern: .arches,
                colors: [0xF4F0FA, 0xE1D7F0, 0xFBF8FF, 0xEBE4F5, 0x63428D, 0x8A5A9A, 0xFFFFFF, 0x352A47, 0x655878])),
            .init(theme: .watercolor, palette: .init("Watercolor", "Watercolor blue · teal · washed ribbons", dark: false, pattern: .ribbons,
                colors: [0xEEF8FA, 0xD8EBF2, 0xF8FCFD, 0xE6F2F6, 0x2E627A, 0x4C7B8D, 0xFFFFFF, 0x253D49, 0x526B75])),
            .init(theme: .vermilion, palette: .init("Vermilion", "Burnt vermilion · peach · arched forms", dark: true, pattern: .arches,
                colors: [0x2A1310, 0x4A2119, 0x371A15, 0x2D1511, 0xFFB38E, 0xF2D08A, 0x2A1007, 0xFFF4EE, 0xE2C1B5])),
            .init(theme: .cerulean, palette: .init("Cerulean", "Cerulean · sky blue · crystalline lines", dark: false, pattern: .crystal,
                colors: [0xEDF6FC, 0xD3E6F2, 0xF8FCFF, 0xE4F0F8, 0x27658A, 0x3A7897, 0xFFFFFF, 0x203D4D, 0x48636F])),
            .init(theme: .magentaPress, palette: .init("Magenta Press", "Magenta ink · gold · pressed petals", dark: true, pattern: .petals,
                colors: [0x29101F, 0x4A1B38, 0x371626, 0x2D1222, 0xFF9BC8, 0xF6D48B, 0x2A0719, 0xFFF2F8, 0xE4B9CC]))
        ]),
        .init(group: .nightSignal, entries: [
            .init(theme: .aurora, palette: .init("Aurora", "Northern lights · teal · violet ribbons", dark: true, pattern: .ribbons,
                colors: [0x10232A, 0x30233F, 0x20333A, 0x182A32, 0x97EBD2, 0xBBA9ED, 0x142D29, 0xEBF9F5, 0xB0CFCB])),
            .init(theme: .plum, palette: .init("Plum", "Velvet aubergine · rose gold · fine lattice", dark: true, pattern: .lattice,
                colors: [0x281D30, 0x4A2C43, 0x3B2B41, 0x2C2034, 0xEAC2D8, 0xCCADD9, 0x3D263B, 0xFBF0F7, 0xD3B8CE])),
            .init(theme: .mulberry, palette: .init("Mulberry", "Blackberry · orchid · pressed petals", dark: true, pattern: .petals,
                colors: [0x351A34, 0x592A48, 0x47243E, 0x3B1F36, 0xFDC5E1, 0xEFB4E4, 0x402238, 0xFFF2F9, 0xDEC1D5])),
            .init(theme: .neonNocturne, palette: .init("Neon Nocturne", "Night violet · neon mint · starlight", dark: true, pattern: .stars,
                colors: [0x100B20, 0x25133F, 0x1A1230, 0x130D27, 0x65F5D5, 0xFF83C9, 0x081B18, 0xF8F2FF, 0xC8B9DD])),
            .init(theme: .signalRed, palette: .init("Signal Red", "Signal red · warm amber · sharp facets", dark: true, pattern: .facets,
                colors: [0x1C1011, 0x3A1B1D, 0x281619, 0x201214, 0xFF8B83, 0xFFD08A, 0x2A0907, 0xFFF4F2, 0xE0BDB9])),
            .init(theme: .signalAmber, palette: .init("Signal Amber", "Amber signal · burnt orange · sunburst", dark: true, pattern: .sunburst,
                colors: [0x1C170C, 0x3B3015, 0x2A2312, 0x211B0F, 0xFFD36A, 0xFFB36B, 0x2A1A00, 0xFFF8E8, 0xE1D0A8])),
            .init(theme: .radarGreen, palette: .init("Radar Green", "Radar green · lime · sweeping contours", dark: true, pattern: .contours,
                colors: [0x071A12, 0x0F3525, 0x0B2519, 0x081E15, 0x72F5A8, 0xC7F58A, 0x04210F, 0xECFFF3, 0xB5DCC3])),
            .init(theme: .ultraviolet, palette: .init("Ultraviolet", "Ultraviolet · electric cyan · crystal", dark: true, pattern: .crystal,
                colors: [0x160D2B, 0x301B58, 0x21163D, 0x190F31, 0xD8A5FF, 0x8FF0FF, 0x210D32, 0xF9F2FF, 0xCDBDE2])),
            .init(theme: .arcade, palette: .init("Arcade", "Arcade blue · pink · neon lattice", dark: true, pattern: .lattice,
                colors: [0x101626, 0x1D2D4B, 0x162039, 0x121A2E, 0xFF7EDB, 0x7BE7FF, 0x260A21, 0xF7F4FF, 0xC7C2DE])),
            .init(theme: .laserPink, palette: .init("Laser Pink", "Laser pink · ice blue · light ribbons", dark: true, pattern: .ribbons,
                colors: [0x21101B, 0x421C35, 0x301624, 0x27121F, 0xFF9FD1, 0xA8F0FF, 0x2B071A, 0xFFF3F9, 0xE1B9CD])),
            .init(theme: .nightwatch, palette: .init("Nightwatch", "Nightwatch blue · brass · star fields", dark: true, pattern: .stars,
                colors: [0x0D1721, 0x1C3141, 0x132433, 0x0F1B27, 0xD7B86D, 0x8FD4E8, 0x241A05, 0xF1F7FA, 0xBED0D7])),
            .init(theme: .beacon, palette: .init("Beacon", "Beacon brown · amber · radiating light", dark: true, pattern: .sunburst,
                colors: [0x1A1410, 0x35271A, 0x261D16, 0x1E1712, 0xFFC46B, 0xFFE7A3, 0x2A1800, 0xFFF8EE, 0xE0CDB4])),
            .init(theme: .starlight, palette: .init("Starlight", "Starlight · pale gold · blue stars", dark: true, pattern: .stars,
                colors: [0x11131D, 0x252A3D, 0x1A1E2C, 0x141722, 0xE8D7A0, 0xA9C7FF, 0x211B08, 0xF8F8FF, 0xCDD0DF]))
        ]),
        .init(group: .mineralEarth, entries: [
            .init(theme: .dune, palette: .init("Dune", "Warm linen · sandstone · wind-carved arcs", dark: false, pattern: .dunes,
                colors: [0xF7F0E2, 0xE5D3B6, 0xFCF7EC, 0xEEE3CD, 0x805B35, 0x89683F, 0xFFFFFF, 0x433526, 0x695640])),
            .init(theme: .terracotta, palette: .init("Terracotta", "Fired clay · apricot · architectural arches", dark: false, pattern: .arches,
                colors: [0xFAEEE5, 0xEACABA, 0xFFF5EE, 0xF0DBCD, 0x9A4835, 0xA65B42, 0xFFFFFF, 0x4F302B, 0x744E42])),
            .init(theme: .copper, palette: .init("Copper", "Smoked walnut · burnished metal · strata", dark: true, pattern: .strata,
                colors: [0x2C221F, 0x4C352B, 0x3C2F29, 0x30241F, 0xF0C09A, 0xD1A989, 0x402B1F, 0xFBF1E7, 0xD5BFB0])),
            .init(theme: .redwood, palette: .init("Redwood", "Mahogany · muted coral · layered grain", dark: true, pattern: .strata,
                colors: [0x321F21, 0x4D2D31, 0x412B2E, 0x372326, 0xFFC3B0, 0xE9ABA6, 0x442323, 0xFFF0EB, 0xDFC0B8])),
            .init(theme: .espresso, palette: .init("Espresso", "Roast brown · oat cream · fine grain", dark: true, pattern: .paper,
                colors: [0x201713, 0x372B24, 0x2E231D, 0x271D18, 0xF3D6AB, 0xDCC2A6, 0x33251B, 0xFBF4EB, 0xD1C2B6])),
            .init(theme: .basalt, palette: .init("Basalt", "Basalt grey · ochre · fractured facets", dark: true, pattern: .facets,
                colors: [0x141719, 0x2A3034, 0x1D2225, 0x171B1D, 0xE0B36A, 0x9CC5C2, 0x241704, 0xF3F5F5, 0xC3CBCB])),
            .init(theme: .granite, palette: .init("Granite", "Granite · graphite · fine strata", dark: false, pattern: .strata,
                colors: [0xF0F0ED, 0xD9D9D3, 0xF9F9F6, 0xE7E7E2, 0x555B5E, 0x6D7476, 0xFFFFFF, 0x2D3133, 0x565C5E])),
            .init(theme: .quartz, palette: .init("Quartz", "Quartz pink · mauve · crystalline lines", dark: false, pattern: .crystal,
                colors: [0xF8F3F7, 0xE7D9E6, 0xFDF9FC, 0xF1E8F0, 0x704A72, 0x8A5D82, 0xFFFFFF, 0x3D2D3F, 0x6B586D])),
            .init(theme: .clay, palette: .init("Clay", "Terracotta clay · warm cream · arches", dark: false, pattern: .arches,
                colors: [0xF8EEE7, 0xE7D1C1, 0xFDF7F2, 0xF1E3D8, 0x854C32, 0x9B6548, 0xFFFFFF, 0x472F24, 0x6C5040])),
            .init(theme: .ochre, palette: .init("Ochre", "Ochre · sand · wind-carved dunes", dark: false, pattern: .dunes,
                colors: [0xF8F1DD, 0xE7D7AE, 0xFDF9EC, 0xF2E9D1, 0x74561A, 0x8A6A28, 0xFFFFFF, 0x44381F, 0x645531])),
            .init(theme: .umber, palette: .init("Umber", "Umber · copper · layered grain", dark: true, pattern: .strata,
                colors: [0x241813, 0x432B21, 0x31221B, 0x281B16, 0xE7B889, 0xC9D4A4, 0x261507, 0xFBF3ED, 0xD6C1B3])),
            .init(theme: .jade, palette: .init("Jade", "Jade · eucalyptus · quiet terraces", dark: false, pattern: .terraces,
                colors: [0xEDF7F2, 0xD2E8DD, 0xF8FCFA, 0xE3F1EA, 0x2C6854, 0x477C68, 0xFFFFFF, 0x223D33, 0x4F6B5F])),
            .init(theme: .sandstone, palette: .init("Sandstone", "Sandstone · umber · wind-carved dunes", dark: false, pattern: .dunes,
                colors: [0xF8F1E7, 0xE6D5BF, 0xFDF8F1, 0xF1E7D9, 0x7B5634, 0x906A45, 0xFFFFFF, 0x443426, 0x68543F])),
            .init(theme: .mossAgate, palette: .init("Moss Agate", "Moss agate · sage · layered terraces", dark: true, pattern: .terraces,
                colors: [0x18221D, 0x2E4033, 0x223129, 0x223129, 0xC9D98F, 0x9BD8C0, 0x1D2308, 0xF5F8ED, 0xC8D3C0]))
        ])
    ]

    static let entries: [ThemeCatalogEntry] = sections.flatMap(\.entries)
    static let palettes: [ProsodyTheme: ThemePalette] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.theme, $0.palette) }
    )
    static let darkGlassPalettes: [ProsodyTheme: ThemePalette] = [
        .glass: .init("Frosted Glass", "Icy silver · follows system appearance", dark: true,
            colors: [0x101720, 0x1A2430, 0x222D3B, 0x1A2330, 0xD9ECFF, 0xC0DCFA, 0x142233, 0xF7FBFF, 0xE4EBF3]),
        .clearGlass: .init("Clear Glass", "Neutral glass · follows system appearance", dark: true,
            colors: [0x171717, 0x272727, 0x303030, 0x202020, 0xF5F5F5, 0xC8C8C8, 0x242424, 0xF8F8F8, 0xCCCCCC]),
        .amberGlass: .init("Amber Glass", "Honey and bronze · follows system appearance", dark: true,
            colors: [0x2B2116, 0x512F17, 0x39291B, 0x302116, 0xFFE0A9, 0xF7BC69, 0x37210F, 0xFFF5E6, 0xE1C9A6]),
        .irisGlass: .init("Iris Glass", "Lavender and violet · follows system appearance", dark: true,
            colors: [0x211A32, 0x382854, 0x322543, 0x291E3B, 0xEADDFF, 0xC6AAF6, 0x2A1D42, 0xFAF3FF, 0xD1BDE9]),
        .roseGlass: .init("Rose Glass", "Blush and wine · follows system appearance", dark: true,
            colors: [0x2C1C28, 0x4B233A, 0x392433, 0x301F2C, 0xFFD8E9, 0xEDAECF, 0x3B1B2B, 0xFFF3F8, 0xE4BED0])
    ]

    static func palette(for theme: ProsodyTheme) -> ThemePalette {
        guard let palette = palettes[theme] else {
            preconditionFailure("Missing palette for theme \(theme.rawValue)")
        }
        return palette
    }
}

public struct ThemePalette: Equatable, Sendable {
    public let name: String
    public let detail: String
    public let dark: Bool
    let pattern: ThemePattern?
    /// Background, gradient end, surface, sidebar, accent, accent end,
    /// on-accent, text, secondary. Kept as sRGB for contrast validation.
    public let colors: [UInt32]
    init(_ name: String, _ detail: String, dark: Bool, pattern: ThemePattern? = nil, colors: [UInt32]) {
        self.name = name; self.detail = detail; self.dark = dark; self.pattern = pattern; self.colors = colors
    }
    var background: Color { Color(themeHex: colors[0]) }
    var backgroundEnd: Color { Color(themeHex: colors[1]) }
    var surface: Color { Color(themeHex: colors[2]) }
    var sidebar: Color { Color(themeHex: colors[3]) }
    var accent: Color { Color(themeHex: colors[4]) }
    var accentEnd: Color { Color(themeHex: colors[5]) }
    var onAccent: Color { Color(themeHex: colors[6]) }
    var text: Color { Color(themeHex: colors[7]) }
    var secondary: Color { Color(themeHex: colors[8]) }
    var border: Color { secondary.opacity(dark ? 0.24 : 0.22) }
    var accentGradient: LinearGradient { .init(colors: [accent, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing) }
}

enum ThemePattern: Int, Sendable {
    case facets, paper, stars, ribbons, contours, waves, sprigs, terraces
    case dunes, arches, petals, lattice, crystal, strata, sunburst
}

extension Color {
    init(themeHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ProsodyTheme.graphite.palette
}

extension EnvironmentValues {
    var prosodyPalette: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}
