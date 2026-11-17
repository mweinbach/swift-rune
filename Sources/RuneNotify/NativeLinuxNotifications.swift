#if os(Linux)
import CRuneNotify
import Dispatch
import Foundation

/// Talks to the session's freedesktop notification service and receives its action signals.
final class NativeLinuxNotifications: NotificationBackend, @unchecked Sendable {
    static let shared = NativeLinuxNotifications()
    private init() {}

    private struct ServerID: Hashable {
        var owner: String
        var number: UInt32
    }

    private struct Delivery {
        var notification: Notification
        var token: String?
    }

    private struct State {
        var client: OpaquePointer?
        var identity: NotificationIdentity?
        var byName: [String: ServerID] = [:]
        var delivered: [ServerID: Delivery] = [:]
        var handler: (@Sendable (NotificationClick) -> Void)?
        var lastActionToken: String?

        mutating func forget(_ serverID: ServerID) {
            guard let delivery = delivered.removeValue(forKey: serverID),
                  byName[delivery.notification.id] == serverID else { return }
            byName.removeValue(forKey: delivery.notification.id)
        }

        mutating func connection() -> OpaquePointer? {
            if let current = client, rune_notify_linux_connected(current) == 0 {
                client = nil
                delivered.removeAll()
                byName.removeAll()
                lastActionToken = nil
                // A retiring signal callback may be waiting on the state lock.
                let address = UInt(bitPattern: current)
                DispatchQueue.global().async { rune_notify_linux_disconnect(OpaquePointer(bitPattern: address)) }
            }
            if client == nil {
                client = rune_notify_linux_connect { origin, kind, owner, number, value in
                    guard let owner, let origin else { return }
                    NativeLinuxNotifications.shared.receive(from: origin, kind: kind,
                        serverID: ServerID(owner: String(cString: owner), number: number),
                        value: value.map(String.init(cString:)) ?? "")
                }
            }
            return client
        }
    }

    private let state = NotifyLock(initialState: State())
    private let deliveryQueue = DispatchQueue(label: "dev.rune.notifications.actions")

    var isAvailable: Bool {
        state.withLock { state in rune_notify_linux_available(state.connection()) != 0 }
    }

    var isAppFocused: Bool {
        rune_notify_linux_app_focused() != 0
    }

    func bringToFront() {
        let token = state.withLock { state in
            let token = state.lastActionToken
            state.lastActionToken = nil
            return token
        }
        rune_notify_linux_bring_to_front(token)
    }

    func register(_ identity: NotificationIdentity) -> Result<Void, NotificationError> { adopt(identity) }

    func adopt(_ identity: NotificationIdentity) -> Result<Void, NotificationError> {
        guard !identity.id.isEmpty, !identity.id.utf8.contains(0) else {
            return .failure(.message("Invalid notification application identifier"))
        }
        state.withLock { $0.identity = identity }
        return .success(())
    }

    func post(_ note: Notification) -> Bool {
        state.withLock { state in
            guard let client = state.connection() else { return false }
            let identity = state.identity
            let title = identity?.name.isEmpty == false ? identity?.name : identity?.id
            let urgency: UInt8 = switch note.urgency {
            case .passive: 0
            case .active: 1
            case .timeSensitive, .critical: 2
            }
            let sound = if case .named(let name) = note.sound { name } else { "" }
            let body = [note.subtitle ?? "", note.body].filter { !$0.isEmpty }.joined(separator: "\n")
            guard let request = rune_notify_linux_message(title ?? ProcessInfo.processInfo.processName,
                identity?.id ?? "", identity?.iconPath ?? "", note.title, body, urgency,
                note.sound == .none ? 1 : 0, sound, note.categoryIdentifier ?? "") else { return false }
            defer { rune_notify_linux_message_free(request) }
            for (index, action) in note.actions.enumerated() {
                // Keep caller IDs distinct from the protocol's reserved "default" and "inline-reply".
                let key = "rune-\(index)"
                switch action {
                case .button(_, let label): rune_notify_linux_action(request, key, label, nil)
                case .reply(_, let placeholder, let label): rune_notify_linux_action(request, key, label, placeholder)
                }
            }
            var owner: UnsafeMutablePointer<CChar>?
            let old = state.byName[note.id]
            let number = rune_notify_linux_post(client, request, old?.owner, old?.number ?? 0, &owner)
            guard let owner, number != 0 else { return false }
            defer { rune_notify_linux_free_string(owner) }
            let serverID = ServerID(owner: String(cString: owner), number: number)
            if let old { state.forget(old) }
            state.byName[note.id] = serverID
            state.delivered[serverID] = Delivery(notification: note)
            return true
        }
    }

    func remove(ids: [String]) {
        state.withLock { state in
            guard let client = state.client else { return }
            for name in ids {
                if let key = state.byName[name], rune_notify_linux_remove(client, key.owner, key.number) != 0 {
                    state.forget(key)
                }
            }
        }
    }

    func setClickHandler(_ handler: (@Sendable (NotificationClick) -> Void)?) {
        state.withLock { $0.handler = handler }
    }

    private func receive(from client: OpaquePointer, kind: Int32, serverID: ServerID, value: String) {
        state.withLock { state in
            guard state.client == client else { return }
            if kind == Int32(RUNE_NOTIFY_SERVER_GONE.rawValue) {
                for key in state.delivered.keys.filter({ $0.owner == serverID.owner }) { state.forget(key) }
                return
            }
            guard let delivery = state.delivered[serverID] else { return }
            if kind == Int32(RUNE_NOTIFY_CLOSED.rawValue) {
                state.forget(serverID)
                return
            }
            if kind == Int32(RUNE_NOTIFY_ACTIVATION_TOKEN.rawValue) {
                state.delivered[serverID]?.token = value
                return
            }
            var info = delivery.notification.info
            if kind == Int32(RUNE_NOTIFY_REPLIED.rawValue) {
                guard let action = delivery.notification.actions.first(where: {
                    if case .reply = $0 { return true }
                    return false
                }) else { return }
                info.append((RuneNotifyConstants.inputPrefix + action.id, value))
                info.append((RuneNotifyConstants.actionKey, action.id))
            } else if kind == Int32(RUNE_NOTIFY_ACTION.rawValue), value != "default" {
                guard value.hasPrefix("rune-"), let index = Int(value.dropFirst(5)),
                      delivery.notification.actions.indices.contains(index),
                      case let .button(id, _) = delivery.notification.actions[index] else { return }
                info.append((RuneNotifyConstants.actionKey, id))
            }
            guard let handler = state.handler else { return }
            let click = NotificationClick(id: delivery.notification.id, info: info)
            deliveryQueue.async { [self] in
                self.state.withLock { $0.lastActionToken = delivery.token }
                handler(click)
            }
        }
    }
}
#endif
