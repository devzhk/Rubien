import SwiftUI

extension View {
    func chipBackground(_ color: Color) -> some View {
        self
            .background(color.opacity(0.2))
            .clipShape(Capsule())
    }
}
