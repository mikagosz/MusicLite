import SwiftUI

/// The popover under the equalizer button: preset menu, ten band sliders, preamp and balance.
struct EqualizerView: View {
    @ObservedObject var eq = Equalizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Equalizer", isOn: $eq.isOn)
                    .toggleStyle(.switch)
                Spacer()
                Menu(Equalizer.displayName(eq.preset)) {
                    ForEach(Equalizer.presets, id: \.name) { preset in
                        Button(Equalizer.displayName(preset.name)) { eq.choose(preset.name) }
                    }
                }
                .frame(width: 200)
            }

            HStack(alignment: .top, spacing: 6) {
                band(String(localized: "Pre", comment: "Short label under the preamp slider"), value: $eq.preamp,
                     help: String(localized: "Preamp — turn it down when boosted bands distort"))
                Divider().frame(height: 150)
                scale
                ForEach(Equalizer.bands.indices, id: \.self) { n in
                    band(label(Equalizer.bands[n]),
                         value: Binding(get: { eq.gains[n] }, set: { eq.setGain(n, $0) }),
                         help: "\(label(Equalizer.bands[n]))Hz")
                }
            }
            .disabled(!eq.isOn)

            Divider()

            HStack(spacing: 8) {
                Text("Balance")
                Text("L").foregroundStyle(.secondary)
                Slider(value: $eq.balance, in: -1...1)
                    .accessibilityLabel("Balance left–right")
                Text("R", comment: "Right channel").foregroundStyle(.secondary)
                Button("Center") { eq.balance = 0 }
                    .disabled(eq.balance == 0)
            }

            HStack {
                Spacer()
                Button("Reset All") { eq.reset() }
            }
        }
        .padding(16)
        .frame(width: 470)
    }

    private var scale: some View {
        VStack {
            Text("+12")
            Spacer()
            Text("0")
            Spacer()
            Text("−12")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(height: 150)
    }

    /// A vertical slider with its label under it. Double-click the label: back to 0.
    private func band(_ title: String, value: Binding<Float>, help: String) -> some View {
        VStack(spacing: 4) {
            Slider(value: value, in: Equalizer.range)
                .controlSize(.small)
                .frame(width: 150)
                .rotationEffect(.degrees(-90))
                .frame(width: 28, height: 150)
                .help("\(help): \(String(format: "%+.1f", value.wrappedValue)) dB")
                .accessibilityLabel(help)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) { value.wrappedValue = 0 }
        }
    }

    private func label(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))K" : "\(Int(hz))"
    }
}
