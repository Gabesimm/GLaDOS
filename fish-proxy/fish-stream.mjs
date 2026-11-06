import http from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';
import { encode, decode } from '@msgpack/msgpack';

const port = Number(process.env.FISH_PROXY_PORT || 18766);
const key = process.env.FISH_API_KEY || '';
const voice = process.env.FISH_VOICE_ID || '';
const model = process.env.FISH_MODEL || 's2.1-pro';

function readJson(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.setEncoding('utf8');
    req.on('data', c => { data += c; if (data.length > 200000) reject(new Error('request too large')); });
    req.on('end', () => { try { resolve(JSON.parse(data || '{}')); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}

async function synthesize(text) {
  if (!key) throw new Error('FISH_API_KEY is not set');
  return await new Promise((resolve, reject) => {
    const chunks = [];
    let finished = false;
    const ws = new WebSocket('wss://api.fish.audio/v1/tts/live', {
      headers: { Authorization: `Bearer ${key}`, model }
    });
    const fail = e => { if (!finished) { finished = true; console.error(`Fish WS error: ${e.message}`); try { ws.close(); } catch {} reject(e); } };
    ws.on('open', () => {
      ws.send(encode({ event: 'start', request: { text: '', reference_id: voice, format: 'mp3', latency: 'balanced', chunk_length: 160 } }));
      ws.send(encode({ event: 'text', text }));
      ws.send(encode({ event: 'stop' }));
    });
    ws.on('message', data => {
      try {
        const event = decode(data);
        if (event?.event === 'audio' && event.audio) chunks.push(Buffer.from(event.audio));
        if (event?.event === 'finish' && !finished) { finished = true; resolve(Buffer.concat(chunks)); ws.close(); }
      } catch (e) { fail(e); }
    });
    ws.on('error', fail);
    ws.on('close', (code, reason) => { if (!finished) { if (chunks.length) { finished = true; resolve(Buffer.concat(chunks)); } else fail(new Error(`Fish Audio WebSocket closed before finish (${code}): ${reason}`)); } });
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/') { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }
  if (req.method !== 'POST' || req.url !== '/tts') { res.writeHead(404); res.end(); return; }
  try {
    const body = await readJson(req);
    const audio = await synthesize(String(body.text || '').trim());
    res.writeHead(200, { 'Content-Type': 'audio/mpeg', 'Content-Length': audio.length, 'Cache-Control': 'no-store' });
    res.end(audio);
  } catch (e) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: e.message }));
  }
});
const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  if (req.url !== '/stream') { socket.destroy(); return; }
  wss.handleUpgrade(req, socket, head, client => wss.emit('connection', client));
});
wss.on('connection', client => {
  if (!key) { client.close(1011, 'FISH_API_KEY is not set'); return; }
  const fish = new WebSocket('wss://api.fish.audio/v1/tts/live', { headers: { Authorization: `Bearer ${key}`, model } });
  fish.on('open', () => fish.send(encode({ event: 'start', request: { text: '', reference_id: voice, format: 'mp3', latency: 'balanced', chunk_length: 160 } })));
  fish.on('message', data => {
    try {
      const event = decode(data);
      if (event?.event === 'audio' && event.audio && client.readyState === 1) client.send(Buffer.from(event.audio));
      if (event?.event === 'finish' && client.readyState === 1) client.send(JSON.stringify({ event: 'finish' }));
    } catch (e) { if (client.readyState === 1) client.send(JSON.stringify({ event: 'error', error: e.message })); }
  });
  fish.on('error', e => { if (client.readyState === 1) client.send(JSON.stringify({ event: 'error', error: e.message })); });
  client.on('message', data => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === 'text') fish.send(encode({ event: 'text', text: String(msg.text || '') }));
      else if (msg.type === 'flush') fish.send(encode({ event: 'flush' }));
      else if (msg.type === 'stop') fish.send(encode({ event: 'stop' }));
    } catch {}
  });
  client.on('close', () => { try { fish.close(); } catch {} });
});
server.listen(port, '127.0.0.1', () => console.log(`Fish streaming proxy listening on 127.0.0.1:${port}`));
