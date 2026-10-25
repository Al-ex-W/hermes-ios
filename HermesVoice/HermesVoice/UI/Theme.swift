import SwiftUI
import UIKit

/// Design tokens of the desktop's default "nous" skin (`apps/desktop/DESIGN.md`,
/// `apps/shared/src/theme-presets.ts`, `apps/desktop/src/styles.css`). Surfaces are mixed from the
/// preset the way styles.css mixes them, so light and dark match what the desktop paints.
/// One CSS px is one point throughout.
enum Theme {
    // MARK: Surfaces and slots (`--dt-*`)

    /// Chat and page background (`--ui-bg-chrome`).
    static let background = color(\.chrome)
    /// Primary ink (`--dt-foreground`, the base at 94%).
    static let foreground = color { $0.foreground.opacity(0.94) }
    /// Raised panels and code surfaces (`--ui-bg-editor`).
    static let card = color(\.editor)
    /// Sidebar column (`--ui-bg-sidebar`).
    static let sidebar = color(\.sidebarBackground)
    static let sidebarBorder = color(\.sidebarBorder)
    /// The sidebar's edge against the chat (`--sidebar-edge-border`).
    static let sidebarEdge = color { $0.foreground.opacity($0.isDark ? 0.12 : 0.075) }
    /// Menus, popovers and dialogs (`--ui-bg-elevated` at 96%).
    static let popover = color { $0.elevated.opacity(0.96) }
    static let muted = color(\.muted)
    static let mutedForeground = color { $0.foreground.opacity(0.54) }
    static let primary = color(\.primary)
    static let primaryForeground = color(\.primaryForeground)
    static let secondary = color(\.secondary)
    static let secondaryForeground = color(\.secondaryForeground)
    static let accent = color(\.accent)
    static let accentForeground = color(\.accentForeground)
    /// App-wide border. Bordered surfaces in the transcript use `Hairline.tertiary`, which reads quieter.
    static let border = color(\.border)
    static let input = color(\.input)
    static let ring = color(\.ring)
    /// Brand stroke: focus rings, running dots, streaming cursor (`--ui-accent`).
    static let midground = color(\.midground)
    static let destructive = color(\.destructive)
    static let destructiveForeground = color(\.destructiveForeground)
    /// User message fill (`--ui-chat-bubble-background`): near white in light, a navy tint in dark.
    static let userBubble = color(\.bubble)
    static let userBubbleBorder = color(\.userBubbleBorder)
    /// Inline chat widgets such as clarify and artifact cards (`--ui-widget-surface-background`).
    static let widget = color { $0.isDark ? $0.editor.mixed(0.88, with: .black) : $0.editor }

    /// Text hierarchy by foreground opacity (`--ui-text-*`).
    enum Text {
        static let primary = color { $0.foreground.opacity(0.94) }
        static let secondary = color { $0.foreground.opacity(0.74) }
        static let tertiary = color { $0.foreground.opacity(0.54) }
        static let quaternary = color { $0.foreground.opacity(0.36) }
        /// Transcript scaffolding: thinking headers, settled tool runs, the activity line.
        static let scaffold = color { $0.foreground.opacity(0.64) }
        static let scaffoldMeta = color { $0.foreground.opacity(0.44) }
        static let inlineCode = color { ($0.isDark ? RGBA.white : 0x141414).opacity(0.88) }
    }

    /// Hairlines in descending strength (`--ui-stroke-*`): the foreground at 10/7/5/3%,
    /// tinted with the brand accent at 24/16/10/6%.
    enum Hairline {
        static let primary = color { $0.tint(accent: 0.24, base: 0.10) }
        static let secondary = color { $0.tint(accent: 0.16, base: 0.07) }
        /// The default divider, and the border of every bordered surface in the transcript.
        static let tertiary = color { $0.tint(accent: 0.10, base: 0.05) }
        static let quaternary = color { $0.tint(accent: 0.06, base: 0.03) }
        /// Outline of floating panels, paired with the `hermesFloating()` shadow (`--stroke-nous`).
        static let overlay = color { $0.foreground.opacity(0.03) }
    }

