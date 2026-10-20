// A single SwiftUI feature, embedded by the Level 3 examples inside apps
// that are otherwise plain Kotlin/Compose (Android) or HTML/React (web).
// The host app owns the screen; this card owns its own state and logic —
// exactly the shape of incrementally adopting SwiftUI one feature at a time.

import SwiftUI

public struct OrderStatusCard: View {
    private static let steps = ["Ordered", "Packed", "Shipped", "Delivered"]
    @State private var step = 2
    @State private var notify = true

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Order #10 342")
                    .font(.headline)
                Spacer()
                Text(Self.steps[step])
                    .font(.subheadline).foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(step == Self.steps.count - 1 ? Color.green : Color.blue)
                    .cornerRadius(10)
            }

            // Progress rail: a dot + connector per step.
            HStack(spacing: 6) {
                ForEach(0 ..< Self.steps.count, id: \.self) { index in
                    Circle()
                        .fill(index <= step ? Color.blue : Color(white: 0, opacity: 0.15))
                        .frame(width: 14, height: 14)
                    if index < Self.steps.count - 1 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index < step ? Color.blue : Color(white: 0, opacity: 0.12))
                            .frame(height: 4)
                    }
                }
            }

            Text(step == Self.steps.count - 1
                ? "Delivered — enjoy!"
                : "Estimated delivery: Thursday, July 9")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            Toggle("Delivery notifications", isOn: $notify)

            HStack(spacing: 12) {
                Button("Advance") {
                    step = min(step + 1, Self.steps.count - 1)
                }
                Button("Reset") { step = 0 }
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(20)
    }
}
