import SwiftUI

/// Fixed artwork has no time-dependent state. Only window and popover roots
/// opt in to translucency; other uses get the opaque palette.
struct ThemeBackground: View {
    let palette: ThemePalette
    var isAdaptive = false
    var backdrop: ThemeBackdrop = .opaque
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if isAdaptive, !reduceTransparency, backdrop != .opaque {
                ZStack {
                    if backdrop == .window { ThemeWindowMaterial() }
                    palette.backdropGradient(opacity: palette.glassTintOpacity)
                }
            } else {
                opaqueBackground
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var opaqueBackground: some View {
        ZStack {
            palette.backdropGradient()
            if !reduceTransparency, let pattern = palette.pattern {
                RadialGradient(colors: [palette.accent.opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 650)
                Canvas { context, size in
                    var path = Path()
                    let w = size.width, h = size.height
                    func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
                        path.move(to: CGPoint(x: x1 * w, y: y1 * h))
                        path.addLine(to: CGPoint(x: x2 * w, y: y2 * h))
                    }
                    switch pattern {
                    case .facets, .crystal:
                        let count = pattern == .crystal ? 12 : 6
                        for i in 0..<count {
                            let t = Double(i) / Double(count)
                            line(t - 0.3, 1, 0.78, -0.2)
                            line(0.78, -0.2, 1.25, t + 0.2)
                            if pattern == .crystal { line(t, 0.8, 1, t * 0.4) }
                        }
                    case .paper:
                        for i in 0..<32 { line(0, Double(i) / 31, 1, Double(i) / 31) }
                        for i in 0..<24 { line(Double(i) / 23, 0, Double(i) / 23, 1) }
                    case .stars:
                        for i in 0..<42 {
                            let x = Double((i * 73 + 17) % 997) / 997 * w
                            let y = Double((i * 139 + 41) % 991) / 991 * h
                            path.addEllipse(in: CGRect(x: x, y: y, width: i % 4 == 0 ? 3 : 1.5, height: i % 4 == 0 ? 3 : 1.5))
                        }
                        path.addEllipse(in: CGRect(x: w * 0.4, y: -h * 0.55, width: w, height: h * 1.25))
                    case .ribbons, .waves, .dunes, .strata:
                        for i in 0..<12 {
                            let t = Double(i) * 0.065
                            path.move(to: CGPoint(x: -w * 0.1, y: h * (0.25 + t)))
                            let rise: Double = pattern == .ribbons ? -0.45 : pattern == .dunes ? 0.7 : 0.1
                            path.addCurve(to: CGPoint(x: w * 1.1, y: h * (0.6 + t)),
                                control1: CGPoint(x: w * 0.3, y: h * (rise + t)),
                                control2: CGPoint(x: w * 0.62, y: h * (0.9 + t)))
                        }
                    case .contours, .terraces:
                        for i in 0..<13 {
                            let inset = Double(i) * 24
                            let rect = CGRect(x: w * 0.55 - inset, y: -h * 0.45 - inset, width: w * 0.8 + inset * 2, height: h + inset * 2)
                            if pattern == .contours { path.addEllipse(in: rect) }
                            else { path.addRoundedRect(in: rect, cornerSize: CGSize(width: 85, height: 85)) }
                        }
                    case .sprigs:
                        for j in 0..<3 {
                            let x = w * (0.68 + Double(j) * 0.13)
                            path.move(to: CGPoint(x: x, y: h * 1.1))
                            path.addQuadCurve(to: CGPoint(x: x + 35, y: -30), control: CGPoint(x: x - 65, y: h * 0.4))
                            for i in 0..<10 {
                                let y = Double(i) / 10 * h
                                path.move(to: CGPoint(x: x - 15, y: y))
                                path.addQuadCurve(to: CGPoint(x: x + (i % 2 == 0 ? 50 : -70), y: y - 50),
                                    control: CGPoint(x: x + (i % 2 == 0 ? 45 : -65), y: y - 5))
                            }
                        }
                    case .arches:
                        for i in 0..<9 {
                            let inset = Double(i) * 22
                            path.addRoundedRect(in: CGRect(x: w * 0.55 - inset, y: h * 0.15 - inset, width: w * 0.33 + inset * 2, height: h * 1.2), cornerSize: CGSize(width: w * 0.25, height: h * 0.35))
                        }
                    case .petals:
                        for i in 0..<9 {
                            let angle = Double(i) * .pi * 2 / 9
                            let center = CGPoint(x: w * 0.82, y: h * 0.2)
                            var petal = Path(ellipseIn: CGRect(x: 0, y: -34, width: w * 0.44, height: 68))
                            petal = petal.applying(CGAffineTransform(rotationAngle: angle).concatenating(.init(translationX: center.x, y: center.y)))
                            path.addPath(petal)
                        }
                    case .lattice:
                        for i in -12..<24 {
                            let t = Double(i) * 0.09
                            line(t, 0, t + 0.6, 1); line(t, 0, t - 0.6, 1)
                        }
                    case .sunburst:
                        for i in 0..<35 {
                            let angle = Double(i) * .pi * 2 / 35
                            line(0.82 + cos(angle) * 0.08, 0.2 + sin(angle) * 0.1,
                                 0.82 + cos(angle) * 1.6, 0.2 + sin(angle) * 1.6)
                        }
                    }
                    context.stroke(path, with: .color(palette.accent.opacity(palette.dark ? 0.09 : 0.075)), lineWidth: 1)
                }
            }
        }
    }
}

enum ThemeBackdrop {
    /// Prosody owns the host window and installs one desktop-sampling effect.
    case window
    /// AppKit already provides the popover's backdrop.
    case systemPopover
    /// Keep the palette opaque on hosts that do not provide a material.
    case opaque
}

private extension ThemePalette {
    func backdropGradient(opacity: Double = 1) -> LinearGradient {
        LinearGradient(
            colors: [background.opacity(opacity), backgroundEnd.opacity(opacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct ThemedRoot<Content: View>: View {
    @ObservedObject var preferences: ProsodyPreferences
    var expands = true
    var backdrop: ThemeBackdrop = .window
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let theme = preferences.theme
        let palette = theme.palette(for: systemScheme)
        let scheme: ColorScheme = palette.dark ? .dark : .light
        content()
            .frame(maxWidth: expands ? .infinity : nil, maxHeight: expands ? .infinity : nil)
            .background {
                ThemeBackground(palette: palette, isAdaptive: theme.isAdaptive, backdrop: backdrop)
                    .ignoresSafeArea(.container)
            }
            .environment(\.prosodyPalette, palette)
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(theme.isAdaptive ? nil : scheme)
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .accentColor(palette.accent)
            .buttonStyle(ThemedControlButtonStyle())
    }
}

struct ThemedControlButtonStyle: ButtonStyle {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(palette.surface.opacity(configuration.isPressed ? 0.6 : 0.95), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border) }
            .opacity(isEnabled ? 1 : 0.45)
    }
}
