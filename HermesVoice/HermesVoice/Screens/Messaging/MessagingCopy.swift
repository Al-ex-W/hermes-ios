import SwiftUI

/// What the Messaging and Webhooks screens talk to: the dashboard, for one profile. `profile` nil is the dashboard's
/// own profile (also what the sidebar's "all profiles" scope configures).
struct MessagingContext {
    let client: DashboardClient
    let profile: String?

    init(client: DashboardClient, profile: String?) {
        self.client = client
        self.profile = profile
    }

    /// From the sidebar's scope: a profile name, or `SidebarOptions.allProfiles` (the dashboard's own profile).
    init(client: DashboardClient, profileScope: String) {
        self.init(client: client, profile: profileScope == SidebarOptions.allProfiles ? nil : profileScope)
    }

    func messaging(profile: String?) -> MessagingAPI { MessagingAPI(transport: client, profile: profile) }
    var webhooks: WebhooksAPI { WebhooksAPI(transport: client, profile: profile) }
}

/// The desktop's Messaging copy (`i18n/en.ts` › `messaging`): state names, field labels and setup intros.
enum MessagingCopy {
    static let states: [String: String] = [
        "connected": "Connected",
        "connecting": "Connecting",
        "disabled": "Disabled",
        "fatal": "Error",
        "gateway_stopped": "Messaging gateway stopped",
        "not_configured": "Needs setup",
        "pending_restart": "Restart needed",
        "retrying": "Retrying",
        "startup_failed": "Startup failed",
    ]

    /// A state's label; an unknown one reads with spaces for underscores.
    static func stateLabel(_ state: String?) -> String {
        guard let state, !state.isEmpty else { return "Unknown" }
        return states[state] ?? state.replacingOccurrences(of: "_", with: " ")
    }

    struct FieldCopy {
        var label: String?
        var help: String?
        var placeholder: String?
    }

    /// `FIELD_COPY`: fields tucked under Advanced whatever the backend says.
    static let advancedKeys: Set<String> = [
        "TELEGRAM_PROXY", "DISCORD_REPLY_TO_MODE", "DISCORD_ALLOW_ALL_USERS", "DISCORD_HOME_CHANNEL",
        "DISCORD_HOME_CHANNEL_NAME", "BLUEBUBBLES_ALLOW_ALL_USERS", "MATTERMOST_ALLOW_ALL_USERS", "MATTERMOST_HOME_CHANNEL",
        "QQ_ALLOW_ALL_USERS", "QQBOT_HOME_CHANNEL", "QQBOT_HOME_CHANNEL_NAME", "WHATSAPP_ENABLED", "WHATSAPP_MODE",
    ]

    static let fieldCopy: [String: FieldCopy] = [
        "TELEGRAM_BOT_TOKEN": FieldCopy(label: "Bot token",
                                        help: "Create a bot with @BotFather, then paste the token it gives you.",
                                        placeholder: "Paste Telegram bot token"),
        "TELEGRAM_ALLOWED_USERS": FieldCopy(label: "Allowed Telegram user IDs",
                                            help: "Recommended. Numeric IDs from @userinfobot, one per box. Without this, anyone can DM your bot."),
        "TELEGRAM_PROXY": FieldCopy(label: "Proxy URL", help: "Only needed on networks where Telegram is blocked."),
        "DISCORD_BOT_TOKEN": FieldCopy(label: "Bot token",
                                       help: "Create an application in the Discord Developer Portal, add a bot, then paste its token."),
        "DISCORD_ALLOWED_USERS": FieldCopy(label: "Allowed Discord user IDs", help: "Recommended. Discord user IDs, one per box."),
        "DISCORD_REPLY_TO_MODE": FieldCopy(label: "Reply style", help: "first, all, or off."),
        "DISCORD_ALLOW_ALL_USERS": FieldCopy(label: "Allow all Discord users",
                                             help: "Development only. When true, anyone can DM the bot without an allowlist."),
        "DISCORD_HOME_CHANNEL": FieldCopy(label: "Home channel ID",
                                          help: "Channel where the bot sends proactive messages (cron output, reminders)."),
        "DISCORD_HOME_CHANNEL_NAME": FieldCopy(label: "Home channel name",
                                               help: "Display name for the home channel in logs and status output."),
        "BLUEBUBBLES_ALLOW_ALL_USERS": FieldCopy(label: "Allow all iMessage users", help: "When true, skip the BlueBubbles allowlist."),
        "MATTERMOST_ALLOW_ALL_USERS": FieldCopy(label: "Allow all Mattermost users"),
        "MATTERMOST_HOME_CHANNEL": FieldCopy(label: "Home channel"),
        "QQ_ALLOW_ALL_USERS": FieldCopy(label: "Allow all QQ users"),
        "QQBOT_HOME_CHANNEL": FieldCopy(label: "QQ home channel", help: "Default channel or group for cron delivery."),
        "QQBOT_HOME_CHANNEL_NAME": FieldCopy(label: "QQ home channel name"),
        "SLACK_BOT_TOKEN": FieldCopy(label: "Slack bot token",
                                     help: "Use the bot token from OAuth & Permissions after installing your Slack app.",
                                     placeholder: "Paste Slack bot token"),
        "SLACK_APP_TOKEN": FieldCopy(label: "Slack app token", help: "Use the app-level token required for Socket Mode.",
                                     placeholder: "Paste Slack app token"),
        "SLACK_ALLOWED_USERS": FieldCopy(label: "Allowed Slack user IDs", help: "Recommended. Slack user IDs, one per box."),
        "MATTERMOST_URL": FieldCopy(label: "Server URL", placeholder: "https://mattermost.example.com"),
        "MATTERMOST_TOKEN": FieldCopy(label: "Bot token"),
        "MATTERMOST_ALLOWED_USERS": FieldCopy(label: "Allowed user IDs", help: "Recommended. Mattermost user IDs, one per box."),
        "MATRIX_HOMESERVER": FieldCopy(label: "Homeserver URL", placeholder: "https://matrix.org"),
        "MATRIX_ACCESS_TOKEN": FieldCopy(label: "Access token"),
        "MATRIX_USER_ID": FieldCopy(label: "Bot user ID", placeholder: "@hermes:example.org"),
        "MATRIX_ALLOWED_USERS": FieldCopy(label: "Allowed Matrix user IDs",
                                          help: "Recommended. User IDs in @user:server format, one per box."),
        "SIGNAL_HTTP_URL": FieldCopy(label: "Signal bridge URL", help: "URL of a running signal-cli REST bridge.",
                                     placeholder: "http://127.0.0.1:8080"),
        "SIGNAL_ACCOUNT": FieldCopy(label: "Phone number", help: "The number registered with your signal-cli bridge."),
        "SIGNAL_ALLOWED_USERS": FieldCopy(label: "Allowed Signal users", help: "Recommended. Signal identifiers, one per box."),
        "WHATSAPP_ENABLED": FieldCopy(label: "Enable WhatsApp bridge",
                                      help: "Set automatically by the Enabled switch. Leave alone unless you know you need it."),
        "WHATSAPP_MODE": FieldCopy(label: "Bridge mode"),
        "WHATSAPP_ALLOWED_USERS": FieldCopy(label: "Allowed WhatsApp users",
                                            help: "Recommended. Phone numbers or WhatsApp IDs, one per box."),
    ]

