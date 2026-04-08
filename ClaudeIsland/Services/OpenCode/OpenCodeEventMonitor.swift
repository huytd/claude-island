//
//  OpenCodeEventMonitor.swift
//  ClaudeIsland
//
//  Monitors a running OpenCode server via SSE and translates events
//  into SessionStore events so they appear alongside Claude Code sessions.
//
//  Discovery: probes localhost:4096..4115 (OpenCode defaults to 4096).
//  Events: parsed from the /event SSE stream (global event bus).
//  Permissions: responded to via POST /permission/{id}/reply.
//

import Foundation
import os.log

// MARK: - OpenCode Data Models

/// Minimal representation of an OpenCode session from GET /session
private struct OCSession: Decodable {
    let id: String
    let title: String?
    let path: String?
}

/// Minimal OpenCode message part
private struct OCMessagePart: Decodable {
    let type: String
    let text: String?
    let toolName: String?
    let toolCallId: String?
    let args: AnyCodable?
    let result: String?
    let state: String?  // "call", "partial-call", "result"
}

/// Minimal OpenCode message
private struct OCMessage: Decodable {
    let id: String
    let role: String
    let parts: [OCMessagePart]
    let createdAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, role, parts
        case createdAt = "time"
    }

    var date: Date {
        if let t = createdAt { return Date(timeIntervalSince1970: t / 1000) }
        return Date()
    }
}

/// Raw SSE event parsed from the /event stream
private struct OCRawEvent: Decodable {
    let type: String
    /// Catch-all for all other top-level keys
    private let extra: [String: AnyCodable]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        type = try container.decode(String.self, forKey: DynamicKey("type"))
        var extras: [String: AnyCodable] = [:]
        for key in container.allKeys where key.stringValue != "type" {
            extras[key.stringValue] = try container.decodeIfPresent(AnyCodable.self, forKey: key)
        }
        extra = extras
    }

    subscript(_ key: String) -> Any? { extra[key]?.value }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - OpenCodeEventMonitor

