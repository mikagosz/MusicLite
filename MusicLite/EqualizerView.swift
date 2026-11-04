import SwiftUI

/// The popover under the equalizer button: preset menu, ten band sliders, preamp and balance.
struct EqualizerView: View {
    @ObservedObject var eq = Equalizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Toggle("Korektor", isOn: $eq.isOn)
                    .toggleStyle(.switch)
                Spacer()
                Menu(eq.preset) {
                    ForEach(Equalizer.presets, id: \.name) { preset in
                        Button(preset.name) { eq.choose(preset.name) }
                    }
                }
                .frame(width: 200)
            }

            HStack(alignment: .top, spacing: 6) {
                band("Wzm.", value: $eq.preamp, help: "Przedwzmacniacz — ścisz, gdy podbite pasma przesterowują")
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
                Text("Balans")
                Text("L").foregroundStyle(.secondary)
                Slider(value: $eq.balance, in: -1...1)
                    .accessibilityLabel("Balans lewo–prawo")
                Text("P").foregroundStyle(.secondary)
                Button("Środek") { eq.balance = 0 }
                    .disabled(eq.balance == 0)
            }

            HStack {
                Spacer()
                Button("Wyzeruj wszystko") { eq.reset() }
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
