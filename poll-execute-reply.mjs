// Confirmed GLaDOS tasks almost always delegate to a specialist worker and pause
// (sessions_spawn + sessions_yield) waiting for it. The chat-completions HTTP stream closes at
// that pause point, before the coordinator's real final answer exists, so the bridge sees an
// empty/filler reply. This polls the session's own SQLite transcript directly for the terminal
// assistant message once the session actually finishes, and while waiting, reports whatever
// tool call is most recently active (in the coordinator or whichever worker it delegated to) so
// the page can show real progress instead of going silent.
import { DatabaseSync } from 'node:sqlite';
import { existsSync } from 'node:fs';
import zlib from 'node:zlib';

const [, , root, agent, sessionUser, timeoutSecondsArg] = process.argv;
const timeoutMs = (Number(timeoutSecondsArg) || 300) * 1000;
const pollIntervalMs = 2000;
const deadline = Date.now() + timeoutMs;

// Every worker a coordinator can currently delegate to; scanned for child activity each tick.
const WORKER_AGENTS = ['gpt-light', 'gpt-work', 'gpt-deep', 'claude-work', 'claude-deep',
	'gpt-light-execute', 'gpt-work-execute', 'gpt-deep-execute', 'claude-work-execute', 'claude-deep-execute'];

function dbPathFor(agentId) {
	return `${root}\\openclaw\\agents\\${agentId}\\agent\\openclaw-agent.sqlite`;
}

function openDb(path) {
	if (!existsSync(path)) return null;
	try { return new DatabaseSync(path, { readOnly: true }); } catch { return null; }
}

function decodeEvent(row) {
	if (row.event_json) return row.event_json;
	if (row.event_zstd) {
		try { return zlib.zstdDecompressSync(Buffer.from(row.event_zstd)).toString('utf8'); } catch { return null; }
	}
	return null;
}

function findSessionId(db, key) {
	const row = db.prepare('select current_session_id from session_nodes where session_key = ?').get(key);
	return row ? row.current_session_id : null;
}

function sessionStatus(db, sessionId) {
	return db.prepare('select status from session_windows where session_id = ? order by updated_at desc limit 1').get(sessionId) || null;
}

function lastAssistantText(db, sessionId) {
	const rows = db.prepare('select event_json, event_zstd from transcript_events where session_id = ? order by seq desc').all(sessionId);
	for (const row of rows) {
		const raw = decodeEvent(row);
		if (!raw) continue;
		let ev;
		try { ev = JSON.parse(raw); } catch { continue; }
		if (ev.type !== 'message' || !ev.message || ev.message.role !== 'assistant') continue;
		const content = Array.isArray(ev.message.content) ? ev.message.content : [];
		const textPart = content.find((c) => c.type === 'text' && c.text && c.text.trim());
		if (textPart) return textPart.text;
	}
	return null;
}

