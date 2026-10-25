import SwiftUI

/// Live call controls inside the chat that owns the call.
struct CallPanel: View {
    @ObservedObject var call: VoiceCall
    @EnvironmentObject private var calls: CallController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(status).font(.subheadline.weight(.medium))
                Spacer()
                Text("call \(call.callID.prefix(8))").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let note = call.statusNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if !call.hearing.isEmpty {
                Text(call.hearing).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else if call.hermesSpeaking {
                Text(call.lastSpoken).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 24) {
                Button { calls.setMuted(!call.muted) } label: {
                    Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill")
                }
                Button { call.toggleSpeaker() } label: {
                    Image(systemName: call.speakerOn ? "speaker.wave.2.fill" : "iphone")
                }
                Spacer()
                Button { calls.end() } label: {
                    Label("End", systemImage: "phone.down.fill")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .font(.title3)
        }
        .padding(12)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var status: String {
        switch call.state {
        case .connecting: return "Connecting…"
        case .ended: return "Call ended"
        case .live:
            if call.hermesSpeaking { return "Hermes is speaking" }
            return call.muted ? "Muted" : "Listening"
        }
    }

    private var statusColor: Color {
        switch call.state {
        case .connecting: return .orange
        case .ended: return .gray
        case .live: return call.hermesSpeaking ? .indigo : (call.muted ? .gray : .green)
        }
    }
}
