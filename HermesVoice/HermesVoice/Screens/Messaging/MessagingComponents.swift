import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Pieces the Messaging and Webhooks screens share.

/// A platform's mark (the desktop's `PlatformAvatar`): its brand colour behind a monogram, or a symbol for the generic ones.
struct MessagingPlatformAvatar: View {
    let platformID: String
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let style = Self.style(platformID)
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.icon)
                .fill(style.color.opacity(0.14))
            if let symbol = style.symbol {
                Image(systemName: symbol).font(.system(size: size * 0.46, weight: .medium))
            } else {
                Text(monogram).font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(style.color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var monogram: String {
        String(name.trimmingCharacters(in: .whitespaces).first ?? Character(platformID.prefix(1).uppercased())).uppercased()
    }

    /// `PLATFORM_ICONS`: the brands' colours (simpleicons.org), symbols for the generic platforms.
    static func style(_ platformID: String) -> (color: Color, symbol: String?) {
        switch platformID {
        case "telegram": return (Color(red: 0x26 / 255, green: 0xA5 / 255, blue: 0xE4 / 255), nil)
        case "discord": return (Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255), nil)
        case "slack": return (Color(red: 0x4A / 255, green: 0x15 / 255, blue: 0x4B / 255), nil)
        case "mattermost": return (Color(red: 0x00 / 255, green: 0x58 / 255, blue: 0xCC / 255), nil)
        case "matrix": return (Theme.Text.primary, nil)
        case "signal": return (Color(red: 0x3A / 255, green: 0x76 / 255, blue: 0xF0 / 255), nil)
        case "whatsapp": return (Color(red: 0x25 / 255, green: 0xD3 / 255, blue: 0x66 / 255), nil)
        case "bluebubbles": return (Color(red: 0x0B / 255, green: 0xD3 / 255, blue: 0x18 / 255), "bubble.left.fill")
        case "photon": return (Color(red: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255), nil)
        case "homeassistant": return (Color(red: 0x18 / 255, green: 0xBC / 255, blue: 0xF2 / 255), "house")
        case "email": return (Color(red: 0xEA / 255, green: 0x43 / 255, blue: 0x35 / 255), "envelope")
        case "sms": return (Color(red: 0xF4 / 255, green: 0x3F / 255, blue: 0x5E / 255), "message")
        case "webhook": return (Color(red: 0x71 / 255, green: 0x71 / 255, blue: 0x7A / 255), "link")
        case "api_server": return (Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255), "globe")
        case "weixin": return (Color(red: 0x07 / 255, green: 0xC1 / 255, blue: 0x60 / 255), nil)
        case "qqbot": return (Color(red: 0xEB / 255, green: 0x19 / 255, blue: 0x23 / 255), nil)
        case "yuanbao": return (Color(red: 0xFB / 255, green: 0x72 / 255, blue: 0x99 / 255), nil)
        default: return (Theme.Text.tertiary, nil)
        }
    }
}

/// A QR code for another device to scan, drawn on the phone (black on white, whatever the theme).
struct MessagingQRCode: View {
    let payload: String
    var side: CGFloat = 200
    var label = "QR code"
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: side, height: side)
        .padding(Theme.Spacing.md)
        .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
        .task(id: payload) { image = MessagingQRRenderer.image(payload) }
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

enum MessagingQRRenderer {
    /// The code at a whole-number scale (so its modules stay crisp), or nil when the payload doesn't fit a code.
    static func image(_ payload: String, scale: CGFloat = 8) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// A warning line (the desktop's warning `Alert`; its action is the row below it).
struct MessagingBanner: View {
    let text: String
    var systemImage = Theme.Icon.warning

    var body: some View {
        Label {
            Text(text).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Theme.Semantic.attention)
        }
    }
}

/// A value to copy (a URL), in monospace with its copy button (the desktop's `CopyValueRow`).
struct MessagingCopyRow: View {
    let value: String
    var copyLabel = "Copy"

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(value)
                .font(Theme.TextStyle.code.font)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            OpsCopyButton(text: value, label: copyLabel)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

/// A secret shown once: masked until revealed, copied to this phone's clipboard only, for two minutes.
struct MessagingSecretRow: View {
    let secret: String
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(revealed ? secret : WebhookSecretMask.masked(secret))
                .font(Theme.TextStyle.code.font)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(revealed ? 3 : 1)
                .textSelection(.enabled)
                .privacySensitive()
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "Hide secret" : "Show secret")
            Button {
                MessagingSecretClipboard.copy(secret)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : Theme.Icon.copy)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : "Copy secret")
        }
    }
}

enum MessagingSecretClipboard {
    /// Stays on this phone (no Universal Clipboard) and clears itself after two minutes.
    static func copy(_ secret: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: secret]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
    }
}

/// A section's title above its rows (`SectionTitle`).
struct MessagingSectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).textCase(nil)
    }
}
