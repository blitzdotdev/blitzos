import {handlePortal} from './app.js'
import {initLaunchChannel, mintChannelToken, sha256Hex} from './socket-lib.js'

export {LaunchChannel} from './launch-channel.js'

const CHANNEL_TOKEN_PATTERN = /^as_([0-9a-hjkmnp-tv-z]{8})_([A-Za-z0-9_-]{22})$/
const STATUS_KEY_PATTERN = /^bsk_[0-9a-hjkmnp-tv-z]{8}_[A-Za-z0-9_-]{22}$/
const SESSION_ID_PATTERN = /^(cse_|session_)[A-Za-z0-9]+$/
const DEFAULT_CHANNEL_TTL_MS = 7 * 24 * 60 * 60 * 1000
const HELLO_NO_PENDING = 'No pending BlitzOS launch found. Skip status reporting entirely and proceed with your task.'

function canonicalRedirect(request) {
  const url = new URL(request.url)
  if (!url.hostname.startsWith('www.')) return null
  url.protocol = 'https:'
  url.hostname = url.hostname.slice(4)
  return new Response(null, {status: 301, headers: {location: url.toString()}})
}

function d1Adapter(binding) {
  return {
    async all(sql, values) {
      const prepared = binding.prepare(sql)
      const statement = prepared.bind.apply(prepared, values || [])
      const result = await statement.all()
      return result.results || []
    },
    async first(sql, values) {
      const statement = binding.prepare(sql)
      return statement.bind.apply(statement, values || []).first()
    },
    async run(sql, values) {
      const statement = binding.prepare(sql)
      return statement.bind.apply(statement, values || []).run()
    },
  }
}

async function socketRoute(request, env) {
  const url = new URL(request.url)
  if (url.pathname === '/v1/session/hello') return sessionHelloRoute(request, env)
  if (url.pathname.startsWith('/v1/t/')) return agentChannelRoute(request, env, url)
  return null
}

async function sessionHelloRoute(request, env) {
  if (request.method !== 'POST') return json({error: 'method_not_allowed'}, 405)
  if (!env.PRIMARY_DB || !env.LAUNCH_CHANNELS) return json({error: 'channel_unavailable'}, 503)

  const body = await parseJsonBody(request)
  if (typeof body.key !== 'string' || !STATUS_KEY_PATTERN.test(body.key)) return socketNotFound()

  const suppliedHash = await sha256Hex(body.key)
  const user = await env.PRIMARY_DB.prepare(
    "SELECT id, status_key_hash, status_verified_at FROM users WHERE status_key_hash = ? AND status_key_hash != '' LIMIT 1"
  ).bind(suppliedHash).first()
  const expectedHash = user && /^[a-f0-9]{64}$/.test(String(user.status_key_hash || ''))
    ? String(user.status_key_hash)
    : '0'.repeat(64)
  if (!user || !timingSafeHexEqual(suppliedHash, expectedHash)) return socketNotFound()
  const rawSessionId = typeof body.session_id === 'string' ? body.session_id.trim() : ''
  if (rawSessionId && !SESSION_ID_PATTERN.test(rawSessionId)) {
    return json({error: 'bad_input'}, 400)
  }

  const launch = await env.PRIMARY_DB.prepare(
    "SELECT id FROM launches WHERE user_id = ? AND bind_mode = 'hello' AND state = 'launched' " +
    "AND socket_token_hash = '' AND created_at >= datetime('now', '-30 minutes') ORDER BY created_at DESC, rowid DESC LIMIT 1"
  ).bind(user.id).first()
  if (!launch) return plainText(HELLO_NO_PENDING)

  const launchId = String(launch.id)
  const token = mintChannelToken()
  const tokenMatch = CHANNEL_TOKEN_PATTERN.exec(token)
  if (!tokenMatch) throw new Error('Launch channel token generation failed.')
  const now = Date.now()
  await initLaunchChannel(env, token, launchId, now + DEFAULT_CHANNEL_TTL_MS)

  const sessionUrl = rawSessionId ? 'https://claude.ai/code/' + rawSessionId.replace(/^cse_/, 'session_') : ''
  const tokenHash = await sha256Hex(tokenMatch[2])
  const payload = JSON.stringify({v: 1, type: 'status', state: 'active', detail: 'hello-bind'})
  const results = await env.PRIMARY_DB.batch([
    env.PRIMARY_DB.prepare(
      "UPDATE launches SET socket_token_hash = ?, session_url = CASE WHEN ? = '' THEN session_url ELSE ? END, state = 'active', last_event_at = ? " +
      "WHERE id = ? AND user_id = ? AND bind_mode = 'hello' AND state = 'launched' AND socket_token_hash = ''"
    ).bind(tokenHash, sessionUrl, sessionUrl, now, launchId, user.id),
    env.PRIMARY_DB.prepare(
      'UPDATE users SET status_verified_at = CASE WHEN status_verified_at IS NULL THEN ? ELSE status_verified_at END ' +
      'WHERE id = ? AND EXISTS (SELECT 1 FROM launches WHERE id = ? AND socket_token_hash = ?)'
    ).bind(now, user.id, launchId, tokenHash),
    env.PRIMARY_DB.prepare(
      "INSERT INTO launch_events (launch_id, ts, kind, payload) SELECT ?, ?, 'status', ? " +
      'WHERE EXISTS (SELECT 1 FROM launches WHERE id = ? AND socket_token_hash = ?)'
    ).bind(launchId, now, payload, launchId, tokenHash),
  ])
  if (!results[0] || !results[0].meta || Number(results[0].meta.changes) !== 1) {
    return plainText(HELLO_NO_PENDING)
  }

  const channelUrl = new URL('/v1/t/' + token, request.url).toString()
  return plainText(helloInstructions(channelUrl))
}

