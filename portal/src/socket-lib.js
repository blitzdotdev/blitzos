const CROCKFORD_ALPHABET = '0123456789abcdefghjkmnpqrstvwxyz'
const TOKEN_PATTERN = /^as_([0-9a-hjkmnp-tv-z]{8})_([A-Za-z0-9_-]{22})$/

function mintToken(prefix) {
  const sessionBytes = crypto.getRandomValues(new Uint8Array(8))
  let sessionId = ''
  for (let i = 0; i < sessionBytes.length; i += 1) {
    sessionId += CROCKFORD_ALPHABET[sessionBytes[i] % CROCKFORD_ALPHABET.length]
  }

  const verifierBytes = crypto.getRandomValues(new Uint8Array(16))
  let verifierBinary = ''
  for (let i = 0; i < verifierBytes.length; i += 1) {
    verifierBinary += String.fromCharCode(verifierBytes[i])
  }
  const verifier = btoa(verifierBinary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')

  return prefix + sessionId + '_' + verifier
}

export function mintChannelToken() {
  return mintToken('as_')
}

export function mintStatusKey() {
  return mintToken('bsk_')
}

export async function sha256Hex(value) {
  const bytes = new TextEncoder().encode(String(value))
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest), function (byte) {
    return byte.toString(16).padStart(2, '0')
  }).join('')
}

export async function initLaunchChannel(env, token, launchId, expiresAt) {
  const parsed = TOKEN_PATTERN.exec(token)
  if (!parsed) throw new Error('Invalid launch channel token format.')
  if (typeof launchId !== 'string' || !launchId.trim()) throw new Error('launchId is required.')

  const expiry = expiresAt == null ? Date.now() + (7 * 24 * 60 * 60 * 1000) : Number(expiresAt)
  if (!Number.isFinite(expiry)) throw new Error('expiresAt must be a finite timestamp.')

  const id = env.LAUNCH_CHANNELS.idFromName(parsed[1])
  const stub = env.LAUNCH_CHANNELS.get(id)
  const response = await stub.fetch(new Request('https:' + '//launch-channel.internal/__internal/init', {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({
      verifier_hash: await sha256Hex(parsed[2]),
      launch_id: launchId,
      expires_at: Math.trunc(expiry),
    }),
  }))
  if (!response.ok) {
    throw new Error('Launch channel initialization failed with status ' + response.status + '.')
  }
  return response.json()
}
