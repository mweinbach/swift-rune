import Foundation

/// Constants shared between notification posting and click handling.
public enum RuneNotifyConstants {
    /// User-info key carrying the clicked action identifier.
    public static let actionKey = "rune.action"
    /// User-info key prefix carrying text entered into a reply action.
    public static let inputPrefix = "rune.input."
}

/// Interactive action attached to a notification.
public enum NotificationAction: Sendable, Equatable, Hashable {
    /// A button whose click delivers `id` without bringing the app forward.
    case button(id: String, label: String)
    /// A text input field with a send button.
    case reply(id: String, placeholder: String, label: String)

    public var id: String {
        switch self {
        case .button(let id, _), .reply(let id, _, _):
            return id
        }
    }
}

/// Sound behavior for a notification.
public enum NotificationSound: Sendable, Equatable, Hashable {
    /// Silent notification (default).
    case none
    /// System default notification sound.
    case `default`
    /// Custom named sound in the app bundle or system sounds.
    case named(String)
}

/// Interruption / urgency level for a notification.
public enum NotificationUrgency: Sendable, Equatable, Hashable {
    /// Added to Notification Center without lighting up the screen or playing a sound.
    case passive
    /// Standard banner / alert presentation.
    case active
    /// Breaks through Focus / Do Not Disturb when permitted.
    case timeSensitive
    /// Critical alert (requires entitlement on Apple platforms).
    case critical
}

/// A notification to post, built with fluent setters.
public struct Notification: Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var body: String
    public var info: [(String, String)]
    public var actions: [NotificationAction]
    public var sound: NotificationSound
    public var urgency: NotificationUrgency
    public var categoryIdentifier: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        body: String = "",
        info: [(String, String)] = [],
        actions: [NotificationAction] = [],
        sound: NotificationSound = .none,
        urgency: NotificationUrgency = .active,
        categoryIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.info = info
        self.actions = actions
        self.sound = sound
        self.urgency = urgency
        self.categoryIdentifier = categoryIdentifier
    }

    public static func == (lhs: Notification, rhs: Notification) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle
            && lhs.body == rhs.body
            && lhs.info.count == rhs.info.count
            && zip(lhs.info, rhs.info).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.actions == rhs.actions
            && lhs.sound == rhs.sound
            && lhs.urgency == rhs.urgency
            && lhs.categoryIdentifier == rhs.categoryIdentifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(body)
        for (k, v) in info {
            hasher.combine(k)
            hasher.combine(v)
        }
        hasher.combine(actions)
        hasher.combine(sound)
        hasher.combine(urgency)
        hasher.combine(categoryIdentifier)
    }

    public func subtitle(_ subtitle: String?) -> Notification {
        var copy = self
        copy.subtitle = subtitle
        return copy
    }

    public func body(_ body: String) -> Notification {
        var copy = self
        copy.body = body
        return copy
    }

    public func info(_ key: String, _ value: String) -> Notification {
        var copy = self
        copy.info.append((key, value))
        return copy
    }

    public func action(id: String, label: String) -> Notification {
        var copy = self
        copy.actions.append(.button(id: id, label: label))
        return copy
    }

    public func reply(id: String, placeholder: String, label: String) -> Notification {
        var copy = self
        copy.actions.append(.reply(id: id, placeholder: placeholder, label: label))
        return copy
    }

    public func sound(_ sound: NotificationSound) -> Notification {
        var copy = self
        copy.sound = sound
        return copy
    }

    public func urgency(_ urgency: NotificationUrgency) -> Notification {
        var copy = self
        copy.urgency = urgency
        return copy
    }

    public func category(_ identifier: String?) -> Notification {
        var copy = self
        copy.categoryIdentifier = identifier
        return copy
    }
}

/// A user click or action response on a delivered notification.
public struct NotificationClick: Sendable, Equatable {
    public var id: String
    public var info: [(String, String)]

    public init(id: String, info: [(String, String)] = []) {
        self.id = id
        self.info = info
    }

    public static func == (lhs: NotificationClick, rhs: NotificationClick) -> Bool {
        lhs.id == rhs.id
            && lhs.info.count == rhs.info.count
            && zip(lhs.info, rhs.info).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// Returns the user-info value for `key`.
    public func get(_ key: String) -> String? {
        info.first(where: { $0.0 == key })?.1
    }

    /// The action button or reply identifier clicked, or `nil` for the default notification tap.
    public var action: String? {
        self.get(RuneNotifyConstants.actionKey)
    }

    /// Text typed into the reply box `id`, if any.
    public func input(for id: String) -> String? {
        let targetKey = RuneNotifyConstants.inputPrefix + id
        return info.first(where: { $0.0 == targetKey })?.1
    }
}

/// App identity used for notification registration.
public struct NotificationIdentity: Sendable, Equatable {
    public var id: String
    public var name: String
    public var iconPath: String?
    public var activationScheme: String?

    public init(
        id: String,
        name: String,
        iconPath: String? = nil,
        activationScheme: String? = nil
    ) {
        self.id = id
        self.name = name
        self.iconPath = iconPath
        self.activationScheme = activationScheme
    }

    public func icon(_ path: String) -> NotificationIdentity {
        var copy = self
        copy.iconPath = path
        return copy
    }

    public func activation(_ scheme: String) -> NotificationIdentity {
        var copy = self
        copy.activationScheme = scheme
        return copy
    }
}

/// Error returned by notification registration or activation serving calls.
public enum NotificationError: Error, Sendable, Equatable, CustomStringConvertible {
    case message(String)

    public var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}
