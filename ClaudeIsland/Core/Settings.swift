//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds — 8-bit game-style sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case coin = "Coin"
    case blip = "Blip"
    case jump = "Jump"
    case powerUp = "Power Up"
    case menuOpen = "Menu Open"

    var bitSound: BitSound? {
        switch self {
        case .none: return nil
        case .coin: return .coin
        case .blip: return .blip
        case .jump: return .jump
        case .powerUp: return .powerUp
        case .menuOpen: return .menuOpen
        }
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .coin // Default to Coin
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }
}
