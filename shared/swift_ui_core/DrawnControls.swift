// Display-list implementations of the pop-up controls for the self-drawing
// path (swapped in by ChromeExpansion): Menu, Picker, and DatePicker drawn
// entirely at the GPU layer, identical on every backend. Component-system
// renderers build these from their platform's native components instead.

/// A drawn pop-up list shared by Menu and Picker: a tappable label opens a
/// popover of rows; picking one fires its action and closes.
struct DrawnPopUpList {
    let label: String
    let accented: Bool
    let rows: [String]
    /// Index of the check-marked row, or nil (menus have no selection).
    let selectedIndex: Int?
    let onSelect: (Int) -> Void
    @State private var open = false

    var body: some View {
        Button(action: { open = true }) {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundColor(accented ? .accentColor : .primary)
                Text("\u{25BE}") // ▾
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(white: 0.5, opacity: 0.12))
            )
        }
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< rows.count) { index in
                    Button(action: {
                        open = false
                        onSelect(index)
                    }) {
                        HStack(spacing: 8) {
                            Text(rows[index]).foregroundColor(.primary)
                            Spacer(minLength: 12)
                            if index == selectedIndex {
                                Text("\u{2713}") // ✓ (in DejaVu Sans too)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(width: 240)
        }
    }
}

/// A drawn segmented control (`.pickerStyle(.segmented)`): every option in a
/// pill row, the selected one raised — the same shape on every GPU backend.
struct DrawnSegmented {
    let options: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< options.count, id: \.self) { index in
                Button(action: { onSelect(index) }) {
                    Text(options[index])
                        .font(.system(size: 14, weight: index == selectedIndex ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(index == selectedIndex ? Color.secondaryBackground : Color.clear)
                        )
                }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.5, opacity: 0.16)))
    }
}

/// A drawn date picker: the formatted date opens a popover of three stepper
/// rows (year / month / day) editing the ISO `yyyy-MM-dd` value.
struct DrawnDatePicker {
    let title: String
    /// ISO yyyy-MM-dd in/out.
    let isoValue: String
    let onChange: (String) -> Void
    @State private var open = false

    private var parts: (year: Int, month: Int, day: Int) {
        let pieces = isoValue.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return (2026, 1, 1) }
        return (pieces[0], pieces[1], pieces[2])
    }

    private func emit(year: Int, month: Int, day: Int) {
        let clampedMonth = min(max(month, 1), 12)
        let clampedDay = min(max(day, 1), 31)
        func pad(_ value: Int) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        onChange("\(year)-\(pad(clampedMonth))-\(pad(clampedDay))")
    }

    private func stepperRow(_ label: String, _ value: Int, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).foregroundColor(.secondary).frame(width: 60, alignment: .leading)
            Button(action: { set(value - 1) }) {
                Text("\u{2212}").font(.system(size: 18)) // −
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(white: 0.5, opacity: 0.15)))
            }
            Text("\(value)")
                .font(.system(size: 16, weight: .semibold))
                .frame(minWidth: 52)
            Button(action: { set(value + 1) }) {
                Text("+").font(.system(size: 18))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(white: 0.5, opacity: 0.15)))
            }
        }
    }

    var body: some View {
        let current = parts
        return Button(action: { open = true }) {
            HStack(spacing: 6) {
                if !title.isEmpty {
                    Text(title).foregroundColor(.primary)
                }
                Text(isoValue)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(white: 0.5, opacity: 0.12))
                    )
            }
        }
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow("Year", current.year) { emit(year: $0, month: current.month, day: current.day) }
                stepperRow("Month", current.month) { emit(year: current.year, month: $0, day: current.day) }
                stepperRow("Day", current.day) { emit(year: current.year, month: current.month, day: $0) }
            }
            .padding(16)
        }
    }
}

/// A drawn placeholder for embedded platform surfaces (WebView, VideoPlayer)
/// under the self-drawing renderers: those contents can't be rasterized by the
/// GPU layer, so the placeholder offers to open them externally.
struct DrawnMediaPlaceholder {
    let kind: String
    let url: String

    var body: some View {
        Button(action: { Runtime.shared.host?.openURL(url) }) {
            VStack(spacing: 8) {
                Text(kind == "video" ? "\u{25B6}" : "\u{2197}") // ▶ / ↗
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text(kind == "video" ? "Open video" : "Open page")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(url)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.5, opacity: 0.08))
            )
        }
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension DrawnPopUpList: View {}
extension DrawnSegmented: View {}
extension DrawnDatePicker: View {}
extension DrawnMediaPlaceholder: View {}