    /// A field's label, help and placeholder, and whether it sits under Advanced (`fieldCopy`).
    static func copy(_ field: MessagingEnvField) -> (label: String, help: String, placeholder: String, advanced: Bool) {
        let copy = fieldCopy[field.key]
        let prompt = field.prompt.isEmpty ? field.key : field.prompt
        return (copy?.label ?? prompt, copy?.help ?? field.description, copy?.placeholder ?? prompt,
                advancedKeys.contains(field.key) || field.advanced)
    }

    /// `PLATFORM_INTRO`: how to get the credentials, per platform.
    static let platformIntro: [String: String] = [
        "telegram": "In Telegram, talk to @BotFather, run /newbot, and copy the token it gives you. Then grab your numeric user ID from @userinfobot.",
        "discord": "Open the Discord Developer Portal, create an application, add a Bot, then copy its token. Invite the bot to your server with the right scopes.",
        "slack": "Create a Slack app, enable Socket Mode, install it to your workspace, then copy the bot token and app-level token.",
        "mattermost": "On your Mattermost server, create a bot account or personal access token, then paste the server URL and token here.",
        "matrix": "Sign in to your homeserver with the bot account, then copy the access token, user ID, and homeserver URL.",
        "signal": "Run a signal-cli REST bridge somewhere reachable, then point Hermes at the URL and the registered phone number.",
        "whatsapp": "Start the WhatsApp bridge that ships with Hermes, scan the QR code on first run, then enable the platform.",
        "bluebubbles": "Run BlueBubbles Server on a Mac with iMessage, expose its API, then point Hermes at the URL with the server password.",
        "homeassistant": "In Home Assistant, open your profile and create a long-lived access token. Paste it here along with your HA URL.",
        "email": "Use a dedicated mailbox. For Gmail/Workspace, create an app password and use imap.gmail.com / smtp.gmail.com.",
        "sms": "Get your Twilio Account SID and Auth Token from the Twilio console, plus a phone number that can send SMS.",
        "dingtalk": "Create a DingTalk app in the developer console, then copy the Client ID (App key) and Client Secret here.",
        "feishu": "Create a Feishu / Lark app, configure the bot capability, and copy the App ID, App secret, and event encryption keys.",
        "wecom": "Add a group robot in WeCom and copy its webhook key as WECOM_BOT_ID. Send-only — use the WeCom (app) option for two-way.",
        "wecom_callback": "Set up a WeCom self-built app, expose its callback URL, and provide the corp ID, secret, agent ID, and AES key.",
        "weixin": "Run `hermes gateway setup`, select Weixin, then scan and confirm the QR code with a personal WeChat account. Hermes connects through Tencent's iLink Bot API and saves the credentials.",
        "qqbot": "Register an app on the QQ Open Platform (q.qq.com) and copy the App ID and Client Secret.",
        "api_server": "Expose Hermes as an OpenAI-compatible API. Set an auth key, then point Open WebUI / LobeChat / etc. at the host:port.",
        "webhook": "Run an HTTP server that other tools (GitHub, GitLab, custom apps) can POST to. Use the secret to verify signatures.",
    ]

    static func intro(_ platform: MessagingPlatform) -> String {
        platformIntro[platform.id] ?? platform.description
    }
}

extension MessagingTone {
    var pillTone: OpsPill.Tone {
        switch self {
        case .good: return .good
        case .warn: return .warn
        case .bad: return .bad
        case .muted: return .muted
        }
    }

    var color: Color {
        switch self {
        case .good: return Theme.primary
        case .warn: return Theme.Semantic.attention
        case .bad: return Theme.destructive
        case .muted: return Theme.Text.quaternary
        }
    }
}