    static let hairlineWidth: CGFloat = 1

    /// Soft fills and interaction states (`--ui-bg-*`, `--ui-row-*`, `--ui-control-*`).
    enum Fill {
        static let primary = color { $0.tint(accent: 0.16, base: 0.10) }
        static let secondary = color { $0.tint(accent: 0.11, base: 0.07) }
        static let tertiary = color { $0.tint(accent: 0.08, base: 0.05) }
        /// Soft control fill: secondary buttons and chips.
        static let quaternary = color { $0.tint(accent: 0.05, base: 0.04) }
        static let quinary = color { $0.tint(accent: 0.03, base: 0.03) }
        static let rowHover = color { $0.tint(accent: 0.04, base: 0.03) }
        static let rowActive = color { $0.tint(accent: 0.08, base: 0.05) }
        /// Hover/press fill of quiet controls (`--chrome-action-hover`).
        static let controlHover = color { $0.tint(accent: 0.06, base: 0.04) }
        static let controlActive = color { $0.tint(accent: 0.08, base: 0.05) }
        static let inlineCode = color { $0.isDark ? RGBA.white.opacity(0.07) : (0x141414 as RGBA).opacity(0.05) }
        static let selection = color { (0xffd24a as RGBA).opacity($0.isDark ? 0.38 : 0.55) }
    }

    /// Semantic hues (`--ui-red` …) and the states built on them.
    enum Semantic {
        static let red = color(\.red)
        static let orange = color(\.orange)
        static let yellow = color(\.yellow)
        static let green = color(\.green)
        static let cyan = color(\.cyan)
        static let blue = color(\.blue)
        static let purple = color(\.purple)
        /// Finished while away (`--ui-success`: emerald turned a quarter toward the accent).
        static let success = color(\.success)
        /// A clarify or approval is blocking the turn (Tailwind amber-500).
        static let attention = color(\.attention)
        static let diffAddBackground = color { $0.green.opacity(0.12) }
        static let diffAddForeground = color { $0.green.mixed($0.isDark ? 0.62 : 0.70, with: $0.isDark ? .white : .black) }
        static let diffRemoveBackground = color { $0.red.opacity(0.12) }
        static let diffRemoveForeground = color { $0.red.mixed($0.isDark ? 0.62 : 0.70, with: $0.isDark ? .white : .black) }
    }

    // MARK: Shape and space

    /// Near-square corners: the desktop pins `--radius-scalar` at 0.2, shrinking Tailwind's scale to 2–6 pt.
    enum Radius {
        /// Menu items and row highlights (`rounded-md`).
        static let row: CGFloat = 2
        /// Menus and popovers (`rounded-lg`).
        static let menu: CGFloat = 2.4
        /// Text buttons and text fields.
        static let control: CGFloat = 2.5
        /// User bubbles and dialogs (`rounded-xl`).
        static let bubble: CGFloat = 3.2
        /// Icon buttons and tooltips.
        static let icon: CGFloat = 4
        /// The composer (`rounded-2xl`).
        static let composer: CGFloat = 4.8
        /// Inline chat widgets (`rounded-3xl`).
        static let widget: CGFloat = 6.4
    }

