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
        guard let feedback, feedback.style != .error else { return }

        // @MainActor:睡眠后直写 @Binding feedback,须回主执行器落笔(同 CCSpaceTooltip
        // 里 Task { @MainActor in } 的范式)。
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled {
                self.feedback = nil
            }
        }
    }
}
