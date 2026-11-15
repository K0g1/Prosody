import SwiftUI

/// Commit text edits on Return or focus loss. Keeping a draft lets users type
/// a multi-digit value without clamping its first digit mid-edit.
struct SettingsNumberControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let unit: String
    let accessibilityID: String
    var help: String? = nil
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var format: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(fractionDigits))
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $draft)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 58)
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand {
                    draft = value.formatted(format)
                    isFocused = false
                }
                .accessibilityIdentifier(accessibilityID + ".value")
                .settingsHelp([help, "Enter \(range.lowerBound.formatted(format)) to \(range.upperBound.formatted(format)) \(unit), then press Return."].compactMap { $0 }.joined(separator: " "))
            Text(unit).foregroundStyle(.secondary)
            Stepper(title, onIncrement: { adjust(by: step) }, onDecrement: { adjust(by: -step) })
                .labelsHidden()
                .accessibilityValue("\(value.formatted(format)) \(unit)")
                .accessibilityIdentifier(accessibilityID + ".stepper")
        }
        .fixedSize()
        .onAppear { draft = value.formatted(format) }
        .onChange(of: value) { _, newValue in draft = newValue.formatted(format) }
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        .onDisappear { if isFocused { commit() } }
    }

    private func commit() {
        if let parsed = try? format.parseStrategy.parse(draft), parsed.isFinite {
            let scale = pow(10, Double(fractionDigits))
            let normalized = (clamped(parsed) * scale).rounded() / scale
            if value != normalized { value = normalized }
        }
        draft = value.formatted(format)
    }

    private func adjust(by delta: Double) {
        commit()
        let adjusted = clamped(value + delta)
        if value != adjusted { value = adjusted }
        draft = value.formatted(format)
    }

    private func clamped(_ value: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
