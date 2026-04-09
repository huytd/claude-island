//
//  SessionEvent.swift
//  ClaudeIsland
//
//  Unified event types for the session state machine.
//  All state changes flow through SessionStore.process(event).
//

import Foundation

/// All events that can affect session state
/// This is the single entry point for state mutations
enum SessionEvent: Sendable {
    // MARK: - Hook Events (from HookSocketServer)

    /// A hook event was received from Claude Code
    case hookReceived(HookEvent)

    // MARK: - Permission Events (user actions)

    /// User approved a permission request
    case permissionApproved(sessionId: String, toolUseId: String)

    /// User approved a permission request and wants to always allow this tool
    case permissionApprovedAlways(sessionId: String, toolUseId: String, toolName: String)

    /// User denied a permission request
    case permissionDenied(sessionId: String, toolUseId: String, reason: String?)

    /// Permission socket failed (connection died before response)
    case permissionSocketFailed(sessionId: String, toolUseId: String)

    // MARK: - File Events (from ConversationParser)

    /// JSONL file was updated with new content
    case fileUpdated(FileUpdatePayload)

    // MARK: - Tool Completion Events (from JSONL parsing)

    /// A tool was detected as completed via JSONL result
    /// This is the authoritative signal that a tool has finished
    case toolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult)

    // MARK: - Interrupt Events (from JSONLInterruptWatcher)

    /// User interrupted Claude (detected via JSONL)
    case interruptDetected(sessionId: String)

    // MARK: - Subagent Events (Task tool tracking)

    /// A Task (subagent) tool has started
    case subagentStarted(sessionId: String, taskToolId: String)

    /// A tool was executed within an active subagent
    case subagentToolExecuted(sessionId: String, tool: SubagentToolCall)

    /// A subagent tool completed (status update)
    case subagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus)

    /// A Task (subagent) tool has stopped
    case subagentStopped(sessionId: String, taskToolId: String)

    /// Agent file was updated with new subagent tools (from AgentFileWatcher)
    case agentFileUpdated(sessionId: String, taskToolId: String, tools: [SubagentToolInfo])

    // MARK: - Clear Events (from JSONL detection)

    /// User issued /clear command - reset UI state while keeping session alive
    case clearDetected(sessionId: String)

    // MARK: - Session Lifecycle

    /// Session has ended
    case sessionEnded(sessionId: String)

    /// Request to load initial history from file
    case loadHistory(sessionId: String, cwd: String)

    /// History load completed
    case historyLoaded(sessionId: String, messages: [ChatMessage], completedTools: Set<String>, toolResults: [String: ConversationParser.ToolResult], structuredResults: [String: ToolResultData], conversationInfo: ConversationInfo)

    // MARK: - OpenCode Events (from OpenCodeSocketServer / plugin)

    /// An OpenCode session was created or discovered
    case opencodeSessionCreated(sessionId: String, projectPath: String, title: String?)

    /// An OpenCode session's status changed
    case opencodeSessionUpdated(sessionId: String, phase: SessionPhase)

    /// An OpenCode tool call started
    case opencodeToolStarted(sessionId: String, toolId: String, toolName: String, input: [String: String])

    /// An OpenCode tool call completed
    case opencodeToolCompleted(sessionId: String, toolId: String, status: ToolStatus, result: String?)

    /// An OpenCode session received a new user or assistant message
    case opencodeMessageAdded(sessionId: String, message: ChatMessage)

    /// An OpenCode session requires permission approval
    case opencodePermissionRequested(sessionId: String, requestId: String, permission: String, patterns: [String])

    /// An OpenCode permission request was resolved (approved or denied externally)
    case opencodePermissionResolved(sessionId: String, requestId: String)
}

/// Payload for file update events
struct FileUpdatePayload: Sendable {
    let sessionId: String
    let cwd: String
    /// Messages to process - either only new messages (if isIncremental) or all messages
    let messages: [ChatMessage]
    /// When true, messages contains only NEW messages since last update
    /// When false, messages contains ALL messages (used for initial load or after /clear)
    let isIncremental: Bool
    let completedToolIds: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
}

/// Result of a tool completion detected from JSONL
struct ToolCompletionResult: Sendable {
    let status: ToolStatus
    let result: String?
    let structuredResult: ToolResultData?

    nonisolated static func from(parserResult: ConversationParser.ToolResult?, structuredResult: ToolResultData?) -> ToolCompletionResult {
        let status: ToolStatus
        if parserResult?.isInterrupted == true {
            status = .interrupted
        } else if parserResult?.isError == true {
            status = .error
        } else {
            status = .success
        }

        var resultText: String? = nil
        if let r = parserResult {
            if !r.isInterrupted {
                if let stdout = r.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = r.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = r.content, !content.isEmpty {
                    resultText = content
                }
            }
        }

        return ToolCompletionResult(status: status, result: resultText, structuredResult: structuredResult)
    }
}

