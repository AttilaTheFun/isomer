// Controls: toggles, sliders, steppers, pickers, date pickers and progress.

import Foundation
import SwiftUI

extension StoryCatalog {
    static let controls = StoryArea(id: "controls", title: "Controls", symbol: "slider.horizontal.3", stories: [
        Story(
            "controls.toggle", "Toggle", apis: ["Toggle(_:isOn:)", "Toggle(isOn:label:)", ".disabled(_:)"],
            summary: "An on-off switch bound to a Bool: a switch on iOS and Android, a checkbox or switch on the Mac, the page's own on the web."
        ) { ToggleStory() },
        Story(
            "controls.slider", "Slider", apis: ["Slider(value:)", "Slider(value:in:)", ".tint(_:)"],
            summary: "A value picked from a range by dragging: a fraction by default, or any range."
        ) { SliderStory() },
        Story(
            "controls.stepper", "Stepper", apis: ["Stepper(_:value:in:)", "Stepper(_:value:in:step:)"],
            summary: "A value raised and lowered one step at a time, within bounds."
        ) { StepperStory() },
        Story(
            "controls.picker", "Picker", apis: ["Picker(_:selection:content:)", ".pickerStyle(_:)", ".segmented", ".menu", ".tag(_:)"],
            summary: "One of several values, as segments or a menu. Each choice is tagged with the value it selects."
        ) { PickerStory() },
        Story(
            "controls.date", "DatePicker", apis: ["DatePicker(_:selection:displayedComponents:)", ".date", ".hourAndMinute"],
            summary: "A date, a time, or both, in the platform's own picker."
        ) { DatePickerStory() },
        Story(
            "controls.progress", "ProgressView", apis: ["ProgressView()", "ProgressView(value:)", "ProgressView(_:value:total:)"],
            summary: "Work under way: a spinner when its length is unknown, a bar when it is."
        ) { ProgressStory() },
    ])
}

// story: controls.toggle
struct ToggleStory: View {
    @State private var wifi = true
    @State private var bluetooth = false
    @State private var airplane = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Wi-Fi", isOn: $wifi)
            Toggle(isOn: $bluetooth) {
                Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
            }
            Toggle("Airplane mode (disabled)", isOn: $airplane)
                .disabled(true)
            Text("Wi-Fi \(wifi ? "on" : "off"), Bluetooth \(bluetooth ? "on" : "off")")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: controls.slider
struct SliderStory: View {
    @State private var volume = 0.6
    @State private var rating = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume: \(Int(volume * 100))%")
            Slider(value: $volume)
            Text("Rating: \(Int(rating.rounded())) of 5")
            Slider(value: $rating, in: 1 ... 5)
                .tint(.orange)
        }
    }
}
// end story

// story: controls.stepper
struct StepperStory: View {
    @State private var quantity = 1
    @State private var temperature = 20.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1 ... 10)
            Stepper("Temperature: \(String(format: "%.1f", temperature))°", value: $temperature, in: 10 ... 30, step: 0.5)
        }
    }
}
// end story

// story: controls.picker
struct PickerStory: View {
    enum Flavor: String, CaseIterable, Identifiable {
        case vanilla, chocolate, strawberry
        var id: Self { self }
    }

    @State private var flavor = Flavor.chocolate
    @State private var size = "Medium"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Flavor", selection: $flavor) {
                ForEach(Flavor.allCases) { flavor in
                    Text(flavor.rawValue.capitalized).tag(flavor)
                }
            }
            .pickerStyle(.segmented)
            Picker("Size", selection: $size) {
                ForEach(["Small", "Medium", "Large"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Size (automatic)", selection: $size) {
                ForEach(["Small", "Medium", "Large"], id: \.self) { Text($0).tag($0) }
            }
            Text("\(size) \(flavor.rawValue)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: controls.date
struct DatePickerStory: View {
    // A fixed day, so the page looks the same each time it is opened.
    @State private var date = Date(timeIntervalSince1970: 1_793_534_400)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Day", selection: $date, displayedComponents: .date)
            DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
        }
    }
}
// end story

// story: controls.progress
struct ProgressStory: View {
    @State private var done = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView()
            ProgressView(value: 0.4)
            ProgressView("Uploading", value: done, total: 10)
            Stepper("Done: \(Int(done)) of 10", value: $done, in: 0 ... 10)
        }
    }
}
// end story
