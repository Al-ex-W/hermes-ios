import SwiftUI

/// Shown outside the chat that owns the call; tapping it opens that chat.
struct ActiveCallBanner: View {
    @ObservedObject var call: VoiceCall
    let open: () -> Void
    @EnvironmentObject private var calls: CallController

    var body: some View {
        HStack {
            Button(action: open) {
                HStack {
                    Image(systemName: "phone.fill")
                    Text("On a call · \(call.title)").lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the chat with the call")
            Button(role: .destructive) { calls.end() } label: { Image(systemName: "phone.down.fill") }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.green.gradient, in: Capsule())
        .padding(.horizontal, 16)
    }
}
