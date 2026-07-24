import SwiftUI

struct ToastState: Equatable {
    let id = UUID()
    var message: String
    var isError = false

    init(message: String, isError: Bool = false) {
        self.message = message
        self.isError = isError
    }
}

extension View {
    func toast(_ state: Binding<ToastState?>) -> some View {
        modifier(ToastModifier(state: state))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var state: ToastState?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = state {
                Label(toast.message,
                      systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(toast.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .padding(.bottom, 96)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                        state = nil
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: state)
    }
}
