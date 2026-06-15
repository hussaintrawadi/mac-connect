import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case searching
    case connecting
    case connected(deviceName: String)
    case reconnecting

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
