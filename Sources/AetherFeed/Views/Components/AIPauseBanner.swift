import SwiftUI

/// Bottom banner shown while the LLM pipeline is paused after an error;
/// renders nothing while the pipeline is healthy. Used by the article list
/// and the home/digest page.
struct AIPauseBanner: View {
    @Environment(Localizer.self) private var l10n

    var body: some View {
        if let message = LLMStatusStore.shared.pauseMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n[.aiPaused]).font(.caption.bold())
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n[.retry]) {
                    Task { await LLMPipeline.shared.kick() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.bar)
        }
    }
}
