// Alerts' and confirmation dialogs' titles in each of Apple's forms: a
// LocalizedStringKey (what a string literal is, as for Text: these are the
// overloads a literal picks, the StringProtocol ones being disfavored, as
// Apple's are) and a Text, each drawn as the String form draws (Isomer's
// one modal dialog shape). And the alerts about an item, shown while it is
// non-nil, as the dialogs about one are.

extension View {
    // MARK: Alerts

    nonisolated public func alert<A: View>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> A
    ) -> some View {
        alert(Text(titleKey).content, isPresented: isPresented, actions: actions)
    }

    nonisolated public func alert<A: View>(
        _ title: Text,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> A
    ) -> some View {
        alert(title.content, isPresented: isPresented, actions: actions)
    }

    nonisolated public func alert<A: View, M: View>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: () -> M
    ) -> some View {
        alert(Text(titleKey).content, isPresented: isPresented, actions: actions, message: message)
    }

    nonisolated public func alert<A: View, M: View>(
        _ title: Text,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: () -> M
    ) -> some View {
        alert(title.content, isPresented: isPresented, actions: actions, message: message)
    }

    nonisolated public func alert<A: View, T>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        alert(Text(titleKey).content, isPresented: isPresented, presenting: data, actions: actions)
    }

    nonisolated public func alert<A: View, T>(
        _ title: Text,
        isPresented: Binding<Bool>,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        alert(title.content, isPresented: isPresented, presenting: data, actions: actions)
    }

    nonisolated public func alert<A: View, M: View, T>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: (T) -> M
    ) -> some View {
        alert(Text(titleKey).content, isPresented: isPresented, presenting: data, actions: actions, message: message)
    }

    nonisolated public func alert<A: View, M: View, T>(
        _ title: Text,
        isPresented: Binding<Bool>,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: (T) -> M
    ) -> some View {
        alert(title.content, isPresented: isPresented, presenting: data, actions: actions, message: message)
    }

    /// `.alert(_:item:actions:)`: an alert about the item, shown while it is
    /// non-nil; dismissing it sets it nil.
    @_disfavoredOverload
    nonisolated public func alert<S: StringProtocol, A: View, T>(
        _ title: S,
        item data: Binding<T?>,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        _confirmationDialog(String(title), item: data, titleVisibility: .visible, actions: actions, message: { _ in "" })
    }

    nonisolated public func alert<A: View, T>(
        _ titleKey: LocalizedStringKey,
        item data: Binding<T?>,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        alert(Text(titleKey).content, item: data, actions: actions)
    }

    nonisolated public func alert<A: View, T>(
        _ title: Text,
        item data: Binding<T?>,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        alert(title.content, item: data, actions: actions)
    }

    @_disfavoredOverload
    nonisolated public func alert<S: StringProtocol, A: View, M: View, T>(
        _ title: S,
        item data: Binding<T?>,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: @escaping (T) -> M
    ) -> some View {
        _confirmationDialog(String(title), item: data, titleVisibility: .visible, actions: actions,
                            message: { _extractText(message($0)) })
    }

    nonisolated public func alert<A: View, M: View, T>(
        _ titleKey: LocalizedStringKey,
        item data: Binding<T?>,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: @escaping (T) -> M
    ) -> some View {
        alert(Text(titleKey).content, item: data, actions: actions, message: message)
    }

    // MARK: Confirmation dialogs

    nonisolated public func confirmationDialog<A: View>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> A
    ) -> some View {
        confirmationDialog(Text(titleKey).content, isPresented: isPresented, titleVisibility: titleVisibility, actions: actions)
    }

    nonisolated public func confirmationDialog<A: View>(
        _ title: Text,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> A
    ) -> some View {
        confirmationDialog(title.content, isPresented: isPresented, titleVisibility: titleVisibility, actions: actions)
    }

    nonisolated public func confirmationDialog<A: View, M: View>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: () -> M
    ) -> some View {
        confirmationDialog(Text(titleKey).content, isPresented: isPresented, titleVisibility: titleVisibility,
                           actions: actions, message: message)
    }

    nonisolated public func confirmationDialog<A: View, M: View>(
        _ title: Text,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> A,
        @ViewBuilder message: () -> M
    ) -> some View {
        confirmationDialog(title.content, isPresented: isPresented, titleVisibility: titleVisibility,
                           actions: actions, message: message)
    }

    nonisolated public func confirmationDialog<A: View, T>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        confirmationDialog(Text(titleKey).content, isPresented: isPresented, titleVisibility: titleVisibility,
                           presenting: data, actions: actions)
    }

    nonisolated public func confirmationDialog<A: View, T>(
        _ title: Text,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        confirmationDialog(title.content, isPresented: isPresented, titleVisibility: titleVisibility,
                           presenting: data, actions: actions)
    }

    nonisolated public func confirmationDialog<A: View, M: View, T>(
        _ titleKey: LocalizedStringKey,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        presenting data: T?,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: (T) -> M
    ) -> some View {
        confirmationDialog(Text(titleKey).content, isPresented: isPresented, titleVisibility: titleVisibility,
                           presenting: data, actions: actions, message: message)
    }

    nonisolated public func confirmationDialog<A: View, T>(
        _ titleKey: LocalizedStringKey,
        item data: Binding<T?>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping (T) -> A
    ) -> some View {
        confirmationDialog(Text(titleKey).content, item: data, titleVisibility: titleVisibility, actions: actions)
    }

    nonisolated public func confirmationDialog<A: View, M: View, T>(
        _ titleKey: LocalizedStringKey,
        item data: Binding<T?>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping (T) -> A,
        @ViewBuilder message: @escaping (T) -> M
    ) -> some View {
        confirmationDialog(Text(titleKey).content, item: data, titleVisibility: titleVisibility,
                           actions: actions, message: message)
    }
}
