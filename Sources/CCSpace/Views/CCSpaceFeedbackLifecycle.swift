import SwiftUI

extension View {
    func ccspaceAutoDismissFeedback(
        _ feedback: Binding<CCSpaceFeedback?>,
        after delay: TimeInterval = 3
    ) -> some View {
        modifier(
            CCSpaceFeedbackAutoDismissModifier(
                feedback: feedback,
                delay: delay
            )
        )
    }
}

private struct CCSpaceFeedbackAutoDismissModifier: ViewModifier {
    @Binding var feedback: CCSpaceFeedback?
    let delay: TimeInterval

    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                scheduleAutoDismissIfNeeded(for: feedback)
            }
            .onChange(of: feedback) { _, newValue in
                scheduleAutoDismissIfNeeded(for: newValue)
            }
            .onDisappear {
                dismissTask?.cancel()
            }
    }

    private func scheduleAutoDismissIfNeeded(for feedback: CCSpaceFeedback?) {
        dismissTask?.cancel()
        guard feedback != nil else { return }

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled {
                self.feedback = nil
            }
        }
    }
}
