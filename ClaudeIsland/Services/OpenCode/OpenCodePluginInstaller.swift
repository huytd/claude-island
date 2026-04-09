//
//  OpenCodePluginInstaller.swift
//  ClaudeIsland
//
//  Installs the opencode-island.js plugin into the user's OpenCode config
//  directory and registers it in opencode.json — the same pattern as
//  HookInstaller does for Claude Code.
//
//  Plugin path:  ~/.config/opencode/opencode-island.js
//  Config path:  ~/.config/opencode/opencode.json
//

import Foundation
import os.log

struct OpenCodePluginInstaller {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "OpenCodePlugin")

    // MARK: - Public API

    static func installIfNeeded() {
        let configDir = openCodeConfigDir()
        let pluginDst = configDir.appendingPathComponent("opencode-island.js")
        let configFile = configDir.appendingPathComponent("opencode.json")

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Copy / refresh the plugin file from the app bundle
        if let bundled = Bundle.main.url(forResource: "opencode-island", withExtension: "js") {
            try? FileManager.default.removeItem(at: pluginDst)
            try? FileManager.default.copyItem(at: bundled, to: pluginDst)
            logger.info("Installed OpenCode plugin to \(pluginDst.path, privacy: .public)")
        } else {
            logger.warning("opencode-island.js not found in app bundle")
        }

        updateConfig(at: configFile, pluginPath: pluginDst.path)
    }

    static func uninstall() {
        let configDir = openCodeConfigDir()
        let pluginDst = configDir.appendingPathComponent("opencode-island.js")
        let configFile = configDir.appendingPathComponent("opencode.json")

        try? FileManager.default.removeItem(at: pluginDst)
        removeFromConfig(at: configFile, pluginPath: pluginDst.path)
        logger.info("Uninstalled OpenCode plugin")
    }

    // MARK: - Config Management

    /// Add the plugin entry to opencode.json if it isn't already there.
    private static func updateConfig(at configURL: URL, pluginPath: String) {
        var json = readConfig(at: configURL)

        // opencode.json uses a "plugin" array of specs (strings or [string, options])
        var plugins = json["plugin"] as? [Any] ?? []

        let pluginEntry = "file://\(pluginPath)"
        let alreadyInstalled = plugins.contains { entry in
            if let s = entry as? String { return s == pluginEntry }
            if let pair = entry as? [Any], let s = pair.first as? String { return s == pluginEntry }
            return false
        }

        guard !alreadyInstalled else { return }

        plugins.append(pluginEntry)
        json["plugin"] = plugins
        writeConfig(json, to: configURL)
        logger.info("Registered OpenCode plugin in opencode.json")
    }

    /// Remove our plugin entry from opencode.json.
    private static func removeFromConfig(at configURL: URL, pluginPath: String) {
        var json = readConfig(at: configURL)
        guard var plugins = json["plugin"] as? [Any] else { return }

        let pluginEntry = "file://\(pluginPath)"
        plugins.removeAll { entry in
            if let s = entry as? String { return s == pluginEntry }
            if let pair = entry as? [Any], let s = pair.first as? String { return s == pluginEntry }
            return false
        }

        if plugins.isEmpty {
            json.removeValue(forKey: "plugin")
        } else {
            json["plugin"] = plugins
        }
        writeConfig(json, to: configURL)
    }

    // MARK: - Helpers

    private static func openCodeConfigDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("opencode")
    }

    private static func readConfig(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func writeConfig(_ json: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: url)
    }
}
