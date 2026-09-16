import OperatorCore

@MainActor
final class ForegroundNodeCommandRouter: GatewayNodeCommandHandler {
    private let location: any GatewayNodeCommandHandler
    private let calendar: any GatewayNodeCommandHandler
    private let reminders: (any GatewayNodeCommandHandler)?
    private let contacts: (any GatewayNodeCommandHandler)?
    private let photos: (any GatewayNodeCommandHandler)?
    private let music: (any GatewayNodeCommandHandler)?
    private let weather: (any GatewayNodeCommandHandler)?
    private let device: (any GatewayNodeCommandHandler)?
    private let messages: any GatewayNodeCommandHandler
    private let messageSend: (any GatewayNodeCommandHandler)?
    private let maps: any GatewayNodeCommandHandler
    private let handoff: any GatewayNodeCommandHandler
    private let whatsapp: any GatewayNodeCommandHandler
    private let whatsappCompose: any GatewayNodeCommandHandler
    private let accounts: any GatewayNodeCommandHandler
    private let accountWrite: any GatewayNodeCommandHandler
    private let discovery: (any GatewayNodeCommandHandler)?
    private let notion: any GatewayNodeCommandHandler
    private let media: (any GatewayNodeCommandHandler)?
    private let discord: (any GatewayNodeCommandHandler)?
    private let incomingMessages: (any GatewayNodeCommandHandler)?
    private let contactCreate: (any GatewayNodeCommandHandler)?

    init(
        location: any GatewayNodeCommandHandler,
        calendar: any GatewayNodeCommandHandler,
        reminders: (any GatewayNodeCommandHandler)? = nil,
        contacts: (any GatewayNodeCommandHandler)? = nil,
        photos: (any GatewayNodeCommandHandler)? = nil,
        music: (any GatewayNodeCommandHandler)? = nil,
        weather: (any GatewayNodeCommandHandler)? = nil,
        device: (any GatewayNodeCommandHandler)? = nil,
        messages: any GatewayNodeCommandHandler,
        messageSend: (any GatewayNodeCommandHandler)? = nil,
        maps: any GatewayNodeCommandHandler,
        handoff: any GatewayNodeCommandHandler,
        whatsapp: any GatewayNodeCommandHandler,
        whatsappCompose: any GatewayNodeCommandHandler,
        accounts: any GatewayNodeCommandHandler,
        accountWrite: any GatewayNodeCommandHandler,
        discovery: (any GatewayNodeCommandHandler)? = nil,
        media: (any GatewayNodeCommandHandler)? = nil,
        notion: any GatewayNodeCommandHandler,
        discord: (any GatewayNodeCommandHandler)? = nil,
        incomingMessages: (any GatewayNodeCommandHandler)? = nil,
        contactCreate: (any GatewayNodeCommandHandler)? = nil)
    {
        self.location = location
        self.calendar = calendar
        self.reminders = reminders
        self.contacts = contacts
        self.photos = photos
        self.music = music
        self.weather = weather
        self.device = device
        self.messages = messages
        self.messageSend = messageSend
        self.maps = maps
        self.handoff = handoff
        self.whatsapp = whatsapp
        self.whatsappCompose = whatsappCompose
        self.accounts = accounts
        self.accountWrite = accountWrite
        self.discovery = discovery
        self.media = media
        self.notion = notion
        self.discord = discord
        self.incomingMessages = incomingMessages
        self.contactCreate = contactCreate
    }

    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        switch command {
        case "location.get":
            await self.location.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "calendar.events":
            await self.calendar.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "reminders.list":
            if let reminders {
                await reminders.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "contacts.search":
            if let contacts {
                await contacts.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "photos.latest":
            if let photos {
                await photos.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "music.nowPlaying", "music.search":
            if let music {
                await music.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "weather.forecast":
            if let weather {
                await weather.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "device.status":
            if let device {
                await device.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "sms.compose":
            await self.messages.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "sms.send":
            if let messageSend {
                await messageSend.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "maps.search", "maps.directions":
            await self.maps.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "apps.open":
            await self.handoff.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "whatsapp.chats", "whatsapp.messages", "whatsapp.sync":
            await self.whatsapp.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "whatsapp.compose":
            await self.whatsappCompose.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "connections.read":
            await self.accounts.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "connections.write":
            await self.accountWrite.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "connections.describe":
            if let discovery {
                await discovery.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "notion.tools", "notion.call":
            await self.notion.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
        case "youtube.search", "youtube.open", "podcasts.search", "podcasts.open":
            if let media {
                await media.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "discord.announcements":
            if let discord {
                await discord.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "contacts.create":
            if let contactCreate {
                await contactCreate.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        case "messages.incoming":
            if let incomingMessages {
                await incomingMessages.handleNodeCommand(command, paramsJSON: paramsJSON, timeoutMilliseconds: timeoutMilliseconds)
            } else {
                .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
            }
        default:
            .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
    }
}