    /// Tailwind's 4 pt steps plus the named transcript gaps from styles.css.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        /// Page side gutter (the floor of `PAGE_INSET_X`).
        static let page: CGFloat = 20
        /// Sidebar content side padding.
        static let sidebarInset: CGFloat = 16
        /// Between turns (`--conversation-turn-gap`).
        static let turn: CGFloat = 6
        /// Between prose, tool and thinking blocks of one turn (`--turn-block-gap`).
        static let turnBlock: CGFloat = 12
        /// Between adjacent scaffolding rows (`--scaffold-block-gap`).
        static let scaffold: CGFloat = 4
        /// Between tool rows of one group (`--tool-row-gap`).
        static let toolRow: CGFloat = 6
        /// Between prose paragraphs (`--paragraph-gap`).
        static let paragraph: CGFloat = 11.2
        /// Assistant text indent (`--message-text-indent`).
        static let messageIndent: CGFloat = 12
    }

    // MARK: Type

    /// Desktop default for Chat Text Size; it scales transcript and composer text only.
    static let chatTextScale: CGFloat = 1.1

    /// A size and line height. `hermesText(_:)` applies it with Dynamic Type; `font` is the fixed size.
    /// The sans face is SF Pro, as on the desktop. JetBrains Mono, the desktop's mono face, is not
    /// bundled, so monospaced styles use the system monospaced design.
    struct TextStyle {
        var size: CGFloat
        var lineHeight: CGFloat
        var weight: Font.Weight = .regular
        var monospaced = false
        var relativeTo: Font.TextStyle = .body

        var font: Font { font(size: size) }

        func font(size: CGFloat) -> Font {
            .system(size: size, weight: weight, design: monospaced ? .monospaced : .default)
        }

        /// Assistant prose: conversation size at line height 1.5.
        static let prose = TextStyle(size: 13 * chatTextScale, lineHeight: 13 * chatTextScale * 1.5)
        /// User bubbles and the composer (`--conversation-text-*`, 13/18).
        static let conversation = TextStyle(size: 13 * chatTextScale, lineHeight: 18 * chatTextScale)
        /// Tool rows (`--conversation-tool-*`, 11).
        static let tool = TextStyle(size: 11 * chatTextScale, lineHeight: 16 * chatTextScale, relativeTo: .footnote)
        /// Transcript captions and descriptions (`--conversation-caption-*`, 12/16).
        static let caption = TextStyle(size: 12 * chatTextScale, lineHeight: 16 * chatTextScale, relativeTo: .caption)
        /// Code in the transcript, 0.9 em of conversation text.
        static let code = TextStyle(size: 13 * chatTextScale * 0.9, lineHeight: 13 * chatTextScale * 0.9 * 1.5,
                                    monospaced: true)
        /// App chrome outside the transcript (the desktop body, 13 pt at line height 1.5).
        static let body = TextStyle(size: 13, lineHeight: 19.5)
        /// Sidebar session titles.
        static let rowTitle = TextStyle(size: 13, lineHeight: 13 * 1.35, weight: .medium)
        static let button = TextStyle(size: 12, lineHeight: 16, weight: .medium, relativeTo: .subheadline)
        /// Sidebar section labels and their meta.
        static let label = TextStyle(size: 11, lineHeight: 16, weight: .medium, relativeTo: .caption)
        /// Timestamps, counts and badges.
        static let meta = TextStyle(size: 10, lineHeight: 12, relativeTo: .caption2)
    }

    // MARK: Icons

    /// Icon point sizes (`iconSize` in `src/lib/icons.ts`); controls default to `sm`.
    enum IconSize {
        static let xs: CGFloat = 12
        static let sm: CGFloat = 14
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
    }

    /// SF Symbols standing in for the desktop's Tabler and Codicon glyphs. Spinners (`Loader2`,
    /// codicon `loading`) are a progress view, not a glyph.
    enum Icon {
        // Sidebar navigation (`SIDEBAR_NAV`); the desktop's New session glyph is codicon `robot`.
        static let newSession = "square.and.pencil"
        static let capabilities = "cube"
        static let messaging = "bubble.left"
        static let artifacts = "doc.on.doc"
        static let scheduledJobs = "clock"
        static let search = "magnifyingglass"
        static let filter = "line.3.horizontal.decrease"
        static let settings = "gearshape"
        static let profile = "person.crop.circle"

        // Session menu (`session-actions-menu.tsx`).
        static let more = "ellipsis"
        static let rename = "pencil"
        static let pin = "pin"
        static let markUnread = "envelope"
        static let markRead = "envelope.open"
        static let branch = "arrow.triangle.branch"
        static let export = "icloud.and.arrow.down"
        static let archive = "archivebox"
        static let unarchive = "tray.and.arrow.up"
        static let delete = "trash"

        // Composer and transcript.
        static let attach = "plus"
        static let send = "arrow.up"
        static let stop = "stop.fill"
        static let copy = "doc.on.doc"
        static let retry = "arrow.clockwise"
        static let restore = "arrow.uturn.backward"
        static let tool = "wrench.and.screwdriver"
        static let terminal = "terminal"
        static let reasoning = "brain"
        static let disclosure = "chevron.right"
        static let error = "exclamationmark.circle"
        static let warning = "exclamationmark.triangle"
        static let close = "xmark"

        /// Codicon name → SF Symbol for the glyphs the sidebar and chat use, including names that
        /// arrive at runtime (messaging platforms carry a `codicon`).
        static let codicons: [String: String] = [
            "account": "person.crop.circle", "add": "plus", "agent": "person.2", "archive": "archivebox",
            "arrow-down": "arrow.down", "arrow-left": "arrow.left", "arrow-right": "arrow.right",
            "arrow-small-right": "arrow.right", "arrow-swap": "arrow.left.arrow.right", "arrow-up": "arrow.up",
            "brain": "brain", "browser": "globe", "bug": "ladybug", "check": "checkmark",
            "check-all": "checkmark.circle", "checklist": "checklist", "chevron-down": "chevron.down",
            "chevron-left": "chevron.left", "chevron-right": "chevron.right", "chevron-up": "chevron.up",
            "circle-slash": "nosign", "clear-all": "clear", "close": "xmark", "close-all": "xmark.square",
            "cloud-download": "icloud.and.arrow.down", "comment": "bubble.left",
            "comment-discussion": "bubble.left.and.bubble.right", "compass": "location.north.circle",
            "copy": "doc.on.doc", "debug-pause": "pause", "debug-stop": "stop",
            "device-desktop": "desktopcomputer", "discard": "arrow.uturn.backward", "edit": "pencil",
            "ellipsis": "ellipsis", "empty-window": "macwindow", "error": "exclamationmark.circle",
            "eye": "eye", "eye-closed": "eye.slash", "files": "doc.on.doc", "folder": "folder",
            "folder-opened": "folder", "git-branch": "arrow.triangle.branch", "globe": "globe",
            "grabber": "line.3.horizontal", "hubot": "cpu", "json": "curlybraces", "kebab-vertical": "ellipsis",
            "layers": "square.3.layers.3d", "layout": "rectangle.split.3x1", "layout-sidebar-left": "sidebar.left",
            "layout-sidebar-right": "sidebar.right", "link-external": "arrow.up.right.square",
            "list-filter": "line.3.horizontal.decrease", "list-unordered": "list.bullet", "mail": "envelope",
            "mail-read": "envelope.open", "mic": "mic", "package": "shippingbox",
            "pass-filled": "checkmark.circle.fill", "pin": "pin", "play": "play", "plug": "powerplug",
            "pulse": "waveform.path.ecg", "refresh": "arrow.clockwise", "remote": "network", "repo": "book.closed",
            "repo-forked": "arrow.triangle.branch", "robot": "cpu", "root-folder": "folder",
            "screen-normal": "arrow.down.right.and.arrow.up.left", "settings-gear": "gearshape",
            "sparkle": "sparkle", "split-horizontal": "rectangle.split.1x2", "stop-circle": "stop.circle",
            "symbol-color": "paintpalette", "symbol-misc": "cube", "sync": "arrow.triangle.2.circlepath",
            "target": "scope", "terminal": "terminal", "text-size": "textformat.size", "trash": "trash",
            "viewport": "viewfinder", "warning": "exclamationmark.triangle", "watch": "clock", "zap": "bolt",
        ]

        /// Tabler alias from `src/lib/icons.ts` → SF Symbol.
        static let tabler: [String: String] = [
            "Activity": "waveform.path.ecg", "AlertCircle": "exclamationmark.circle",
            "AlertTriangle": "exclamationmark.triangle", "Archive": "archivebox", "ArchiveOff": "tray.and.arrow.up",
            "ArrowBarToDown": "arrow.down.to.line", "ArrowBarToUp": "arrow.up.to.line", "ArrowUp": "arrow.up",
            "ArrowUpRight": "arrow.up.right", "AtSign": "at", "AudioLines": "waveform", "Bell": "bell",
            "Book": "book", "Brain": "brain", "Check": "checkmark", "CheckCircle2": "checkmark.circle",
            "ChevronDown": "chevron.down", "ChevronLeft": "chevron.left", "ChevronRight": "chevron.right",
            "ChevronUp": "chevron.up", "CircleLetterA": "a.circle", "Clipboard": "clipboard", "Clock": "clock",
            "Cloud": "cloud", "Command": "command", "Copy": "doc.on.doc", "CornerDownLeft": "return",
            "Download": "arrow.down.to.line", "ExternalLink": "arrow.up.right.square", "Eye": "eye",
            "EyeOff": "eye.slash", "FileText": "doc.text", "FolderOpen": "folder",
            "GitBranch": "arrow.triangle.branch", "GitFork": "arrow.triangle.branch", "Globe": "globe",
            "Hash": "number", "ImageIcon": "photo", "Info": "info.circle", "KeyRound": "key",
            "Layers3": "square.3.layers.3d", "LayoutDashboard": "square.grid.2x2", "Link": "link", "Lock": "lock",
            "MessageCircle": "bubble.left", "MessageQuestion": "questionmark.bubble",
            "MessageSquareText": "text.bubble", "Mic": "mic", "MicOff": "mic.slash", "Monitor": "desktopcomputer",
            "MoreHorizontal": "ellipsis", "MoreVertical": "ellipsis", "Network": "network",
            "Package": "shippingbox", "PanelBottom": "rectangle.bottomthird.inset.filled",
            "PanelLeftIcon": "sidebar.left", "Pause": "pause", "Pencil": "pencil", "Pin": "pin", "Play": "play",
            "Plug": "powerplug", "Plus": "plus", "Power": "power", "RefreshCw": "arrow.clockwise",
            "Search": "magnifyingglass", "Send": "paperplane", "Settings": "gearshape",
            "SlidersHorizontal": "slider.horizontal.3", "SmilePlusIcon": "face.smiling", "Square": "square",
            "SteeringWheel": "steeringwheel", "StopFilled": "stop.fill", "Terminal": "terminal", "Trash2": "trash",
            "Upload": "square.and.arrow.up", "Users": "person.2", "Volume2": "speaker.wave.2",
            "VolumeX": "speaker.slash", "Wrench": "wrench.and.screwdriver", "X": "xmark", "Zap": "bolt",
            "ZapFilled": "bolt.fill", "ZoomIn": "plus.magnifyingglass", "ZoomOut": "minus.magnifyingglass",
        ]

        /// The SF Symbol for a codicon name; the desktop falls back to `plug` for unknown platform glyphs.
        static func symbol(codicon name: String) -> String {
            codicons[name] ?? "powerplug"
        }
    }

    // MARK: Palette

    /// One mode of the `nous` preset (theme-presets.ts) plus the per-mode knobs from styles.css.
    struct Palette {
        var isDark: Bool
        var background, foreground, card, muted, popover: RGBA
        var primary, primaryForeground, secondary, secondaryForeground, accent, accentForeground: RGBA
        var border, input, ring, midground, destructive, destructiveForeground: RGBA
        var sidebarBackground, sidebarBorder, userBubble, userBubbleBorder: RGBA
        /// `--theme-neutral-*` and `--theme-mix-*`: how much of each seed survives against a neutral.
        /// `--theme-mix-sidebar` is 100%, so the sidebar is its seed.
        var neutralChrome, neutralCard: RGBA
        var mixChrome, mixCard, mixElevated, mixBubble: Double
        var red, orange, yellow, green, cyan, blue, purple, success, attention: RGBA

        var chrome: RGBA { background.mixed(mixChrome, with: neutralChrome) }
        var editor: RGBA { card.mixed(mixCard, with: neutralCard) }
        var elevated: RGBA { popover.mixed(mixElevated, with: neutralCard) }
        var bubble: RGBA { userBubble.mixed(mixBubble, with: neutralCard) }

        /// `color-mix(in srgb, accent a, color-mix(in srgb, base b, transparent))`.
        func tint(accent: Double, base: Double) -> RGBA {
            midground.mixed(accent, with: foreground.opacity(base))
        }

        static let light = Palette(
            isDark: false,
            background: 0xffffff, foreground: 0x1f2328, card: 0xf6f8fa, muted: 0xf6f6f6, popover: 0xffffff,
            primary: 0x0053fd, primaryForeground: 0xffffff, secondary: 0xdeeaff, secondaryForeground: 0x1f2328,
            accent: 0xe3edff, accentForeground: 0x1f2328,
            border: 0xd0d7de, input: 0xffffff, ring: 0x0053fd, midground: 0x0053fd,
            destructive: 0xcf222e, destructiveForeground: 0xffffff,
            sidebarBackground: 0xf6f8fa, sidebarBorder: 0xd0d7de, userBubble: 0xdae7fd, userBubbleBorder: 0xd0d7de,
            neutralChrome: 0xf3f3f3, neutralCard: 0xfcfcfc,
            mixChrome: 0.92, mixCard: 0.22, mixElevated: 0.28, mixBubble: 0,
            red: 0xcf2d56, orange: 0xdb704b, yellow: 0xc08532, green: 0x1f8a65, cyan: 0x4c7f8c, blue: 0x0053fd,
            purple: 0x9e94d5, success: 0x00b5aa, attention: 0xf69e00
        )

        static let dark = Palette(
            isDark: true,
            background: 0x0d1117, foreground: 0xe6edf3, card: 0x010409, muted: 0x1a1e24, popover: 0x161b22,
            primary: 0x4a84fe, primaryForeground: 0x161616, secondary: 0x1d2e4f, secondaryForeground: 0xe6edf3,
            accent: 0x17243a, accentForeground: 0xe6edf3,
            border: 0x30363d, input: 0x0d1117, ring: 0x4a84fe, midground: 0x4a84fe,
            destructive: 0xf85149, destructiveForeground: 0xffffff,
            sidebarBackground: 0x010409, sidebarBorder: 0x30363d, userBubble: 0x07162c, userBubbleBorder: 0x30363d,
            neutralChrome: 0x0d0d0e, neutralCard: 0x161618,
            mixChrome: 0.74, mixCard: 0.38, mixElevated: 0.46, mixBubble: 0.46,
            red: 0xe75e78, orange: 0xdb704b, yellow: 0xc08532, green: 0x55a583, cyan: 0x6f9ba6, blue: 0x0053fd,
            purple: 0x9e94d5, success: 0x00b5ab, attention: 0xf69e00
        )
    }

    /// sRGB with straight alpha. `mixed` follows CSS `color-mix(in srgb, …)`, which interpolates
    /// premultiplied, so mixing with a translucent color also mixes alpha.
    struct RGBA: ExpressibleByIntegerLiteral {
        var red, green, blue, alpha: Double

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        init(integerLiteral hex: UInt32) {
            self.init(red: Double((hex >> 16) & 0xff) / 255,
                      green: Double((hex >> 8) & 0xff) / 255,
                      blue: Double(hex & 0xff) / 255)
        }

        static let black: RGBA = 0x000000
        static let white: RGBA = 0xffffff

        func opacity(_ amount: Double) -> RGBA {
            RGBA(red: red, green: green, blue: blue, alpha: alpha * amount)
        }

        /// `color-mix(in srgb, self amount, other)`.
        func mixed(_ amount: Double, with other: RGBA) -> RGBA {
            let selfWeight = alpha * amount, otherWeight = other.alpha * (1 - amount)
            let total = selfWeight + otherWeight
            guard total > 0 else { return RGBA(red: 0, green: 0, blue: 0, alpha: 0) }
            func channel(_ a: Double, _ b: Double) -> Double { (a * selfWeight + b * otherWeight) / total }
            return RGBA(red: channel(red, other.red), green: channel(green, other.green),
                        blue: channel(blue, other.blue), alpha: total)
        }

        var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    }

    /// A color that follows the trait collection's light/dark style.
    private static func color(_ token: (Palette) -> RGBA) -> Color {
        let light = token(.light).uiColor, dark = token(.dark).uiColor
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - Modifiers

extension View {
    /// A token hairline along `edges` (default: the in-panel divider, `--ui-stroke-tertiary`).
    func hermesHairline(_ color: Color = Theme.Hairline.tertiary, edges: Edge.Set = .bottom) -> some View {
        modifier(HairlineModifier(color: color, edges: edges))
    }

    /// A bordered transcript surface (tables, code fences, attachments): no fill, tertiary hairline.
    func hermesOutline(radius: CGFloat = Theme.Radius.bubble) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Theme.Hairline.tertiary, lineWidth: Theme.hairlineWidth)
        }
    }

    /// The inline widget shell (`WIDGET_SHELL_CLASS`): widget fill, widget radius, no border.
    /// Its actions belong outside the card, below it.
    func hermesCard(padded: Bool = true) -> some View {
        padding(.horizontal, padded ? 14 : 0)
            .padding(.vertical, padded ? Theme.Spacing.lg : 0)
            .background(Theme.widget, in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
    }

    /// The user message bubble: bubble fill, 1 pt border, 12 × 8 pt padding.
    func hermesBubble() -> some View {
        padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                    .strokeBorder(Theme.userBubbleBorder, lineWidth: Theme.hairlineWidth)
            }
    }

    /// A floating panel (`shadow-nous` + `--stroke-nous`): popover fill, overlay hairline and a
    /// downward layered shadow. SwiftUI shadows have no spread, so the layers only approximate the CSS.
    func hermesFloating(radius: CGFloat = Theme.Radius.bubble) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius)
                .fill(Theme.popover)
                .shadow(color: .black.opacity(0.07), radius: 2, y: 2)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 8)
                .shadow(color: .black.opacity(0.06), radius: 14, y: 20)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Theme.Hairline.overlay, lineWidth: Theme.hairlineWidth)
        }
    }

    /// Font and line height of a `Theme.TextStyle`, scaled with Dynamic Type.
    func hermesText(_ style: Theme.TextStyle) -> some View {
        modifier(TextStyleModifier(style: style))
    }

    /// A form page (sign-in, settings): rows on the page background over the sidebar tone, token hairlines.
    func hermesForm() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.sidebar)
    }

    /// A form section's rows (`hermesForm`).
    func hermesFormRows() -> some View {
        listRowBackground(Theme.background)
            .listRowSeparatorTint(Theme.Hairline.secondary)
    }
}

