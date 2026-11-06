# GLaDOS: GPT and Claude through OpenClaw

Run `GLaDOS-OpenClaw.cmd` after closing the old GLaDOS server. The launcher starts a local OpenClaw gateway and the existing voice interface. `GLaDOS.cmd` remains the original Claude Code route.

The gateway listens only on 127.0.0.1:18789. Its local credential is in `openclaw/gateway.token`; never paste it into chat or add it to source control. The browser never receives it. Project configuration is in `openclaw/openclaw.json`; edit it through OpenClaw's config commands so its recovery journal stays consistent.

## Models and routing

| Agent | Primary model | Purpose |
| --- | --- | --- |
| GLaDOS | GPT-6 Luna | Brief conversation, coordination |
| gpt-light | GPT-6 Luna | Short summaries and extraction |
| gpt-work | GPT-6 Sol | Implementation and analysis |
| gpt-deep | GPT-6 Astra | Hard reasoning and targeted review |
| claude-work | Claude Sonnet 5 | Substantial coding, synthesis, writing |
| claude-deep | Claude Opus 5 | Hard analysis and targeted review |

Each route has a fallback in the other provider, and GLaDOS has a final local fallback: Ollama `qwen3:8b`. Model access depends on the signed-in plan; the Ollama route is local and has no subscription quota, but uses the computer's CPU/GPU and is slower than the cloud routes. Routing instructions ask GLaDOS to use one worker for a task, short isolated briefs, and at most two concurrent workers. Deep models are reserved for difficult work. This is task-based routing, not a guarantee of the cheapest possible execution or exact quota balancing. Claude native login quota percentages are not available to OpenClaw.

Workers of the same provider share that provider's subscription allowance. GPT and Claude use separate subscriptions. Ordinary tasks are not broadcast to every worker. Heartbeats and cron are disabled in this dedicated gateway. Existing provider extra-usage/credit settings still apply.

## Authentication

GPT uses the official Codex runtime with the existing ChatGPT login in the user's native Codex home. Claude uses the installed Claude Code executable and its existing subscription login. The launcher verifies both authentication methods and removes API-key environment variables from its child process. No API-key fallback is configured. Keep this project's OpenClaw credential store free of API-key profiles.

If login expires, use `codex login` or `%USERPROFILE%\.local\bin\claude.exe auth login` locally. Do not copy login tokens into project source. OpenClaw uses the native Codex home, including its native settings; it creates new conversations rather than resuming the user's existing development thread.

## Confirmation and permissions

Normal voice requests go to the read-only team. A proposed change creates a server-held pending plan and displays the existing Confirm/Cancel controls. Confirm sends the exact saved request and plan to a separate execution team. A user request beginning with "No need to ask" grants execution for that request, matching the existing interface.

Each confirmed task receives a fresh execution session. A failed connection does not automatically replay a change. Read-only agents cannot spawn execution agents. Execution agents can edit files and run commands for the approved task. Reset clears the bridge conversation and pending plan; it does not delete prior OpenClaw history.

## Limits and troubleshooting

- The frontend still uses Fish Audio and ElevenLabs, with their existing billing and configuration.
- The voice bridge currently shows team-level status and the final answer, rather than live individual tool events.
- Claude's existing `--chrome` integration is not automatically transferred to the OpenClaw route. The original launcher remains available for those browser workflows.
- On an uncertain failure after dispatch, inspect the gateway's session before retrying a task that may have changed files.
- Gateway startup output is in `openclaw/gateway.stdout.log` and `openclaw/gateway.stderr.log` when started by the launcher.
- The local fallback is served by `ollama/ollama.exe` on `127.0.0.1:11434`; its model files are under `ollama/models`. The OpenClaw launcher starts Ollama automatically when it is not already running.
- Voice replies use a persistent local Fish Audio WebSocket proxy at `127.0.0.1:18766`. OpenClaw streams text deltas into one Fish session per reply, and the browser appends incoming audio chunks while the answer is still being generated. The Fish API key stays in the server-side proxy process.
- Phone access uses Tailscale Serve: open `https://<your-machine>.<your-tailnet>.ts.net/` on a tailnet device. The UI is forwarded to port 8765 and its WebSocket audio channel is forwarded to port 18766.
- The installer saved the original `server.ps1` under `openclaw/backups/`.

To run OpenClaw commands for this project in PowerShell:

```powershell
Set-Location <ULTRON_ROOT>
. .\openclaw-env.ps1
.\node\openclaw.cmd config validate
.\node\openclaw.cmd agents list
```

Use `config patch --file <patch.json>` or `config set` for changes. A direct replacement of the configuration file can trigger automatic restoration from its last-known-good journal.
