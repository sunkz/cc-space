import SwiftUI

extension View {
    func ccspaceAutoDismissFeedback(_ feedback: Binding<CCSpaceFeedback?>) -> some View {
        modifier(CCSpaceFeedbackAutoDismissModifier(feedback: feedback))
    }
}

private struct CCSpaceFeedbackAutoDismissModifier: ViewModifier {
    @Binding var feedback: CCSpaceFeedback?

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
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                self.feedback = nil
            }
        }
    }
}
