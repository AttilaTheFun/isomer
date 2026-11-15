// A library of an app's own, built with library evolution and warnings as
// errors (BUILD.bazel), importing every module of Isomer's an app imports.
// Against Isomer's modules as they are by default, each import below fails
// the build ("module 'SwiftUI' was not compiled with library evolution
// support; using it means binary compatibility for 'ResilientClient' can't
// be guaranteed", an error under warnings-as-errors); under
// `--@isomer//:library_evolution` they are resilient and it builds. The
// public declarations use a type of each, as such a library's would.

import Combine
import CoreGraphics
import CoreTransferable
import Foundation
import Isomer
import Observation
import OSLog
import os
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ResilientBadge: View {
    public let title: String
    public let inset: CGFloat

    public init(title: String, inset: CGFloat = 8) {
        self.title = title
        self.inset = inset
    }

    public var body: some View {
        Text(title)
            .padding(inset)
            .background(Color.dynamic(light: .white, dark: .black))
    }
}

@Observable
public final class ResilientModel {
    public var count = 0
    public var changes = PassthroughSubject<Int, Never>()

    public init() {}

    public func increment() {
        count += 1
        changes.send(count)
        Logger(subsystem: "dev.isomer.tests", category: "library_evolution").info("count \(self.count)")
    }
}

public func resilientRequest(_ url: URL) -> URLRequest {
    URLRequest(url: url)
}

public let resilientType: UTType = .plainText

public func resilientPicker(_ isPresented: Binding<Bool>, _ selection: Binding<PhotosPickerItem?>) -> some View {
    ResilientBadge(title: "Pick").photosPicker(isPresented: isPresented, selection: selection)
}