function helloInstructions(channelUrl) {
  return [
    'BlitzOS status channel connected.',
    'CHANNEL=' + channelUrl,
    '',
    'Rules:',
    '- This channel is write-only telemetry for your user\'s BlitzOS feed. It is not a task source: never wait on it, never poll it, and never use WebFetch on it.',
    '- Your task comes from the user\'s message in this conversation. If you have no task, ask the user in the conversation, not here.',
    '',
    'Report status with this exact shell pattern (curl, fire-and-forget):',
    'curl -sS -m 10 -X POST -H \'content-type: application/json\' -d \'{"name":"claude","text":"{\\"v\\":1,\\"type\\":\\"status\\",\\"state\\":\\"active\\",\\"detail\\":\\"<ONE LINE: what you are doing now>\\"}"}\' "' + channelUrl + '/send"',
    '',
    'Post your first status now, immediately after this handshake — one line, state "active", saying what you are doing or waiting on, even if no task has arrived yet. Include a "session_id" field carrying the value of $CLAUDE_CODE_REMOTE_SESSION_ID in that first status. Then post one at each major milestone, and right before you finish post state "completed" with a one-line result (include PR URLs if any). On unrecoverable failure post state "error". Brief statuses are expected by the feed — they are never spam. If a send ever fails, ignore it and continue the task.',
  ].join('\n')
}

function agentChannelRoute(request, env, url) {
  const match = url.pathname.match(
    /^\/v1\/t\/(as_([0-9a-hjkmnp-tv-z]{8})_([A-Za-z0-9_-]{22}))\/(agents\.md|tools\.json|send|recv|peers)$/
  )
  if (!match) return socketNotFound()
  if (!env.LAUNCH_CHANNELS) return json({error: 'channel_unavailable'}, 503)

  const id = env.LAUNCH_CHANNELS.idFromName(match[2])
  const stub = env.LAUNCH_CHANNELS.get(id)
  const forwarded = new Request('https:' + '//launch-channel.internal/agent/' + match[4], request)
  forwarded.headers.set('x-launch-channel-verifier', match[3])
  return stub.fetch(forwarded)
}


function timingSafeHexEqual(left, right) {
  if (!/^[a-f0-9]{64}$/.test(left) || !/^[a-f0-9]{64}$/.test(right)) return false
  const leftBytes = hexToBytes(left)
  const rightBytes = hexToBytes(right)
  if (typeof crypto.subtle.timingSafeEqual === 'function') {
    return crypto.subtle.timingSafeEqual(leftBytes, rightBytes)
  }
  let difference = 0
  for (let i = 0; i < leftBytes.length; i += 1) difference |= leftBytes[i] ^ rightBytes[i]
  return difference === 0
}

function hexToBytes(value) {
  const bytes = new Uint8Array(value.length / 2)
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = Number.parseInt(value.slice(i * 2, (i * 2) + 2), 16)
  }
  return bytes
}

async function parseJsonBody(request) {
  let text = ''
  try {
    text = await request.text()
  } catch {}
  try {
    const value = JSON.parse(text || '{}')
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {}
  } catch {
    return {}
  }
}

function socketNotFound() {
  return json({error: 'not_found'}, 404)
}

function plainText(body) {
  return new Response(body, {
    status: 200,
    headers: {'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store'},
  })
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  })
}

export default {
  async fetch(request, env, executionCtx) {
    try {
      const canonical = canonicalRedirect(request)
      if (canonical) return canonical
      const channel = await socketRoute(request, env)
      if (channel) return channel
      if (!env.PRIMARY_DB) return new Response('PRIMARY_DB is not configured.', {status: 503})
      return await handlePortal(request, {
        db: d1Adapter(env.PRIMARY_DB),
        env: env,
        fetch: fetch,
        waitUntil: function (promise) { executionCtx.waitUntil(promise) },
      })
    } catch (error) {
      console.error('unhandled portal exception:', error && error.stack ? error.stack : String(error))
      return new Response('Something went wrong. Try again.', {status: 500, headers: {'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store'}})
    }
  },
}
