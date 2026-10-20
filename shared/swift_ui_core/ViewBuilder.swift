@resultBuilder
public struct ViewBuilder {
    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    public static func buildBlock<Content: View>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock<each Content: View>(
        _ content: repeat each Content
    ) -> TupleView<(repeat each Content)> {
        var elements: [any View] = []
        for element in repeat each content {
            elements.append(element)
        }
        return TupleView(elements)
    }

    public static func buildIf<Content: View>(_ content: Content?) -> Content? {
        content
    }

    public static func buildEither<T: View, F: View>(first content: T) -> _ConditionalContent<T, F> {
        _ConditionalContent(storage: .trueContent(content))
    }

    public static func buildEither<T: View, F: View>(second content: F) -> _ConditionalContent<T, F> {
        _ConditionalContent(storage: .falseContent(content))
    }

    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView {
        AnyView(content)
    }
}
