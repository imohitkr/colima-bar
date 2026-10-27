import SwiftUI

/// A small capsule for the text buttons in a section header, such as
/// **Remove dangling** and **Remove unused**. Without it the buttons look
/// like the gray title text and run into each other.
struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderButtonLabel(configuration: configuration)
    }
}

extension ButtonStyle where Self == HeaderButtonStyle {
    static var header: HeaderButtonStyle { HeaderButtonStyle() }
}
