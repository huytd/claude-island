//
//  OpenCodeSocketServer.swift
//  ClaudeIsland
//
//  Unix domain socket server that receives events from the opencode-island.js
//  plugin running inside OpenCode. Mirrors HookSocketServer's design but uses
//  the OpenCode event protocol.
//
//  Socket path: /tmp/opencode-island.sock
//
//  Incoming message shapes (all single-line JSON):
//    { "hook": "event",          "type": "session.created", "sessionID": "…", "info": {…} }
//    { "hook": "event",          "type": "session.status",  "sessionID": "…", "status": "…" }
//    { "hook": "PreToolUse",     "session_id": "…", "tool": "…", "call_id": "…", "args": {…} }
//    { "hook": "PostToolUse",    "session_id": "…", "tool": "…", "call_id": "…", "result": "…" }
//    { "hook": "PermissionRequest", "session_id": "…", "permission": "…",
//                                   "permission_id": "…", "call_id": "…", "patterns": […] }
//
//  Response for PermissionRequest (Claude Island → plugin):
//    { "decision": "allow" | "deny" }
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "OpenCodeSocket")

// MARK: - Event Models

/// A raw event received from the OpenCode plugin.
struct OCPluginEvent: Codable, Sendable {
    // Present on every message
    let hook: String

    // For "event" hook — the bus event type (e.g., "session.created")
    let type: String?

    // Session ID sent by the plugin (snake_case from tool hooks)
    let sessionId: String?
    // Session ID as emitted inside bus events (camelCase)
    let sessionID: String?

    // Resolved session ID (plugin sends snake_case; event payloads use camelCase)
    var resolvedSessionId: String { sessionId ?? sessionID ?? "" }

    // "event" hook — nested session info (path, title, status …)
    let info: [String: AnyCodable]?
    // "event" hook — top-level status field (session.status / session.idle)
    let status: String?

    // Tool hooks
    let tool: String?
    let callId: String?    // call_id from plugin
    let args: AnyCodable?
    let result: String?

    // PermissionRequest
    let permissionId: String?  // permission_id
    let permission: String?
    let patterns: [String]?

    enum CodingKeys: String, CodingKey {
        case hook, type, sessionID, info, status, tool, args, result, permission, patterns
        case sessionId     = "session_id"
        case callId        = "call_id"
        case permissionId  = "permission_id"
    }
}

/// Decision sent back to the plugin for a PermissionRequest.
struct OCPermissionResponse: Codable {
    let decision: String  // "allow" | "deny"
}

/// Pending permission waiting for the user to approve/deny.
struct OCPendingPermission: Sendable {
    let sessionId: String
    let callId: String
    let clientSocket: Int32
    let event: OCPluginEvent
    let receivedAt: Date
}

// MARK: - Socket Server

typealias OCEventHandler           = @Sendable (OCPluginEvent) -> Void
typealias OCPermissionFailHandler  = @Sendable (_ sessionId: String, _ callId: String) -> Void

class OpenCodeSocketServer {
    static let shared           = OpenCodeSocketServer()
    static let socketPath       = "/tmp/opencode-island.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: OCEventHandler?
    private var failureHandler: OCPermissionFailHandler?
    private let queue = DispatchQueue(label: "com.claudeisland.opencode.socket", qos: .userInitiated)

    private var pendingPermissions: [String: OCPendingPermission] = [:]
    private let permissionsLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    func start(onEvent: @escaping OCEventHandler,
               onPermissionFailure: OCPermissionFailHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, p) in pendingPermissions { close(p.clientSocket) }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    // MARK: - Permission Response

    func respondToPermission(callId: String, decision: String) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(callId: callId, decision: decision)
        }
    }

    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in self?.cleanupPermissions(sessionId: sessionId) }
    }

    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    // MARK: - Server Setup

    private func startServer(onEvent: @escaping OCEventHandler,
                             onPermissionFailure: OCPermissionFailHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler     = onEvent
        failureHandler   = onPermissionFailure

        unlink(Self.socketPath)
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                strcpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), ptr)
            }
        }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(serverSocket, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            logger.error("Bind failed: \(errno)")
            close(serverSocket); serverSocket = -1; return
        }

        chmod(Self.socketPath, 0o777)
        guard listen(serverSocket, 10) == 0 else {
            logger.error("Listen failed: \(errno)")
            close(serverSocket); serverSocket = -1; return
        }

        logger.info("OpenCode socket listening at \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in self?.acceptConnection() }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 { close(fd); self?.serverSocket = -1 }
        }
        acceptSource?.resume()
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        let client = accept(serverSocket, nil, nil)
        guard client >= 0 else { return }
        var nosig: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        handleClient(client)
    }

    private func handleClient(_ client: Int32) {
        let flags = fcntl(client, F_GETFL)
        _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer  = [UInt8](repeating: 0, count: 131_072)
        var pollFd  = pollfd(fd: client, events: Int16(POLLIN), revents: 0)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let r = poll(&pollFd, 1, 50)
            if r > 0, (pollFd.revents & Int16(POLLIN)) != 0 {
                let n = read(client, &buffer, buffer.count)
                if n > 0 { allData.append(contentsOf: buffer[0..<n]) }
                else if n == 0 { break }
                else if errno != EAGAIN && errno != EWOULDBLOCK { break }
            } else if r == 0, !allData.isEmpty { break }
        }

        guard !allData.isEmpty else { close(client); return }

        guard let event = try? JSONDecoder().decode(OCPluginEvent.self, from: allData) else {
            logger.warning("Failed to parse plugin event: \(String(data: allData, encoding: .utf8) ?? "?", privacy: .public)")
            close(client)
            return
        }

        logger.debug("OpenCode plugin event: \(event.hook, privacy: .public)")

        if event.hook == "PermissionRequest" {
            // Keep socket open; Claude Island must write the decision
            let callId = event.callId ?? event.permissionId ?? event.resolvedSessionId
            let pending = OCPendingPermission(
                sessionId: event.resolvedSessionId,
                callId: callId,
                clientSocket: client,
                event: event,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[callId] = pending
            permissionsLock.unlock()
            eventHandler?(event)
            return
        }

        close(client)
        eventHandler?(event)
    }

    // MARK: - Permission Response Sending

    private func sendPermissionResponse(callId: String, decision: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: callId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        let resp = OCPermissionResponse(decision: decision)
        guard let data = try? JSONEncoder().encode(resp) else {
            close(pending.clientSocket); return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending '\(decision, privacy: .public)' for \(pending.sessionId.prefix(8), privacy: .public) (age \(String(format: "%.1f", age), privacy: .public)s)")

        var ok = false
        data.withUnsafeBytes { bytes in
            if let ptr = bytes.baseAddress {
                ok = write(pending.clientSocket, ptr, data.count) > 0
            }
        }
        close(pending.clientSocket)
        if !ok { failureHandler?(pending.sessionId, callId) }
    }

    private func cleanupPermissions(sessionId: String) {
        permissionsLock.lock()
        let stale = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (id, p) in stale { close(p.clientSocket); pendingPermissions.removeValue(forKey: id) }
        permissionsLock.unlock()
    }
}
