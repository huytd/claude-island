/**
 * opencode-island.js
 *
 * OpenCode plugin that integrates with Claude Island's notch UI.
 * Forwards lifecycle events via Unix socket so sessions appear
 * alongside Claude Code sessions in the menu bar overlay.
 *
 * Protocol (all messages are single-line JSON):
 *   Plugin → Claude Island  (fire-and-forget):
 *     { "hook": "event"|"PreToolUse"|"PostToolUse", ...fields }
 *   Plugin → Claude Island  (permission request, expects response):
 *     { "hook": "PermissionRequest", "session_id": "...", ... }
 *   Claude Island → Plugin  (permission decision):
 *     { "decision": "allow"|"deny" }
 */

const SOCKET = "/tmp/opencode-island.sock";

// Send a message and don't wait for a reply.
async function notify(msg) {
  try {
    await new Promise((resolve) => {
      Bun.connect({
        unix: SOCKET,
        socket: {
          open(s) { s.write(JSON.stringify(msg)); s.end(); },
          close() { resolve(); },
          error() { resolve(); },
        },
      }).catch(resolve);
    });
  } catch { /* Claude Island not running — that's fine */ }
}

// Send a message and wait for a JSON reply (used for permissions).
async function request(msg, timeoutMs = 300_000) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("timeout")), timeoutMs);

    Bun.connect({
      unix: SOCKET,
      socket: {
        open(s) { s.write(JSON.stringify(msg)); },
        data(_s, bytes) {
          buf += new TextDecoder().decode(bytes);
          try {
            const parsed = JSON.parse(buf);
            clearTimeout(timer);
            resolve(parsed);
          } catch { /* wait for more data */ }
        },
        close() { clearTimeout(timer); reject(new Error("socket closed")); },
        error(_s, err) { clearTimeout(timer); reject(err); },
      },
    }).catch((err) => { clearTimeout(timer); reject(err); });
  });
}

export default {
  server() {
    return {
      // All bus events — used for session lifecycle (created/updated/idle/deleted).
      async event({ event }) {
        await notify({ hook: "event", ...event });
      },

      // Fires just before a tool runs. Lets us show it as "running" in the UI.
      async "tool.execute.before"(input, output) {
        await notify({
          hook: "PreToolUse",
          session_id: input.sessionID,
          tool: input.tool,
          call_id: input.callID,
          args: output.args ?? {},
        });
      },

      // Fires after a tool completes. Updates the tool status in the UI.
      async "tool.execute.after"(input, output) {
        await notify({
          hook: "PostToolUse",
          session_id: input.sessionID,
          tool: input.tool,
          call_id: input.callID,
          result: output.output ?? "",
        });
      },

      // Permission request — blocks until Claude Island responds (or times out).
      // Setting output.status to "allow"/"deny" skips OpenCode's own dialog.
      async "permission.ask"(input, output) {
        try {
          const resp = await request({
            hook: "PermissionRequest",
            session_id: input.sessionID,
            permission_id: input.id ?? "",
            permission: input.permission ?? "unknown",
            patterns: input.patterns ?? [],
            call_id: input.tool?.callID ?? input.id ?? "",
          });
          if (resp?.decision === "allow") output.status = "allow";
          else if (resp?.decision === "deny") output.status = "deny";
          // Else leave as "ask" — fall through to OpenCode's native dialog
        } catch {
          // Claude Island not available — let OpenCode handle it natively
        }
      },
    };
  },
};