/// Connects to a locally running OpenCode server, subscribes to its global SSE
/// event stream, and forwards translated events to SessionStore.
actor OpenCodeEventMonitor {
    static let shared = OpenCodeEventMonitor()

    private let logger = Logger(subsystem: "com.claudeisland", category: "OpenCode")

    /// Port range to probe when discovering the server (OpenCode defaults to 4096)
    private static let discoveryPorts = 4096...4115

    private var serverURL: URL?
    private var monitorTask: Task<Void, Never>?
    private var isStarted = false

    /// Maps permission requestID → sessionID for routing approve/deny actions
    private var permissionSessions: [String: String] = [:]

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitorTask = Task { await runLoop() }
    }

    func stop() {
        isStarted = false
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Main Loop

    private func runLoop() async {
        var retryDelay: Double = 2.0

        while isStarted && !Task.isCancelled {
            if let url = await discoverServer() {
                serverURL = url
                retryDelay = 2.0
                await loadExistingSessions(serverURL: url)
                await subscribeToEvents(serverURL: url)
                serverURL = nil
            }

            guard isStarted && !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            retryDelay = min(retryDelay * 1.5, 30.0)
        }
    }

    // MARK: - Server Discovery

    private func discoverServer() async -> URL? {
        for port in Self.discoveryPorts {
            let candidate = URL(string: "http://localhost:\(port)")!
            if await isOpenCodeServer(at: candidate) {
                logger.info("OpenCode server found at port \(port, privacy: .public)")
                return candidate
            }
        }
        logger.debug("No OpenCode server found on ports \(Self.discoveryPorts.lowerBound, privacy: .public)-\(Self.discoveryPorts.upperBound, privacy: .public)")
        return nil
    }

    private func isOpenCodeServer(at baseURL: URL) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("session"))
        req.timeoutInterval = 0.4
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Initial Session Load

    private func loadExistingSessions(serverURL: URL) async {
        guard let (data, _) = try? await URLSession.shared.data(from: serverURL.appendingPathComponent("session")),
              let sessions = try? JSONDecoder().decode([OCSession].self, from: data)
        else { return }

        logger.info("Loading \(sessions.count, privacy: .public) existing OpenCode sessions")

        for session in sessions {
            let path = session.path ?? FileManager.default.homeDirectoryForCurrentUser.path
            await SessionStore.shared.process(.opencodeSessionCreated(
                sessionId: session.id,
                projectPath: path,
                title: session.title
            ))
            await loadMessages(for: session.id, serverURL: serverURL)
        }
    }

    private func loadMessages(for sessionId: String, serverURL: URL) async {
        let url = serverURL
            .appendingPathComponent("session")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("message")

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let messages = try? JSONDecoder().decode([OCMessage].self, from: data)
        else { return }

        for msg in messages {
            if let chatMsg = convertMessage(msg) {
                await SessionStore.shared.process(.opencodeMessageAdded(sessionId: sessionId, message: chatMsg))
            }
            // Track tool calls from existing messages
            for part in msg.parts where part.type == "tool-invocation" {
                if let state = part.state, let toolId = part.toolCallId, let toolName = part.toolName {
                    if state == "call" || state == "partial-call" {
                        let input = extractInput(from: part)
                        await SessionStore.shared.process(.opencodeToolStarted(
                            sessionId: sessionId, toolId: toolId, toolName: toolName, input: input
                        ))
                    } else if state == "result" {
                        await SessionStore.shared.process(.opencodeToolCompleted(
                            sessionId: sessionId, toolId: toolId, status: .success, result: part.result
                        ))
                    }
                }
            }
        }
    }

    // MARK: - SSE Subscription

    private func subscribeToEvents(serverURL: URL) async {
        let url = serverURL.appendingPathComponent("event")
        logger.info("Subscribing to OpenCode SSE at \(url.absoluteString, privacy: .public)")

        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = .infinity

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.warning("SSE endpoint returned non-200")
                return
            }

            var dataBuffer = ""

            for try await line in bytes.lines {
                guard isStarted else { break }

                if line.hasPrefix("data: ") {
                    dataBuffer += String(line.dropFirst(6))
                } else if line.isEmpty && !dataBuffer.isEmpty {
                    // End of SSE event — parse and dispatch
                    await handleRawEventData(dataBuffer)
                    dataBuffer = ""
                }
            }
        } catch {
            if isStarted {
                logger.info("OpenCode SSE disconnected: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Event Dispatch

    private func handleRawEventData(_ raw: String) async {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONDecoder().decode(OCRawEvent.self, from: data)
        else { return }

        logger.debug("OpenCode event: \(event.type, privacy: .public)")

        switch event.type {

        case "server.heartbeat", "server.connected":
            break // Keep-alive — ignore

        case "server.instance.disposed":
            logger.info("OpenCode server disposed — will reconnect")
            return  // Causes subscribeToEvents to return → triggers runLoop retry

        case "session.created":
            guard let sessionId = event["sessionID"] as? String else { break }
            let info = event["info"] as? [String: Any]
            let path = info?["path"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
            let title = info?["title"] as? String
            await SessionStore.shared.process(.opencodeSessionCreated(
                sessionId: sessionId, projectPath: path, title: title
            ))

        case "session.updated":
            guard let sessionId = event["sessionID"] as? String else { break }
            let info = event["info"] as? [String: Any]
            let status = info?["status"] as? String ?? "idle"
            let phase = mapStatus(status)
            await SessionStore.shared.process(.opencodeSessionUpdated(sessionId: sessionId, phase: phase))

        case "session.deleted":
            guard let sessionId = event["sessionID"] as? String else { break }
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))

        case "permission.asked":
            guard let requestId = event["id"] as? String,
                  let sessionId = event["sessionID"] as? String
            else { break }
            let permission = event["permission"] as? String ?? "unknown"
            let patterns = event["patterns"] as? [String] ?? []
            permissionSessions[requestId] = sessionId
            await SessionStore.shared.process(.opencodePermissionRequested(
                sessionId: sessionId, requestId: requestId, permission: permission, patterns: patterns
            ))

        case "permission.replied":
            guard let requestId = event["requestID"] as? String else { break }
            let sessionId = permissionSessions.removeValue(forKey: requestId) ?? (event["sessionID"] as? String ?? "")
            await SessionStore.shared.process(.opencodePermissionResolved(
                sessionId: sessionId, requestId: requestId
            ))

        default:
            // Check for message events (e.g. "message.updated", "message.part.updated")
            if event.type.hasPrefix("message") {
                await handleMessageEvent(event)
            }
        }
    }

    private func handleMessageEvent(_ event: OCRawEvent) async {
        guard let sessionId = event["sessionID"] as? String else { return }

        // If we have a full message, convert and add it
        if let msgDict = event["info"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: msgDict),
           let msg = try? JSONDecoder().decode(OCMessage.self, from: data),
           let chatMsg = convertMessage(msg) {
            await SessionStore.shared.process(.opencodeMessageAdded(sessionId: sessionId, message: chatMsg))
        }

        // Track tool invocations from parts
        if let parts = event["parts"] as? [[String: Any]] {
            for partDict in parts {
                guard let type = partDict["type"] as? String,
                      type == "tool-invocation",
                      let state = partDict["state"] as? String,
                      let toolId = partDict["toolCallId"] as? String,
                      let toolName = partDict["toolName"] as? String
                else { continue }

                if state == "call" {
                    let input = (partDict["args"] as? [String: Any])?.compactMapValues { "\($0)" } ?? [:]
                    await SessionStore.shared.process(.opencodeToolStarted(
                        sessionId: sessionId, toolId: toolId, toolName: toolName, input: input
                    ))
                } else if state == "result" {
                    let result = partDict["result"] as? String
                    await SessionStore.shared.process(.opencodeToolCompleted(
                        sessionId: sessionId, toolId: toolId, status: .success, result: result
                    ))
                }
            }
        }
    }

    // MARK: - Permission Response

    /// Called by the UI to approve or deny an OpenCode permission request.
    func respondToPermission(requestId: String, reply: OpenCodePermissionReply) async {
        guard let serverURL else { return }

        let url = serverURL
            .appendingPathComponent("permission")
            .appendingPathComponent(requestId)
            .appendingPathComponent("reply")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["reply": reply.rawValue])

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Permission reply \(reply.rawValue, privacy: .public) → HTTP \(status, privacy: .public)")
        } catch {
            logger.error("Failed to send permission reply: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Map an OpenCode session status string to a SessionPhase
    private func mapStatus(_ status: String) -> SessionPhase {
        switch status {
        case "idle", "completed":
            return .waitingForInput
        case "running", "generating", "busy":
            return .processing
        case "error":
            return .idle
        default:
            return .idle
        }
    }

    private func convertMessage(_ msg: OCMessage) -> ChatMessage? {
        let role: ChatRole
        switch msg.role {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }

        var blocks: [MessageBlock] = []
        for part in msg.parts {
            if part.type == "text", let text = part.text, !text.isEmpty {
                blocks.append(.text(text))
            }
        }
        guard !blocks.isEmpty else { return nil }

        return ChatMessage(
            id: msg.id,
            role: role,
            timestamp: msg.date,
            content: blocks
        )
    }

    private func extractInput(from part: OCMessagePart) -> [String: String] {
        guard let args = part.args?.value as? [String: Any] else { return [:] }
        return args.compactMapValues { v -> String? in
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
    }
}

// MARK: - Permission Reply Type

enum OpenCodePermissionReply: String {
    case once = "once"
    case always = "always"
    case reject = "reject"
}
