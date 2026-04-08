//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Install OpenCode plugin and start its socket server
        OpenCodePluginInstaller.installIfNeeded()
        startOpenCodeSocketServer()

        // Start Claude Code hook socket server
        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        OpenCodeSocketServer.shared.stop()
    }

    // MARK: - OpenCode Socket Server

    private func startOpenCodeSocketServer() {
        OpenCodeSocketServer.shared.start(
            onEvent: { event in
                Task { await Self.handleOpenCodePluginEvent(event) }
            },
            onPermissionFailure: { sessionId, callId in
                Task {
                    await SessionStore.shared.process(
                        .opencodePermissionResolved(sessionId: sessionId, requestId: callId)
                    )
                }
            }
        )
    }

    /// Translate an OCPluginEvent into one or more SessionStore events.
    private static func handleOpenCodePluginEvent(_ event: OCPluginEvent) async {
        let sessionId = event.resolvedSessionId

        switch event.hook {

        case "event":
            // Bus event forwarded by the plugin's event() hook
            await handleOpenCodeBusEvent(event)

        case "PreToolUse":
            guard let toolName = event.tool, let callId = event.callId else { return }
            let input = (event.args?.value as? [String: Any])?.compactMapValues { v -> String? in
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return nil
            } ?? [:]
            // Ensure session exists (tool may arrive before session.created)
            await ensureOpenCodeSession(sessionId: sessionId, cwd: nil)
            await SessionStore.shared.process(.opencodeToolStarted(
                sessionId: sessionId, toolId: callId, toolName: toolName, input: input
            ))
            await SessionStore.shared.process(.opencodeSessionUpdated(
                sessionId: sessionId, phase: .processing
            ))

        case "PostToolUse":
            guard let callId = event.callId else { return }
            await SessionStore.shared.process(.opencodeToolCompleted(
                sessionId: sessionId, toolId: callId, status: .success, result: event.result
            ))

        case "PermissionRequest":
            let callId       = event.callId ?? event.permissionId ?? ""
            let permName     = event.permission ?? "unknown"
            let patterns     = event.patterns ?? []
            await ensureOpenCodeSession(sessionId: sessionId, cwd: nil)
            await SessionStore.shared.process(.opencodePermissionRequested(
                sessionId: sessionId, requestId: callId,
                permission: permName, patterns: patterns
            ))

        default:
            break
        }
    }

    private static func handleOpenCodeBusEvent(_ event: OCPluginEvent) async {
        guard let eventType = event.type else { return }
        let sessionId = event.resolvedSessionId

        switch eventType {
        case "session.created":
            let info = event.info
            let path = info?["path"]?.value as? String
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
            let title = info?["title"]?.value as? String
            await SessionStore.shared.process(.opencodeSessionCreated(
                sessionId: sessionId, projectPath: path, title: title
            ))

        case "session.updated":
            let info   = event.info
            let status = info?["status"]?.value as? String ?? "idle"
            await SessionStore.shared.process(.opencodeSessionUpdated(
                sessionId: sessionId, phase: mapOpenCodeStatus(status)
            ))

        case "session.status":
            let status = event.status ?? "idle"
            await SessionStore.shared.process(.opencodeSessionUpdated(
                sessionId: sessionId, phase: mapOpenCodeStatus(status)
            ))

        case "session.idle":
            await SessionStore.shared.process(.opencodeSessionUpdated(
                sessionId: sessionId, phase: .waitingForInput
            ))

        case "session.compacted":
            await SessionStore.shared.process(.opencodeSessionUpdated(
                sessionId: sessionId, phase: .compacting
            ))

        case "session.deleted":
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))

        default:
            break
        }
    }

    /// Creates an OpenCode session stub if it doesn't exist yet.
    private static func ensureOpenCodeSession(sessionId: String, cwd: String?) async {
        guard await SessionStore.shared.session(for: sessionId) == nil else { return }
        let path = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        await SessionStore.shared.process(.opencodeSessionCreated(
            sessionId: sessionId, projectPath: path, title: nil
        ))
    }

    private static func mapOpenCodeStatus(_ status: String) -> SessionPhase {
        switch status {
        case "idle":               return .waitingForInput
        case "running", "streaming", "busy": return .processing
        case "archived":           return .ended
        default:                   return .idle
        }
    }

    // MARK: - Claude Code Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else { return }
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId, decision: "allow"
            )
            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func approvePermissionAlways(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else { return }
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId, decision: "allow"
            )
            await SessionStore.shared.process(
                .permissionApprovedAlways(
                    sessionId: sessionId,
                    toolUseId: permission.toolUseId,
                    toolName: permission.toolName
                )
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else { return }
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId, decision: "deny", reason: reason
            )
            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    // MARK: - OpenCode Permission Handling

    func approveOpenCodePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else { return }
            OpenCodeSocketServer.shared.respondToPermission(
                callId: permission.toolUseId, decision: "allow"
            )
            await SessionStore.shared.process(.opencodePermissionResolved(
                sessionId: sessionId, requestId: permission.toolUseId
            ))
        }
    }

    func approveOpenCodePermissionAlways(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else { return }
            // "always" — tell the plugin to allow and store the pattern
            OpenCodeSocketServer.shared.respondToPermission(
                callId: permission.toolUseId, decision: "allow"
            )
            await SessionStore.shared.process(.permissionApprovedAlways(
                sessionId: sessionId,
                toolUseId: permission.toolUseId,
                toolName: permission.toolName
            ))
        }
    }

    func denyOpenCodePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else { return }
            OpenCodeSocketServer.shared.respondToPermission(
                callId: permission.toolUseId, decision: "deny"
            )
            await SessionStore.shared.process(.opencodePermissionResolved(
                sessionId: sessionId, requestId: permission.toolUseId
            ))
        }
    }

    // MARK: - Archive

    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }
        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
