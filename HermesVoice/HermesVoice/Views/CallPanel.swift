import SwiftUI

/// Call controls inside the chat that owns the call: answer or decline while Hermes rings, then mute, speaker
/// and hang up, with what Hermes says and what is heard.
struct CallPanel: View {
    @ObservedObject var call: VoiceCall
    @EnvironmentObject private var calls: CallController
    #if targetEnvironment(simulator)
    @State private var typed = ""
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(status).font(.subheadline.weight(.medium))
                Spacer()
                if call.state == .live, call.speechProvider == .scribe {
                    Text("Scribe").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
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
            if call.state == .ringing {
                ringingControls
            } else {
                liveControls
            }
            #if targetEnvironment(simulator)
            if call.state == .live {
                // No microphone in the Simulator: type what you would say.
                HStack {
                    TextField("Say…", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sayTyped)
                    Button("Say", action: sayTyped).disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .font(.callout)
            }
            #endif
        }
        .padding(12)
        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var ringingControls: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) { calls.end() } label: {
                Label("Decline", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button { calls.answer() } label: {
                Label("Answer", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.green, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .font(.headline)
        .buttonStyle(.plain)
    }

    private var liveControls: some View {
        HStack(spacing: 24) {
            Button { calls.setMuted(!call.muted) } label: {
                Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill")
            }
            .accessibilityLabel(call.muted ? "Unmute" : "Mute")
            Button { call.toggleSpeaker() } label: {
                Image(systemName: call.speakerOn ? "speaker.wave.2.fill" : "iphone")
            }
            .accessibilityLabel(call.speakerOn ? "Use the earpiece" : "Use the speaker")
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

    #if targetEnvironment(simulator)
    private func sayTyped() {
        call.sayTyped(typed)
        typed = ""
    }
    #endif

    private var status: String {
        switch call.state {
        case .ringing: return "Hermes is calling…"
        case .connecting: return "Connecting…"
        case .ended: return "Call ended"
        case .live:
            if call.hermesSpeaking { return "Hermes is speaking" }
            return call.muted ? "Muted" : "Listening"
        }
    }

    private var statusColor: Color {
        switch call.state {
        case .ringing, .connecting: return .orange
        case .ended: return .gray
        case .live: return call.hermesSpeaking ? .indigo : (call.muted ? .gray : .green)
        }
    }
}
