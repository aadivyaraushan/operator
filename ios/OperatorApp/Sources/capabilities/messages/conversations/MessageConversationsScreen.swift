import OperatorCore
import SwiftUI

/// Task progress lives alongside the chat that requested it.
struct MessageConversationCards: View {
    @ObservedObject var service: MessageConversationService

    var body: some View {
        ForEach(self.service.tasks.filter { $0.status != .cancelled && $0.status != .expired }) { task in
            VStack(alignment: .leading, spacing: 10) {
                Label("\(task.recipientName) · \(self.title(for: task))", systemImage: "message")
                    .font(OperatorLettering.font(.subheadline, .medium))
                Text(task.initialMessage)
                    .font(OperatorLettering.font(.subheadline))
                Text(self.progressDescription(for: task))
                    .font(OperatorLettering.font(.footnote)).foregroundStyle(OperatorBrand.muted)
                if task.status == .proposed {
                    Button("Start") { Task { await self.service.approve(task.id, automatic: true) } }
                        .disabled(!self.service.automaticMessagingEnabled || self.service.isSending)
                }
                HStack {
                    if task.status == .active { Button("Pause") { self.service.control(task.id, action: "pause") } }
                    if task.status == .paused { Button("Resume") { self.service.control(task.id, action: "resume") } }
                    if [.proposed, .active, .paused, .needsAttention].contains(task.status) {
                        Button("Cancel", role: .destructive) { self.service.control(task.id, action: "cancel") }
                    }
                }.font(OperatorLettering.font(.footnote))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
        if let error = self.service.error {
            Text(error).font(OperatorLettering.font(.footnote)).foregroundStyle(OperatorBrand.vermilion)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func title(for task: MessageConversation) -> String {
        guard task.status == .active else { return task.status.conversationTitle }
        if task.sendState == .sending { return "Sending" }
        if task.pendingMessage != nil { return "Reply ready" }
        if !task.evidence.isEmpty && task.reviewedRevision != task.revision { return "Reviewing reply" }
        return "Waiting for reply"
    }

    private func progressDescription(for task: MessageConversation) -> String {
        if let note = task.note { return note }
        let answers = task.questions.compactMap(\.answer).joined(separator: " ")
        switch task.status {
        case .proposed:
            return self.service.automaticMessagingEnabled ? "Ready to start." : "Enable automatic messaging in Permissions to start."
        case .active:
            let status = !self.service.automaticMessagingEnabled
                ? "Automatic messaging is off."
                : task.pendingMessage != nil
                    ? "Following up while Operator is open."
                    : !task.evidence.isEmpty && task.reviewedRevision != task.revision
                        ? "Checking the latest reply while Operator is open."
                        : "Waiting for a reply. I’ll follow up if needed."
            return answers.isEmpty ? status : "\(answers) \(status)"
        case .paused: return answers.isEmpty ? "Paused until you resume." : "\(answers) Paused until you resume."
        case .completed: return answers.isEmpty ? "Finished." : answers
        case .needsAttention: return "Needs your attention before continuing."
        case .cancelled: return "Cancelled."
        case .expired: return "Expired."
        }
    }

}

private extension MessageConversation.Status {
    var conversationTitle: String {
        switch self {
        case .proposed: "Ready to start"
        case .active: "In progress"
        case .paused: "Paused"
        case .completed: "Complete"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        case .needsAttention: "Needs your attention"
        }
    }
}