/// A form section's header or footer text.
struct FormNote: View {
    let text: String
    var color: Color = Theme.Text.tertiary

    init(_ text: String, color: Color = Theme.Text.tertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(LocalizedStringKey(text))
            .hermesText(.caption)
            .foregroundStyle(color)
            .textCase(nil)
    }
}

private struct HairlineModifier: ViewModifier {
    let color: Color
    let edges: Edge.Set

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { if edges.contains(.top) { line.frame(height: Theme.hairlineWidth) } }
            .overlay(alignment: .bottom) { if edges.contains(.bottom) { line.frame(height: Theme.hairlineWidth) } }
            .overlay(alignment: .leading) { if edges.contains(.leading) { line.frame(width: Theme.hairlineWidth) } }
            .overlay(alignment: .trailing) { if edges.contains(.trailing) { line.frame(width: Theme.hairlineWidth) } }
    }

    private var line: some View { color.allowsHitTesting(false) }
}

private struct TextStyleModifier: ViewModifier {
    let style: Theme.TextStyle
    @ScaledMetric private var size: CGFloat

    init(style: Theme.TextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        let lineHeight = style.lineHeight * size / style.size
        let natural = style.monospaced
            ? UIFont.monospacedSystemFont(ofSize: size, weight: .regular).lineHeight
            : UIFont.systemFont(ofSize: size).lineHeight
        content
            .font(style.font(size: size))
            .lineSpacing(max(0, lineHeight - natural))
    }
}