// MARK: - Hook Event Extensions

extension HookEvent {
    /// Determine the target session phase based on this hook event
    nonisolated func determinePhase() -> SessionPhase {
        // PreCompact takes priority
        if event == "PreCompact" {
            return .compacting
        }

        // Permission request creates waitingForApproval state
        if expectsResponse, let tool = tool {
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool,
                toolInput: toolInput,
                receivedAt: Date()
            ))
        }

        if event == "Notification" && notificationType == "idle_prompt" {
            return .idle
        }

        switch status {
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        default:
            return .idle
        }
    }

    /// Whether this is a tool-related event
    nonisolated var isToolEvent: Bool {
        event == "PreToolUse" || event == "PostToolUse" || event == "PermissionRequest"
    }

    /// Whether this event should trigger a file sync
    nonisolated var shouldSyncFile: Bool {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop":
            return true
        default:
            return false
        }
    }
}

// MARK: - Debug Description

extension SessionEvent: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .hookReceived(let event):
            return "hookReceived(\(event.event), session: \(event.sessionId.prefix(8)))"
        case .permissionApproved(let sessionId, let toolUseId):
            return "permissionApproved(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionApprovedAlways(let sessionId, let toolUseId, let toolName):
            return "permissionApprovedAlways(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)), name: \(toolName))"
        case .permissionDenied(let sessionId, let toolUseId, _):
            return "permissionDenied(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionSocketFailed(let sessionId, let toolUseId):
            return "permissionSocketFailed(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .fileUpdated(let payload):
            return "fileUpdated(session: \(payload.sessionId.prefix(8)), messages: \(payload.messages.count))"
        case .interruptDetected(let sessionId):
            return "interruptDetected(session: \(sessionId.prefix(8)))"
        case .clearDetected(let sessionId):
            return "clearDetected(session: \(sessionId.prefix(8)))"
        case .sessionEnded(let sessionId):
            return "sessionEnded(session: \(sessionId.prefix(8)))"
        case .loadHistory(let sessionId, _):
            return "loadHistory(session: \(sessionId.prefix(8)))"
        case .historyLoaded(let sessionId, let messages, _, _, _, _):
            return "historyLoaded(session: \(sessionId.prefix(8)), messages: \(messages.count))"
        case .toolCompleted(let sessionId, let toolUseId, let result):
            return "toolCompleted(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)), status: \(result.status))"
        case .subagentStarted(let sessionId, let taskToolId):
            return "subagentStarted(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .subagentToolExecuted(let sessionId, let tool):
            return "subagentToolExecuted(session: \(sessionId.prefix(8)), tool: \(tool.name))"
        case .subagentToolCompleted(let sessionId, let toolId, let status):
            return "subagentToolCompleted(session: \(sessionId.prefix(8)), tool: \(toolId.prefix(12)), status: \(status))"
        case .subagentStopped(let sessionId, let taskToolId):
            return "subagentStopped(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .agentFileUpdated(let sessionId, let taskToolId, let tools):
            return "agentFileUpdated(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)), tools: \(tools.count))"
        case .opencodeSessionCreated(let sessionId, _, let title):
            return "opencodeSessionCreated(session: \(sessionId.prefix(8)), title: \(title ?? "nil"))"
        case .opencodeSessionUpdated(let sessionId, let phase):
            return "opencodeSessionUpdated(session: \(sessionId.prefix(8)), phase: \(phase))"
        case .opencodeToolStarted(let sessionId, let toolId, let toolName, _):
            return "opencodeToolStarted(session: \(sessionId.prefix(8)), tool: \(toolId.prefix(12)), name: \(toolName))"
        case .opencodeToolCompleted(let sessionId, let toolId, let status, _):
            return "opencodeToolCompleted(session: \(sessionId.prefix(8)), tool: \(toolId.prefix(12)), status: \(status))"
        case .opencodeMessageAdded(let sessionId, let message):
            return "opencodeMessageAdded(session: \(sessionId.prefix(8)), role: \(message.role))"
        case .opencodePermissionRequested(let sessionId, let requestId, let permission, _):
            return "opencodePermissionRequested(session: \(sessionId.prefix(8)), request: \(requestId.prefix(12)), permission: \(permission))"
        case .opencodePermissionResolved(let sessionId, let requestId):
            return "opencodePermissionResolved(session: \(sessionId.prefix(8)), request: \(requestId.prefix(12)))"
        }
    }
}