// Best-effort human label for a tool call, across both the Claude-Code-style direct tool names
// (Read/Write/Edit/Bash/...) and the OpenAI/codex style, which is often a generic "exec" call
// running a JS snippet like `tools.write({...})`, or a real shell exec with a human `title`.
function describeToolCall(name, args) {
	if (args && typeof args.title === 'string' && args.title.trim()) return args.title.trim();
	if (typeof name === 'string') name = name.replace(/^openclaw_direct__/, '').replace(/^openclaw__/, '');
	const short = (v, max = 60) => {
		const s = String(v ?? '');
		return s.length > max ? s.slice(0, max - 3) + '...' : s;
	};
	const path = args && (args.file_path || args.path);
	switch (name) {
		case 'Read': case 'read': return `Reading ${short(path)}`;
		case 'Write': case 'write': return `Writing ${short(path)}`;
		case 'Edit': case 'edit': case 'apply_patch': return `Editing ${short(path)}`;
		case 'Glob': case 'ls': return `Looking in ${short(args?.path || '.')}`;
		case 'Grep': case 'find': return `Searching for ${short(args?.pattern)}`;
		case 'WebSearch': return `Searching the web for ${short(args?.query)}`;
		case 'WebFetch': case 'web_fetch': return `Opening ${short(args?.url)}`;
		case 'Bash': case 'PowerShell': case 'process': return `Running ${short(args?.command || args?.description)}`;
		case 'sessions_spawn': return `Delegating to ${short(args?.agentId || 'a worker')}`;
		case 'sessions_yield': return 'Waiting for the worker';
		case 'view_image': return `Looking at ${short(path)}`;
		case 'exec': {
			const input = typeof args?.input === 'string' ? args.input : (typeof args?.command === 'string' ? args.command : '');
			const m = input.match(/tools\.(\w+)\(/);
			if (m) return describeToolCall(m[1], {});
			if (input) return `Running ${short(input.replace(/\s+/g, ' '))}`;
			return 'Working';
		}
		default: return name ? `Using ${name}` : 'Working';
	}
}

function lastToolCall(db, sessionId) {
	const rows = db.prepare('select seq, event_json, event_zstd, created_at from transcript_events where session_id = ? order by seq desc limit 30').all(sessionId);
	for (const row of rows) {
		const raw = decodeEvent(row);
		if (!raw) continue;
		let ev;
		try { ev = JSON.parse(raw); } catch { continue; }
		if (ev.type !== 'message' || !ev.message || ev.message.role !== 'assistant') continue;
		const content = Array.isArray(ev.message.content) ? ev.message.content : [];
		const call = content.find((c) => c.type === 'toolCall');
		if (call) return { at: row.created_at, text: describeToolCall(call.name, call.arguments) };
	}
	return null;
}

function latestActivity(topAgent, topSessionKey) {
	const candidates = [];
	const topDb = openDb(dbPathFor(topAgent));
	if (topDb) {
		const topId = findSessionId(topDb, topSessionKey);
		if (topId) {
			const tc = lastToolCall(topDb, topId);
			if (tc) candidates.push(tc);
		}
		topDb.close();
	}
	for (const worker of WORKER_AGENTS) {
		const db = openDb(dbPathFor(worker));
		if (!db) continue;
		try {
			const rows = db.prepare("select session_id, parent_session_key from session_windows where parent_session_key = ? and status = 'running' order by updated_at desc limit 1").all(topSessionKey);
			for (const row of rows) {
				const tc = lastToolCall(db, row.session_id);
				if (tc) candidates.push(tc);
			}
		} catch { /* table shape may differ; ignore */ }
		db.close();
	}
	if (!candidates.length) return null;
	candidates.sort((a, b) => b.at - a.at);
	return candidates[0].text;
}

async function main() {
	const topSessionKey = `agent:${agent}:openai-user:${sessionUser}`;
	let lastReportedAt = 0;
	while (Date.now() < deadline) {
		try {
			const topDb = openDb(dbPathFor(agent));
			if (topDb) {
				const topId = findSessionId(topDb, topSessionKey);
				if (topId) {
					const status = sessionStatus(topDb, topId);
					if (status && status.status === 'done') {
						const text = lastAssistantText(topDb, topId);
						topDb.close();
						if (text) { console.log(JSON.stringify({ ok: true, text })); return; }
					}
				}
				topDb.close();
			}
		} catch { /* DB may be mid-write; ignore and retry */ }
		await new Promise((r) => setTimeout(r, pollIntervalMs));
	}
	console.log(JSON.stringify({ ok: false, reason: 'timeout' }));
}

// A separate lightweight mode: print only the current best-guess activity label, once, and exit.
// Used by the bridge for heartbeat status lines between the longer completion-poll slices.
if (process.argv[6] === '--peek') {
	const topSessionKey = `agent:${agent}:openai-user:${sessionUser}`;
	const text = latestActivity(agent, topSessionKey);
	console.log(JSON.stringify({ ok: !!text, text: text || null }));
} else {
	main();
}
