import {escapeHtml, formatTime, hiddenCsrf, page, PRIVACY_LINE} from './design.js'
import {
  buildClaudeDeepLink,
  ContextRepositoryError,
  createContextRepository,
  normalizeMembers,
  parseGitmodules,
  updateContextRepository,
  validateBranch,
  validateFullName,
} from './portal-lib.js'
import {initLaunchChannel, mintChannelToken, mintStatusKey, sha256Hex} from './socket-lib.js'

const SESSION_COOKIE = 'blitzos_session'
const OAUTH_COOKIE = 'blitzos_oauth_state'
const encoder = new TextEncoder()
const decoder = new TextDecoder()
const SOCKET_TOKEN_PATTERN = /^as_[0-9a-hjkmnp-tv-z]{8}_([A-Za-z0-9_-]{22})$/
const SOCKET_TTL_MS = 7 * 24 * 60 * 60 * 1000

function envValue(ctx, name) {
  const value = ctx.env && ctx.env[name]
  return value == null ? '' : String(value).trim()
}

function parseCookies(request) {
  const result = new Map()
  const header = request.headers.get('cookie') || ''
  header.split(';').forEach(function (part) {
    const index = part.indexOf('=')
    if (index < 0) return
    const name = part.slice(0, index).trim()
    const value = part.slice(index + 1).trim()
    try { result.set(name, decodeURIComponent(value)) } catch { result.set(name, value) }
  })
  return result
}

function base64Url(bytes) {
  let binary = ''
  bytes.forEach(function (byte) { binary += String.fromCharCode(byte) })
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

function fromBase64Url(value) {
  const padded = String(value).replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((String(value).length + 3) % 4)
  const binary = atob(padded)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
  return bytes
}

async function hmac(value, secret) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), {name: 'HMAC', hash: 'SHA-256'}, false, ['sign'])
  return base64Url(new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(value))))
}

function sessionSecret(ctx) {
  return envValue(ctx, 'SESSION_SECRET')
}

async function makeSession(userId, ctx) {
  const secret = sessionSecret(ctx)
  if (!secret) throw new Error('SESSION_SECRET is not configured.')
  const payload = String(userId) + '.' + String(Date.now() + 30 * 24 * 60 * 60 * 1000)
  const encoded = base64Url(encoder.encode(payload))
  return encoded + '.' + await hmac(encoded, secret)
}

async function readSession(request, ctx) {
  const token = parseCookies(request).get(SESSION_COOKIE) || ''
  const parts = token.split('.')
  const secret = sessionSecret(ctx)
  if (!secret || parts.length !== 2) return null
  const expected = await hmac(parts[0], secret)
  if (!(await constantTimeEqual(parts[1], expected))) return null
  let payload
  try { payload = decoder.decode(fromBase64Url(parts[0])) } catch { return null }
  const split = payload.lastIndexOf('.')
  if (split < 1) return null
  const userId = payload.slice(0, split)
  const expires = Number(payload.slice(split + 1))
  if (!Number.isFinite(expires) || expires < Date.now()) return null
  return ctx.db.first('SELECT id, github_id, login, avatar, access_token, default_environment, status_key_hash, status_verified_at FROM users WHERE id = ?', [userId])
}

async function csrfFor(user, ctx) {
  return hmac('csrf:' + user.id, sessionSecret(ctx))
}

async function constantTimeEqual(left, right) {
  const a = encoder.encode(String(left))
  const b = encoder.encode(String(right))
  if (a.length !== b.length) return false
  let value = 0
  for (let i = 0; i < a.length; i += 1) value |= a[i] ^ b[i]
  return value === 0
}

function cookie(request, name, value, maxAge) {
  const url = new URL(request.url)
  const parts = [name + '=' + encodeURIComponent(value), 'Path=/', 'HttpOnly', 'SameSite=Lax', 'Max-Age=' + String(Math.max(0, maxAge))]
  if (url.protocol === 'https:') parts.push('Secure')
  return parts.join('; ')
}

function redirect(location, status, cookies) {
  const headers = new Headers({location: location, 'cache-control': 'no-store'})
  ;(cookies || []).forEach(function (value) { headers.append('set-cookie', value) })
  return new Response(null, {status: status || 303, headers: headers})
}

function contentSecurityPolicy() {
  const connectSources = ["'self'"]
  return "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src https:" + "//avatars.githubusercontent.com data:; connect-src " + connectSources.join(' ') + "; form-action 'self' https://github.com; base-uri 'none'; frame-ancestors 'none'"
}

function html(body, status, cookies) {
  const headers = new Headers({
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'content-security-policy': contentSecurityPolicy(),
    'referrer-policy': 'strict-origin-when-cross-origin',
    'x-content-type-options': 'nosniff',
    'permissions-policy': 'camera=(), microphone=(), geolocation=()',
  })
  ;(cookies || []).forEach(function (value) { headers.append('set-cookie', value) })
  return new Response(body, {status: status || 200, headers: headers})
}

function text(body, status) {
  return new Response(body, {status: status || 200, headers: {'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store'}})
}

function json(body, status) {
  return new Response(JSON.stringify(body), {status: status || 200, headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'}})
}

async function requireForm(request, user, ctx) {
  const form = await request.formData()
  const supplied = String(form.get('csrf') || '')
  const expected = await csrfFor(user, ctx)
  if (!(await constantTimeEqual(supplied, expected))) throw new HttpError(403, 'This form expired. Reload the page and try again.')
  return form
}

class HttpError extends Error {
  constructor(status, message) {
    super(message)
    this.status = status
  }
}

function safeMembers(row) {
  try { return normalizeMembers(JSON.parse(row.members || '[]')) } catch { return [] }
}


function flash(url) {
  const error = url.searchParams.get('error')
  const ok = url.searchParams.get('ok')
  if (error) return '<div class="notice error">' + escapeHtml(error.slice(0, 240)) + '</div>'
  if (ok) return '<div class="notice success">' + escapeHtml(ok.slice(0, 240)) + '</div>'
  return ''
}

function githubClient(user, ctx) {
  if (!user || !user.access_token) throw new HttpError(401, 'Connect GitHub before using repository features.')
  const fetchImpl = ctx.fetch || fetch
  return async function (method, path, body) {
    const response = await fetchImpl('https://api.github.com' + path, {
      method: method,
      headers: {
        accept: 'application/vnd.github+json',
        authorization: 'Bearer ' + user.access_token,
        'content-type': 'application/json',
        'user-agent': 'BlitzOS-Portal',
        'x-github-api-version': '2022-11-28',
      },
      body: body == null ? undefined : JSON.stringify(body),
    })
    if (response.status === 204) return null
    const data = await response.json().catch(function () { return {} })
    if (!response.ok) {
      const details = Array.isArray(data.errors) ? data.errors.map(function (item) { return item && item.message }).filter(Boolean) : []
      const githubMessage = String(details[0] || data.message || 'request failed').slice(0, 180)
      const error = new HttpError(response.status === 404 ? 404 : 502, 'GitHub: ' + githubMessage)
      error.githubStatus = response.status
      error.githubMessage = githubMessage
      throw error
    }
    return data
  }
}

async function listGithubRepos(user, ctx) {
  const api = githubClient(user, ctx)
  const repos = await api('GET', '/user/repos?per_page=100&sort=updated&affiliation=owner%2Ccollaborator%2Corganization_member')
  return Array.isArray(repos) ? repos.filter(function (repo) { return repo && repo.full_name && repo.default_branch }) : []
}

async function listGithubBranches(url, user, ctx) {
  let fullName
  try { fullName = validateFullName(url.searchParams.get('repo')) } catch { throw new HttpError(422, 'Enter a valid GitHub repository name.') }
  const api = githubClient(user, ctx)
  const results = await Promise.all([
    api('GET', '/repos/' + fullName),
    api('GET', '/repos/' + fullName + '/branches?per_page=100&page=1'),
  ])
  const defaultBranch = validateBranch(results[0] && results[0].default_branch)
  const names = [defaultBranch]
  ;(Array.isArray(results[1]) ? results[1] : []).forEach(function (branch) {
    if (!branch || !branch.name) return
    let name
    try { name = validateBranch(branch.name) } catch { return }
    if (!names.includes(name)) names.push(name)
  })
  return {repo: fullName, branches: names.map(function (name) { return {name: name, default: name === defaultBranch} })}
}

function decodeGithubContent(payload) {
  if (!payload || payload.encoding !== 'base64' || typeof payload.content !== 'string') throw new HttpError(422, 'The context repository has no readable .gitmodules file.')
  const binary = atob(payload.content.replace(/\s/g, ''))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
  return decoder.decode(bytes)
}

function assertSingleMemberOwner(members) {
  const owners = new Set(members.map(function (member) { return member.full_name.split('/')[0].toLowerCase() }))
  if (owners.size !== 1) throw new HttpError(422, 'Member repositories must share one GitHub resource owner.')
}

function repoSlug(name) {
  let slug = String(name || '').trim().toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '')
  slug = slug.replace(/-context$/, '')
  if (!slug) throw new HttpError(422, 'Enter a context repo name.')
  return (slug + '-context').slice(0, 100)
}

function landing(ctx) {
  const body = [
    '<section class="lp">',
    '<div class="hero">',
    '<div class="hero-left">',
    '<h1><span>A context manager</span><br><span>for your cloud agents.</span></h1>',
    '<p class="sub">Bundle repos into a context repo. Launch cloud sessions that boot already knowing all of them.</p>',
    '</div>',
    '<div class="ledger">',
    '<span class="tick tl">+</span><span class="tick tr">+</span><span class="tick bl">+</span><span class="tick br">+</span>',
    '<div class="col">',
    '<div class="cell head micro">for individuals — free</div>',
    '<div class="cell copy">Warm Claude sessions from your repos, one click.</div>',
    '<div class="cell facts"><div>zero credentials</div><div>context in your GitHub</div><div>uses your Claude plan</div></div>',
    '<div class="cell"><a class="button accent" href="/auth/github">Sign in with GitHub</a></div>',
    '</div>',
    '</div>',
    '</div>',
    '<div class="pitch-grid">',
    '<article class="pitch"><span class="micro">01 / context repo</span><p>Pick repos and branches. BlitzOS builds a private context repo on your GitHub.</p></article>',
    '<article class="pitch"><span class="micro">02 / launch</span><p>One click opens Claude Code cloud with every repo selected. Add a task and it is prefilled.</p></article>',
    '<article class="pitch"><span class="micro">03 / come back</span><p>Launch history and PRs in one feed. Sessions keep a work log in the context repo.</p></article>',
    '</div>',
    '</section>',
  ].join('')
  return page({
    title: 'BlitzOS | Context manager for cloud coding agents',
    description: 'Bundle repositories into a context set and launch Claude Code cloud with the full context.',
    body: body,
  })
}


async function openPullRequests(repoSets, user, ctx) {
  if (!user.access_token) return new Map()
  const api = githubClient(user, ctx)
  const jobs = []
  const seen = new Set()
  repoSets.forEach(function (set) {
    safeMembers(set).forEach(function (member) {
      if (seen.size >= 24 || seen.has(member.full_name)) return
      seen.add(member.full_name)
      jobs.push(api('GET', '/repos/' + member.full_name + '/pulls?state=open&sort=updated&direction=desc&per_page=3')
        .then(function (items) { return [member.full_name, Array.isArray(items) ? items : []] })
        .catch(function () { return [member.full_name, []] }))
    })
  })
  return new Map(await Promise.all(jobs))
}

function composer(repoSets, csrf) {
  if (!repoSets.length) {
    return '<section class="card"><div class="card-head"><div><span class="micro">launch</span><h2>Give Claude the full picture.</h2></div></div><div class="empty">Create a context repo before launching a cloud session.<br><br><a class="button small accent" href="/repo-sets/new">Create context repo</a></div></section>'
  }
  const options = repoSets.map(function (set) { return '<option value="' + escapeHtml(set.id) + '">' + escapeHtml(set.name) + '</option>' }).join('')
  return [
    '<section class="card"><div class="card-head"><div><span class="micro">new cloud session</span><h2>What should the agent do?</h2></div><span class="tag">zero credentials</span></div>',
    '<form method="post" action="/launch" target="_blank">' + hiddenCsrf(csrf),
    '<div class="vendor-row"><label class="vendor active"><span>Claude Code</span><input type="radio" name="vendor" value="claude" checked></label><label class="vendor disabled"><span>Codex</span><span class="tag">integration in research</span><input type="radio" disabled></label></div>',
    '<div class="field"><label class="label" for="repo_set_id">context repo</label><select class="input" id="repo_set_id" name="repo_set_id" required>' + options + '</select></div>',
    '<div class="field"><label class="label" for="prompt">task (optional)</label><textarea class="input" id="prompt" name="prompt" maxlength="12000" placeholder="Describe the outcome, constraints, and the first useful checkpoint. Leave blank to type it in the composer."></textarea></div>',
    '<div class="composer-actions"><div></div><div class="actions"><button class="button accent" type="submit" name="variant" value="default">Launch agent</button></div></div>',
    '</form></section>',
  ].join('')
}

const SESSION_WORKING_MS = 90 * 1000
const SESSION_QUIET_MS = 15 * 60 * 1000
const SESSION_LAUNCHING_MS = 10 * 60 * 1000

function parseDbTime(value) {
  const raw = String(value || '')
  const ms = Date.parse(raw.replace(' ', 'T') + (raw.includes('Z') ? '' : 'Z'))
  return Number.isFinite(ms) ? ms : 0
}

function relAgo(ms, now) {
  const diff = Math.max(0, now - ms)
  if (diff < 10 * 1000) return 'just now'
  if (diff < 60 * 1000) return Math.floor(diff / 1000) + 's ago'
  if (diff < 60 * 60 * 1000) return Math.floor(diff / 60000) + 'm ago'
  if (diff < 24 * 60 * 60 * 1000) return Math.floor(diff / 3600000) + 'h ago'
  return Math.floor(diff / 86400000) + 'd ago'
}

function sessionView(launch, now) {
  const tracked = String(launch.socket_token_hash || '') !== '' || String(launch.bind_mode || '') !== ''
  const state = String(launch.state || 'launched')
  const eventAt = launch.last_event_at == null ? null : Number(launch.last_event_at)
  if (state === 'completed') return {section: 'previous', dot: 'done', label: 'completed', phase: 'x'}
  if (!tracked) return {section: 'previous', dot: 'untracked', label: 'launched', phase: 'x'}
  if (state === 'active' && eventAt) {
    const age = now - eventAt
    if (age < SESSION_WORKING_MS) return {section: 'active', dot: 'working', label: 'working', phase: 'working'}
    if (age < SESSION_QUIET_MS) return {section: 'active', dot: 'quiet', label: 'quiet ' + Math.max(1, Math.floor(age / 60000)) + 'm', phase: 'quiet'}
    return {section: 'previous', dot: 'ended', label: 'ended ?', phase: 'ended'}
  }
  if (now - parseDbTime(launch.created_at) < SESSION_LAUNCHING_MS) return {section: 'active', dot: 'quiet', label: 'launching', phase: 'launching'}
  return {section: 'previous', dot: 'ended', label: 'no contact', phase: 'nocontact'}
}

function sessionFingerprint(launch, view) {
  const status = String(launch.last_status_text || '')
  return [String(launch.state || 'launched'), launch.session_url ? '1' : '0', launch.archived ? '1' : '0', view.phase, status.length + ':' + status.slice(0, 24)].join('|')
}

function sessionRow(launch, csrf, now) {
  const view = sessionView(launch, now)
  const tracked = String(launch.socket_token_hash || '') !== '' || String(launch.bind_mode || '') !== ''
  const eventAt = launch.last_event_at == null ? null : Number(launch.last_event_at)
  const task = String(launch.prompt || '').trim()
  const taskLine = task ? escapeHtml(task.length > 110 ? task.slice(0, 107) + '...' : task) : '&mdash;'

  let line = ''
  let when = ''
  if (!tracked) {
    line = 'no live status for this launch'
    when = formatTime(launch.created_at)
  } else if (view.phase === 'launching') {
    line = 'waiting for first contact'
    when = 'launched ' + relAgo(parseDbTime(launch.created_at), now)
  } else if (view.phase === 'nocontact') {
    line = 'no hello from the agent — check the Claude GitHub App can access the context repo'
    when = 'launched ' + relAgo(parseDbTime(launch.created_at), now)
  } else {
    line = String(launch.last_status_text || '') || 'connected'
    when = eventAt ? relAgo(eventAt, now) : formatTime(launch.created_at)
  }

  const sessionUrl = String(launch.session_url || '')
  const actions = []
  if (sessionUrl) {
    actions.push('<a class="button small ' + (view.section === 'active' ? 'accent' : 'secondary') + '" href="' + escapeHtml(sessionUrl) + '" target="_blank" rel="noopener noreferrer">Open session</a>')
  } else if (tracked && view.section === 'active') {
    actions.push('<span class="sess-nolink">no session link yet</span>')
  }
  actions.push('<form method="post" action="/launches/' + escapeHtml(launch.id) + '/relaunch" target="_blank">' + hiddenCsrf(csrf) + '<button class="ghost-btn" type="submit">relaunch</button></form>')
  actions.push('<form method="post" action="/launches/' + escapeHtml(launch.id) + '/archive">' + hiddenCsrf(csrf) + '<button class="ghost-btn" type="submit">' + (launch.archived ? 'restore' : 'archive') + '</button></form>')

  return [
    '<div class="sess-row" data-launch="' + escapeHtml(launch.id) + '" data-tracked="' + (tracked ? '1' : '0') + '" data-fp="' + escapeHtml(sessionFingerprint(launch, view)) + '">',
    '<div class="sess-state"><span class="sess-dot ' + view.dot + '"></span>' + escapeHtml(view.label) + '</div>',
    '<div class="sess-what"><div class="sess-group">' + escapeHtml(launch.repo_set_name) + '</div><div class="sess-task">' + taskLine + '</div></div>',
    '<div class="sess-signal"><div class="line">' + escapeHtml(line) + '</div><div class="when">' + escapeHtml(when) + '</div></div>',
    '<div class="sess-actions">' + actions.join('') + '</div>',
    '</div>',
  ].join('')
}

const SESSION_POLLER = [
  '<script>(function(){',
  'var ta=document.getElementById("prompt");',
  'var card=document.getElementById("bz-sessions");',
  'var newestTs=card?(Number(card.getAttribute("data-newest-ts"))||0):0;',
  'var timer=null;',
  'try{var draft=sessionStorage.getItem("bz-task-draft");if(draft&&ta&&!ta.value){ta.value=draft}sessionStorage.removeItem("bz-task-draft")}catch(e){}',
  'function phase(state,tracked,ev,created,now){',
  'if(state==="active"&&tracked&&ev!=null){var a=now-ev;return a<90000?"working":(a<900000?"quiet":"ended")}',
  'if(state==="launched"&&tracked){return now-created<600000?"launching":"nocontact"}',
  'return "x"}',
  'function parseTs(v){var r=String(v||"");var t=Date.parse(r.replace(" ","T")+(r.indexOf("Z")>=0?"":"Z"));return isNaN(t)?0:t}',
  'function doReload(){try{if(ta&&ta.value)sessionStorage.setItem("bz-task-draft",ta.value)}catch(e){}location.reload()}',
  'function tick(){',
  'if(document.hidden||(ta&&document.activeElement===ta)){return schedule()}',
  'fetch("/api/launches/status",{headers:{accept:"application/json"}}).then(function(r){return r.json()}).then(function(list){',
  'if(!Array.isArray(list)){return schedule()}',
  'var rows=document.querySelectorAll("[data-launch]");var byId={};var i;',
  'for(i=0;i<rows.length;i++){byId[rows[i].getAttribute("data-launch")]=rows[i]}',
  'var now=Date.now();var reload=false;',
  'for(i=0;i<list.length;i++){var it=list[i];var row=byId[it.id];',
  'if(!row){if(!it.archived&&parseTs(it.created_at)>newestTs){reload=true;break}continue}',
  'var tracked=row.getAttribute("data-tracked")==="1";',
  'var ev=it.last_event_at==null?null:Number(it.last_event_at);',
  'var status=String(it.last_status_text||"");',
  'var fp=[String(it.state||"launched"),it.session_url?"1":"0",it.archived?"1":"0",phase(String(it.state||"launched"),tracked,ev,parseTs(it.created_at),now),status.length+":"+status.slice(0,24)].join("|");',
  'if(row.getAttribute("data-fp")!==fp){reload=true;break}}',
  'if(reload){doReload()}else{schedule()}',
  '}).catch(function(){schedule()})}',
  'function schedule(){if(timer)clearTimeout(timer);timer=setTimeout(tick,20000)}',
  'document.addEventListener("visibilitychange",function(){if(!document.hidden)tick()});',
  'document.addEventListener("submit",function(e){var f=e.target;if(!f||!f.getAttribute||f.getAttribute("target")!=="_blank")return;',
  'if(ta&&f.contains(ta)){setTimeout(function(){ta.value="";try{sessionStorage.removeItem("bz-task-draft")}catch(err){}},600)}',
  'setTimeout(tick,1500);setTimeout(tick,5000)},true);',
  'schedule()',
  '})()</scr' + 'ipt>',
].join('')

function sessionsCard(launches, csrf, showArchived, now) {
  const visible = launches.filter(function (launch) { return !launch.archived })
  const archivedRows = launches.filter(function (launch) { return Boolean(launch.archived) })
  const active = []
  const previous = []
  visible.forEach(function (launch) {
    if (sessionView(launch, now).section === 'active') active.push(launch)
    else previous.push(launch)
  })
  active.sort(function (a, b) { return (Number(b.last_event_at) || 0) - (Number(a.last_event_at) || 0) })

  const parts = []
  if (!launches.length) {
    parts.push('<div class="empty">No sessions launched yet.</div>')
  } else {
    let first = true
    if (active.length) {
      parts.push('<div class="sess-head' + (first ? ' first' : '') + '"><span class="micro">active &mdash; ' + active.length + '</span></div>')
      parts.push(active.map(function (launch) { return sessionRow(launch, csrf, now) }).join(''))
      first = false
    }
    if (previous.length) {
      parts.push('<div class="sess-head' + (first ? ' first' : '') + '"><span class="micro">previous &mdash; ' + previous.length + '</span></div>')
      parts.push(previous.map(function (launch) { return sessionRow(launch, csrf, now) }).join(''))
      first = false
    }
    if (showArchived && archivedRows.length) {
      parts.push('<div class="sess-head' + (first ? ' first' : '') + '"><span class="micro">archived &mdash; ' + archivedRows.length + '</span></div>')
      parts.push(archivedRows.map(function (launch) { return sessionRow(launch, csrf, now) }).join(''))
    }
    if (archivedRows.length) {
      parts.push(showArchived
        ? '<a class="sess-toggle" href="/">hide archived</a>'
        : '<a class="sess-toggle" href="/?archived=1">show archived (' + archivedRows.length + ')</a>')
    }
  }

  const newestTs = launches.length ? parseDbTime(launches[0].created_at) : 0
  return '<section class="card flat" id="bz-sessions" data-newest-ts="' + newestTs + '"><div class="card-head"><div><span class="micro">sessions</span><h2>Sessions</h2></div></div>' + parts.join('') + SESSION_POLLER + '</section>'
}

function repoSetCard(set, pulls) {
  const members = safeMembers(set)
  const memberTags = members.map(function (member) { return '<span class="member">' + escapeHtml(member.full_name) + ' @ ' + escapeHtml(member.branch) + '</span>' }).join('')
  const prs = []
  members.forEach(function (member) {
    ;(pulls.get(member.full_name) || []).forEach(function (pr) {
      prs.push('<div class="pr"><div><a href="' + escapeHtml(pr.html_url || '#') + '" target="_blank" rel="noopener noreferrer">#' + escapeHtml(pr.number) + ' ' + escapeHtml(pr.title || 'Open pull request') + '</a><div class="pr-repo">' + escapeHtml(member.full_name) + '</div></div><span class="tag">open</span></div>')
    })
  })
  return [
    '<section class="card set-card"><div class="set-title"><div><span class="micro">context repo</span><h3>' + escapeHtml(set.name) + '</h3><div class="repo-name">' + escapeHtml(set.monorepo_full_name) + '</div></div><a class="button small secondary" href="/repo-sets/' + escapeHtml(set.id) + '/edit">Edit</a></div>',
    '<div class="member-list">' + memberTags + '</div>',
    '<div><span class="micro">recent open PRs</span><div class="prs">' + (prs.join('') || '<div class="empty">No open pull requests found.</div>') + '</div></div></section>',
  ].join('')
}

async function feedPage(url, user, csrf, ctx) {
  const repoSets = await ctx.db.all('SELECT * FROM repo_sets WHERE user_id = ? ORDER BY updated_at DESC', [user.id])
  const launches = await ctx.db.all('SELECT l.*, r.name AS repo_set_name FROM launches l JOIN repo_sets r ON r.id = l.repo_set_id WHERE l.user_id = ? ORDER BY l.created_at DESC LIMIT 60', [user.id])
  const pulls = await openPullRequests(repoSets, user, ctx)
  const panels = repoSets.map(function (set) { return repoSetCard(set, pulls) }).join('')
  const showArchived = url.searchParams.get('archived') === '1'
  const hasStatusKey = Boolean(String(user.status_key_hash || '').trim())
  const statusNudge = !hasStatusKey
    ? '<p class="sess-nudge">live status is off &mdash; <a href="/settings">2-minute setup in settings</a></p>'
    : (user.status_verified_at == null ? '<p class="sess-nudge">live status: key set &mdash; waiting for the first session to call home</p>' : '')
  const body = [
    flash(url),
    '<div class="grid"><div class="stack">',
    composer(repoSets, csrf),
    statusNudge,
    sessionsCard(launches, csrf, showArchived, Date.now()),
    '</div><aside class="stack">',
    panels || '<section class="card"><div class="empty">Your context repos will appear here.</div></section>',
    '</aside></div>',
  ].join('')
  return page({title: 'The feed | BlitzOS', body: body, user: user, csrf: csrf})
}

function repoOwner(repo) {
  return String(repo.full_name || '').split('/')[0]
}

function repoGroups(repos, selected, login) {
  const chosen = new Map((selected || []).map(function (member) { return [member.full_name.toLowerCase(), member] }))
  const byOwner = new Map()
  repos.forEach(function (repo) {
    const owner = repoOwner(repo)
    const key = owner.toLowerCase()
    if (!byOwner.has(key)) byOwner.set(key, {owner: owner, repos: []})
    byOwner.get(key).repos.push(repo)
  })
  const ownKey = String(login || '').toLowerCase()
  const groups = Array.from(byOwner.values()).sort(function (left, right) {
    const leftKey = left.owner.toLowerCase()
    const rightKey = right.owner.toLowerCase()
    if (leftKey === ownKey && rightKey !== ownKey) return -1
    if (rightKey === ownKey && leftKey !== ownKey) return 1
    if (leftKey < rightKey) return -1
    if (leftKey > rightKey) return 1
    return 0
  })
  return groups.map(function (group) {
    const rows = group.repos.map(function (repo) {
      const member = chosen.get(String(repo.full_name).toLowerCase())
      const branch = member ? member.branch : repo.default_branch
      const description = repo.description || (repo.private ? 'Private repository' : 'Public repository')
      const search = String(repo.full_name) + ' ' + String(repo.description || '')
      return [
        '<label class="repo-choice" data-owner="' + escapeHtml(group.owner.toLowerCase()) + '" data-repo="' + escapeHtml(repo.full_name) + '" data-search="' + escapeHtml(search.toLowerCase()) + '"><input type="checkbox" name="repo" value="' + escapeHtml(repo.full_name) + '"' + (member ? ' checked' : '') + '>',
        '<span><strong>' + escapeHtml(repo.full_name) + '</strong><span class="help" style="display:block">' + escapeHtml(description) + '</span></span>',
        '<span class="branch-wrap"><select class="input branch branch-control" name="branch:' + escapeHtml(repo.full_name) + '" data-repo="' + escapeHtml(repo.full_name) + '" data-default-branch="' + escapeHtml(repo.default_branch) + '" aria-label="Branch for ' + escapeHtml(repo.full_name) + '"><option value="' + escapeHtml(branch) + '" selected>' + escapeHtml(branch) + '</option></select><span class="branch-status" aria-live="polite"></span></span></label>',
      ].join('')
    }).join('')
    const count = group.repos.length
    return '<section class="repo-owner-group" data-owner="' + escapeHtml(group.owner.toLowerCase()) + '"><div class="repo-owner-head"><strong>' + escapeHtml(group.owner) + '</strong><span>' + String(count) + ' ' + (count === 1 ? 'repository' : 'repositories') + '</span></div><div class="repo-owner-rows">' + rows + '</div></section>'
  }).join('')
}

const REPO_PICKER_SCRIPT = [
  '(function(){',
  "var picker=document.getElementById('repo-picker');if(!picker)return;",
  "var search=document.getElementById('repo-search');var noMatches=document.getElementById('repo-no-matches');var ownerHint=document.getElementById('repo-owner-hint');var cache=Object.create(null);var activeOwner='';",
  "function statusFor(row){return row.querySelector('.branch-status');}",
  "function setStatus(row,message,error){var status=statusFor(row);status.textContent=message;status.classList.toggle('error',Boolean(error));}",
  "function loadBranches(row){var control=row.querySelector('.branch-control');if(!control||control.getAttribute('data-loaded')==='true'||control.getAttribute('data-loading')==='true')return;var repo=row.getAttribute('data-repo');control.setAttribute('data-loading','true');control.setAttribute('aria-busy','true');setStatus(row,'Loading branches...',false);if(!cache[repo]){cache[repo]=fetch('/api/github/branches?repo='+encodeURIComponent(repo),{headers:{accept:'application/json'}}).then(function(response){if(!response.ok)throw new Error('branch request failed');return response.json();}).then(function(body){if(!body||!Array.isArray(body.branches)||!body.branches.length)throw new Error('no branches returned');return body.branches;});}cache[repo].then(function(branches){var current=control.value;var fallback='';var options=[];for(var i=0;i<branches.length;i++){var branch=branches[i];if(!branch||typeof branch.name!=='string')continue;var option=document.createElement('option');option.value=branch.name;option.textContent=branch.name;if(branch.default)fallback=branch.name;options.push(option);}if(!options.length)throw new Error('no branches returned');var preferred=fallback||options[0].value;for(var j=0;j<options.length;j++){if(options[j].value===current){preferred=current;break;}}control.replaceChildren.apply(control,options);control.value=preferred;control.removeAttribute('data-loading');control.removeAttribute('aria-busy');control.setAttribute('data-loaded','true');setStatus(row,'',false);}).catch(function(){delete cache[repo];var input=document.createElement('input');input.className='input branch';input.name=control.name;input.value=control.value;input.setAttribute('data-repo',repo);input.setAttribute('aria-label',control.getAttribute('aria-label'));input.setAttribute('autocomplete','off');control.replaceWith(input);setStatus(row,'Could not load branches; type one instead.',true);});}",
  "function updateOwners(){var checked=picker.querySelectorAll('input[type=checkbox][name=repo]:checked');var activeStillChecked=false;for(var i=0;i<checked.length;i++){if(checked[i].closest('.repo-choice').getAttribute('data-owner')===activeOwner)activeStillChecked=true;}if(!activeStillChecked)activeOwner=checked.length?checked[0].closest('.repo-choice').getAttribute('data-owner'):'';var groups=picker.querySelectorAll('.repo-owner-group');for(var j=0;j<groups.length;j++)groups[j].classList.toggle('is-dimmed',Boolean(activeOwner)&&groups[j].getAttribute('data-owner')!==activeOwner);ownerHint.hidden=!activeOwner;ownerHint.textContent=activeOwner?'Context repos use one owner. '+activeOwner+' is selected; other owner groups are dimmed.':'';}",
  "function filterRows(){var query=search.value.trim().toLowerCase();var groups=picker.querySelectorAll('.repo-owner-group');var visible=0;for(var i=0;i<groups.length;i++){var rows=groups[i].querySelectorAll('.repo-choice');var groupVisible=0;for(var j=0;j<rows.length;j++){var match=!query||rows[j].getAttribute('data-search').indexOf(query)!==-1;rows[j].hidden=!match;if(match){groupVisible++;visible++;}}groups[i].hidden=groupVisible===0;}noMatches.hidden=visible!==0;}",
  "picker.addEventListener('change',function(event){if(event.target.matches('input[type=checkbox][name=repo]')){var row=event.target.closest('.repo-choice');if(event.target.checked){if(!activeOwner)activeOwner=row.getAttribute('data-owner');loadBranches(row);}updateOwners();}});",
  "picker.addEventListener('focusin',function(event){if(event.target.classList.contains('branch-control'))loadBranches(event.target.closest('.repo-choice'));});",
  "search.addEventListener('input',filterRows);updateOwners();filterRows();",
  '})();',
].join('')

const COPY_ICON = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="12" height="12" rx="2"></rect><path d="M5 15a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2"></path></svg>'

const COPY_SCRIPT = [
  '<script>document.addEventListener("click",function(e){',
  'var b=e.target&&e.target.closest?e.target.closest(".copy-btn"):null;if(!b)return;',
  'var w=b.parentElement;var t=w?w.querySelector("[data-copy]"):null;if(!t)return;',
  'var text=t.textContent;',
  'function done(){b.classList.add("copied");setTimeout(function(){b.classList.remove("copied")},1600)}',
  'if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(text).then(done).catch(function(){})}',
  'else{try{var r=document.createRange();r.selectNodeContents(t);var s=getSelection();s.removeAllRanges();s.addRange(r);document.execCommand("copy");s.removeAllRanges();done()}catch(err){}}',
  '});</scr' + 'ipt>',
].join('')

function copyBlock(tag, className, text) {
  return '<span class="copywrap"><button class="copy-btn" type="button" title="Copy" aria-label="Copy to clipboard">' + COPY_ICON + '</button><' + tag + ' class="' + className + '" data-copy>' + escapeHtml(text) + '</' + tag + '></span>'
}

function skillsImportPrompt(fullName) {
  return [
    'I use BlitzOS. Import my local Claude Code skills into my context repo.',
    '',
    '1. List every skill in ~/.claude/skills: folder name plus the description from each SKILL.md. Show me the list and ask which ones to import. Import nothing without my answer.',
    '2. Clone https://github.com/' + fullName + '.git into a temp directory (gh repo clone ' + fullName + ' works).',
    '3. Copy each chosen skill folder into skills/<name>/ in the clone. Before committing, review every file for secrets, tokens, API keys, absolute paths, and machine-specific config — leave anything suspect out and tell me about it instead. Never copy .env or credential files.',
    '4. Commit as "skills: import <names>", push to main, and tell me exactly what was imported.',
  ].join('\n')
}

async function skillsCard(set, user, ctx) {
  let count = 0
  try {
    const entries = await githubClient(user, ctx)('GET', '/repos/' + set.monorepo_full_name + '/contents/skills')
    count = Array.isArray(entries) ? entries.filter(function (entry) { return entry && entry.type === 'dir' }).length : 0
  } catch (error) {
    count = 0
  }
  return [
    '<section class="card" style="max-width:850px"><div class="card-head"><div><span class="micro">skills</span><h2>Skills</h2></div>' + (count > 0 ? '<span class="tag">' + count + ' installed</span>' : '') + '</div>',
    '<p>Skills in <code>skills/</code> travel with this context repo — BlitzOS installs them into your cloud sessions automatically.</p>',
    count > 0 ? '' : '<p class="help">No skills in this repo yet.</p>',
    '<p>Import your local Claude Code skills: paste this into Claude Code on your laptop, from any directory.</p>',
    copyBlock('pre', 'keyblock', skillsImportPrompt(set.monorepo_full_name)),
    '</section>',
  ].join('')
}

async function repoSetFormPage(url, user, csrf, ctx, existing) {
  const mode = existing ? 'edit' : (url.searchParams.get('mode') === 'register' ? 'register' : 'create')
  const allRepos = mode === 'register' || !user.access_token ? [] : await listGithubRepos(user, ctx)
  const selected = existing ? safeMembers(existing) : []
  const title = existing ? 'Edit ' + existing.name : 'New context repo'
  let content
  if (mode === 'register') {
    content = [
      '<form method="post" action="/repo-sets/register">' + hiddenCsrf(csrf),
      '<div class="field"><label class="label" for="name">context repo name</label><input class="input" id="name" name="name" maxlength="100" required></div>',
      '<div class="field"><label class="label" for="full_name">existing context monorepo</label><input class="input code" id="full_name" name="full_name" placeholder="owner/company-context" required><p class="help">BlitzOS verifies the context scaffold and parses member repos from .gitmodules.</p></div>',
      '<div class="field"><label class="label" for="environment_name">Claude environment (optional)</label><input class="input" id="environment_name" name="environment_name" value="' + escapeHtml(user.default_environment || '') + '" maxlength="100"><p class="help">Leave blank to use Claude\'s default environment.</p></div>',
      '<button class="button accent" type="submit">Register context repo</button></form>',
    ].join('')
  } else {
    const action = existing ? '/repo-sets/' + existing.id + '/update' : '/repo-sets/create'
    content = [
      '<form method="post" action="' + escapeHtml(action) + '">' + hiddenCsrf(csrf),
      '<div class="field"><label class="label" for="name">context repo name</label><input class="input" id="name" name="name" value="' + escapeHtml(existing ? existing.name : '') + '" maxlength="100" required></div>',
      '<div class="field"><label class="label" for="environment_name">Claude environment (optional)</label><input class="input" id="environment_name" name="environment_name" value="' + escapeHtml(existing ? existing.environment_name : (user.default_environment || '')) + '" maxlength="100"><p class="help">Leave blank to use Claude\'s default environment.</p></div>',
      !user.access_token ? '<div class="notice error">GitHub is not connected in this preview session. Connect with GitHub to load and create repositories.</div>' : '',
      '<div class="notice">Member repositories must share one GitHub resource owner.</div>',
      '<div class="field repo-search"><label class="label" for="repo-search">search repositories</label><input class="input" id="repo-search" type="search" placeholder="Search by repository or description" autocomplete="off"></div>',
      '<p class="owner-hint" id="repo-owner-hint" aria-live="polite" hidden></p>',
      '<div class="field"><span class="label">member repositories and branches</span><div class="repo-picker" id="repo-picker">' + repoGroups(allRepos, selected, user.login) + '<div class="empty" id="repo-no-matches" hidden>No matching repositories.</div></div></div>',
      '<button class="button accent" type="submit">' + (existing ? 'Commit context repo update' : 'Create context repo') + '</button></form>',
      '<script>' + REPO_PICKER_SCRIPT + '</script>',
    ].join('')
  }
  const tabs = existing ? '' : '<div class="tabs"><a class="tab' + (mode === 'create' ? ' active' : '') + '" href="/repo-sets/new">Create new</a><a class="tab' + (mode === 'register' ? ' active' : '') + '" href="/repo-sets/new?mode=register">Register existing</a></div>'
  const skillsSection = existing ? await skillsCard(existing, user, ctx) : ''
  const body = flash(url) + '<section class="card" style="max-width:850px">' + tabs + content + '</section>' + skillsSection + (existing ? COPY_SCRIPT : '')
  return page({title: title + ' | BlitzOS', body: body, user: user, csrf: csrf})
}

function liveStatusRow(user, csrf) {
  const hasKey = Boolean(String(user.status_key_hash || '').trim())
  const verified = user.status_verified_at != null
  let state
  let actions
  if (!hasKey) {
    state = '<p class="code">off</p><p>Cloud sessions report live status to your feed — working, quiet, done — through a key that lives only in your Claude cloud environment. Nothing is ever added to your prompts.</p>'
    actions = '<form method="post" action="/settings/status-key" style="margin-top:12px">' + hiddenCsrf(csrf) + '<button class="button small accent" type="submit">Generate status key</button></form>'
  } else if (!verified) {
    state = '<p class="code">key set — waiting for the first session to call home</p><p>Launch any session from the feed. This flips to live when the agent connects.</p>'
    actions = '<div class="actions" style="margin-top:12px"><form method="post" action="/settings/status-key">' + hiddenCsrf(csrf) + '<button class="button small secondary" type="submit">Regenerate key</button></form><form method="post" action="/settings/status-key/disable">' + hiddenCsrf(csrf) + '<button class="button small secondary" type="submit">Turn off</button></form></div>'
  } else {
    state = '<p class="code">live — first verified ' + escapeHtml(relAgo(Number(user.status_verified_at), Date.now())) + '</p><p>Sessions launched from the feed report status through your environment key.</p>'
    actions = '<div class="actions" style="margin-top:12px"><form method="post" action="/settings/status-key">' + hiddenCsrf(csrf) + '<button class="button small secondary" type="submit">Regenerate key</button></form><form method="post" action="/settings/status-key/disable">' + hiddenCsrf(csrf) + '<button class="button small secondary" type="submit">Turn off</button></form></div>'
  }
  return '<div class="settings-row"><div><h3>Live session status</h3><p>One-time environment setup. Regenerating invalidates the old key.</p></div><div>' + state + actions + '</div></div>'
}

function statusHookCommand(origin) {
  return '[ -s "$HOME/.blitzos-channel" ] || [ -z "$BLITZOS_STATUS_KEY" ] || { curl -sS -m 10 -X POST -H \'content-type: application/json\' -d "{\\"key\\":\\"$BLITZOS_STATUS_KEY\\",\\"session_id\\":\\"$CLAUDE_CODE_REMOTE_SESSION_ID\\"}" ' + origin + '/v1/session/hello > /tmp/.blitzos-hello 2>/dev/null; [ -s /tmp/.blitzos-hello ] && tee "$HOME/.blitzos-channel" < /tmp/.blitzos-hello; }; copied=0; for s in /home/user/*/skills; do [ -d "$s" ] && mkdir -p "$HOME/.claude/skills" && cp -R "$s/." "$HOME/.claude/skills/" 2>/dev/null && copied=1; done; [ "$copied" = 1 ] && echo "blitzos: skills from your repos are installed in this session"'
}

function statusSetupScript(origin) {
  const settings = {hooks: {SessionStart: [{hooks: [{type: 'command', command: statusHookCommand(origin)}]}]}}
  return 'mkdir -p /home/user/.claude\ncat > /home/user/.claude/settings.json <<\'BZEOF\'\n' + JSON.stringify(settings, null, 2) + '\nBZEOF'
}

function statusKeyPage(key, user, csrf, origin) {
  const envDefault = String(user.default_environment || '').trim()
  const portalHostname = new URL(origin).hostname
  const body = [
    '<section class="card" style="max-width:720px"><div class="card-head"><div><span class="micro">live session status</span><h2>Your status key</h2></div></div>',
    '<p>Copy this line into your Claude cloud environment now. It is shown only this once — BlitzOS keeps a hash, not the key.</p>',
    copyBlock('code', 'keyline', 'BLITZOS_STATUS_KEY=' + key),
    '<ol class="recipe">',
    '<li>Open <a href="https://claude.ai/code" target="_blank" rel="noopener noreferrer">claude.ai/code</a> &rarr; environment picker &rarr; <strong>New cloud environment</strong> (or edit the one you already use for BlitzOS).</li>',
    '<li>Network access: <strong>Custom</strong>. Allowlist these, one per line — package installs fail inside sessions for anything not listed:' + copyBlock('pre', 'keyblock', portalHostname + '\nregistry.npmjs.org') + '<p class="help">Using pip too? Add <code>pypi.org</code> and <code>files.pythonhosted.org</code>. Tools that fetch their own binaries name the blocked domain in the session when they fail.</p></li>',
    '<li>Environment variables: paste the line above.</li>',
    '<li>Setup script: paste this block. It installs a session hook that connects the status channel automatically at boot, before the agent starts:' + copyBlock('pre', 'keyblock', statusSetupScript(origin)) + '</li>',
    '<li>Save, then put the environment name on your context repo (edit page) or as your settings default' + (envDefault ? ' — yours is &ldquo;' + escapeHtml(envDefault) + '&rdquo;' : '') + '.</li>',
    '<li>Launch any session from the feed. Settings flips to live when the agent calls home.</li>',
    '</ol>',
    '<p class="help">Anthropic notes environment variables are visible to anyone using the environment — use a personal environment, not a shared one.</p>',
    '<div class="actions" style="margin-top:16px"><a class="button small" href="/settings">Done</a></div>',
    COPY_SCRIPT,
    '</section>',
  ].join('')
  return page({title: 'Status key | BlitzOS', body: body, user: user, csrf: csrf})
}

function settingsPage(url, user, csrf) {
  const connected = Boolean(user.access_token)
  const body = [
    flash(url),
    '<section class="card"><div class="settings-row"><div><h3>GitHub connection</h3><p>Used for your private repositories and context monorepos.</p></div><div><p class="code">' + (connected ? 'Connected as @' + escapeHtml(user.login) : 'Not connected') + '</p>',
    '<p>BlitzOS currently requests the GitHub <strong>repo</strong> scope. A per-repo GitHub App is coming.</p>',
    connected ? '<form method="post" action="/settings/disconnect" style="margin-top:12px">' + hiddenCsrf(csrf) + '<button class="button small secondary" type="submit">Disconnect GitHub</button></form>' : '<a class="button small accent" href="/auth/github" style="margin-top:12px">Connect GitHub</a>',
    '</div></div>',
    liveStatusRow(user, csrf),
    '<div class="settings-row"><div><h3>Environment default</h3><p>Optional. Leave blank to use Claude\'s default environment for new context repos.</p></div><form method="post" action="/settings/environment">' + hiddenCsrf(csrf) + '<div class="field"><label class="label" for="default_environment">environment name</label><input class="input" id="default_environment" name="default_environment" value="' + escapeHtml(user.default_environment || '') + '" maxlength="100"></div><button class="button small" type="submit">Save default</button></form></div>',
    '<div class="settings-row"><div><h3>Delete portal data</h3><p>Deletes launches, context repos, the stored GitHub token, and your portal user. GitHub repositories are not deleted.</p></div><form method="post" action="/settings/delete">' + hiddenCsrf(csrf) + '<button class="button small danger" type="submit">Delete my portal data</button></form></div></section>',
  ].join('')
  return page({title: 'Settings | BlitzOS', body: body, user: user, csrf: csrf})
}

function selectedMembers(form) {
  const repos = form.getAll('repo').map(function (value) { return validateFullName(value) })
  const members = repos.map(function (fullName) {
    return {full_name: fullName, branch: validateBranch(form.get('branch:' + fullName) || 'main')}
  })
  const normalized = normalizeMembers(members)
  assertSingleMemberOwner(normalized)
  return normalized
}

async function registerContext(form, user, ctx) {
  const api = githubClient(user, ctx)
  const fullName = validateFullName(form.get('full_name'))
  const repo = await api('GET', '/repos/' + fullName)
  const branch = validateBranch(repo.default_branch || 'main')
  const required = ['CLAUDE.md', 'bootstrap.sh', 'docs/CLOUD-SETUP.md', 'sessions/INDEX.md']
  const checks = await Promise.all(required.map(function (path) {
    return api('GET', '/repos/' + fullName + '/contents/' + path.split('/').map(encodeURIComponent).join('/') + '?ref=' + encodeURIComponent(branch))
  }))
  if (checks.some(function (item) { return !item || item.type !== 'file' })) throw new HttpError(422, 'The repository does not match the BlitzOS context format.')
  const moduleFile = await api('GET', '/repos/' + fullName + '/contents/.gitmodules?ref=' + encodeURIComponent(branch))
  const members = parseGitmodules(decodeGithubContent(moduleFile))
  assertSingleMemberOwner(members)
  return {full_name: fullName, members: members}
}

async function launchResponse(form, user, ctx, origin, promptOverride, setOverride, variantOverride) {
  const repoSetId = setOverride ? setOverride.id : String(form.get('repo_set_id') || '')
  const set = setOverride || await ctx.db.first('SELECT * FROM repo_sets WHERE id = ? AND user_id = ?', [repoSetId, user.id])
  if (!set) throw new HttpError(404, 'Context repo not found.')
  const prompt = promptOverride == null ? String(form.get('prompt') || '') : String(promptOverride)
  const variant = variantOverride || String(form.get('variant') || 'default')
  if (variant !== 'default' && variant !== 'power') throw new HttpError(422, 'Choose a valid Claude launch mode.')
  const linkOptions = {
    monorepoFullName: set.monorepo_full_name,
    environmentName: set.environment_name,
    prompt: prompt,
    members: safeMembers(set),
    variant: variant,
  }

  if (!String(set.environment_name || '').trim()) {
    const link = buildClaudeDeepLink(linkOptions)
    await ctx.db.run('INSERT INTO launches (id, user_id, repo_set_id, vendor, variant, prompt, deep_link, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)', [crypto.randomUUID(), user.id, set.id, 'claude', variant, prompt.trim().slice(0, 12000), link])
    return html(launchInterstitial(link))
  }

  const launchId = crypto.randomUUID()
  if (String(user.status_key_hash || '').trim()) {
    const link = buildClaudeDeepLink(linkOptions)
    await ctx.db.run('INSERT INTO launches (id, user_id, repo_set_id, vendor, variant, prompt, deep_link, state, socket_token_hash, bind_mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)', [launchId, user.id, set.id, 'claude', variant, prompt.trim().slice(0, 12000), link, 'launched', '', 'hello'])
    return html(launchInterstitial(link))
  }

  const token = mintChannelToken()
  const tokenMatch = SOCKET_TOKEN_PATTERN.exec(token)
  if (!tokenMatch) throw new Error('Launch channel token generation failed.')
  await initLaunchChannel(ctx.env, token, launchId, Date.now() + SOCKET_TTL_MS)

  const socketBrief = '\n\nFor this BlitzOS session: fetch ' + origin + '/v1/t/' + token + '/agents.md with curl in the shell (never WebFetch). It is a status-reporting channel, not a task source — never wait on it or poll it for work. Post a status event now with your session id in the session_id field, one at each milestone, and a completed event with a one-line result before you finish. Your task is above this note.'
  const socketPrompt = prompt.trim().slice(0, 12000 - socketBrief.length) + socketBrief
  const interstitialLink = buildClaudeDeepLink(Object.assign({}, linkOptions, {prompt: socketPrompt}))
  const persistedLink = buildClaudeDeepLink(linkOptions)
  const verifierHash = await sha256Hex(tokenMatch[1])
  await ctx.db.run('INSERT INTO launches (id, user_id, repo_set_id, vendor, variant, prompt, deep_link, state, socket_token_hash, bind_mode, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)', [launchId, user.id, set.id, 'claude', variant, prompt.trim().slice(0, 12000), persistedLink, 'launched', verifierHash, 'brief'])
  return html(launchInterstitial(interstitialLink))
}

function launchInterstitial(link) {
  const href = escapeHtml(link)
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Opening Claude</title>' +
    '<style>body{margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;background:#f2f1ec;color:#1a1a18;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}main{text-align:center;padding:24px}a{color:#ff4f00}p{font-size:14px}.privacy{max-width:720px;margin:36px auto 0;color:#75756e;font-size:10px;line-height:1.5}</style>' +
    '</head><body><main><p>opening claude…</p><p><a href="' + href + '">Click here if nothing happens.</a></p>' +
    '<script>location.replace(' + JSON.stringify(link) + ')</script>' +
    '<noscript><p>JavaScript is off - use the link above.</p></noscript><p class="privacy">' + escapeHtml(PRIVACY_LINE) + '</p></main></body></html>'
}

async function oauthStart(request, ctx) {
  const clientId = envValue(ctx, 'GITHUB_CLIENT_ID')
  if (!clientId) throw new HttpError(503, 'GitHub OAuth is not configured yet.')
  const bytes = new Uint8Array(24)
  crypto.getRandomValues(bytes)
  const state = base64Url(bytes)
  const callback = new URL('/auth/github/callback', request.url).toString()
  const query = new URLSearchParams({client_id: clientId, redirect_uri: callback, scope: 'repo', state: state})
  return redirect('https://github.com/login/oauth/authorize?' + query.toString(), 302, [cookie(request, OAUTH_COOKIE, state, 600)])
}

async function oauthCallback(request, ctx) {
  const url = new URL(request.url)
  const state = url.searchParams.get('state') || ''
  const expected = parseCookies(request).get(OAUTH_COOKIE) || ''
  const code = url.searchParams.get('code') || ''
  if (!code || !(await constantTimeEqual(state, expected))) throw new HttpError(400, 'GitHub sign-in could not be verified.')
  const response = await (ctx.fetch || fetch)('https://github.com/login/oauth/access_token', {
    method: 'POST',
    headers: {accept: 'application/json', 'content-type': 'application/json', 'user-agent': 'BlitzOS-Portal'},
    body: JSON.stringify({client_id: envValue(ctx, 'GITHUB_CLIENT_ID'), client_secret: envValue(ctx, 'GITHUB_CLIENT_SECRET'), code: code}),
  })
  const tokenData = await response.json().catch(function () { return {} })
  if (!response.ok || !tokenData.access_token) throw new HttpError(502, 'GitHub did not return an access token.')
  const profileResponse = await (ctx.fetch || fetch)('https://api.github.com/user', {
    headers: {accept: 'application/vnd.github+json', authorization: 'Bearer ' + tokenData.access_token, 'user-agent': 'BlitzOS-Portal', 'x-github-api-version': '2022-11-28'},
  })
  const profile = await profileResponse.json().catch(function () { return {} })
  if (!profileResponse.ok || !profile.id || !profile.login) throw new HttpError(502, 'GitHub profile lookup failed.')
  const allowedLogins = envValue(ctx, 'ALLOWED_LOGINS')
  if (allowedLogins) {
    const allowed = allowedLogins.split(',').map(function (login) { return login.trim().toLowerCase() }).filter(Boolean)
    if (!allowed.includes(String(profile.login).trim().toLowerCase())) {
      throw new HttpError(403, 'This portal is private. Ask the owner to add your GitHub username to ALLOWED_LOGINS.')
    }
  }
  const current = await ctx.db.first('SELECT id FROM users WHERE github_id = ?', [String(profile.id)])
  const userId = current ? current.id : crypto.randomUUID()
  await ctx.db.run('INSERT INTO users (id, github_id, login, avatar, access_token, default_environment, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) ON CONFLICT(github_id) DO UPDATE SET login = excluded.login, avatar = excluded.avatar, access_token = excluded.access_token, updated_at = CURRENT_TIMESTAMP', [userId, String(profile.id), String(profile.login), String(profile.avatar_url || ''), String(tokenData.access_token), ''])
  const session = await makeSession(userId, ctx)
  return redirect('/', 303, [cookie(request, SESSION_COOKIE, session, 30 * 24 * 60 * 60), cookie(request, OAUTH_COOKIE, '', 0)])
}

function errorPage(error, user, csrf) {
  const exposed = error instanceof HttpError || error instanceof ContextRepositoryError
  const status = exposed ? error.status : 500
  const message = exposed ? error.message : 'Something went wrong. Try again.'
  const body = '<div class="page-head"><div><span class="micro">request stopped</span><h1>Could not complete that.</h1><p>' + escapeHtml(message) + '</p></div></div><a class="button secondary" href="' + (user ? '/' : '/auth/github') + '">Go back</a>'
  return html(page({title: 'Request stopped | BlitzOS', body: body, user: user, csrf: csrf}), status)
}

function sitemapXml(origin) {
  const pages = [origin + '/']
  const entries = pages.map(function (loc) { return '<url><loc>' + loc + '</loc></url>' }).join('')
  return '<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' + entries + '</urlset>'
}

function robotsTxt(origin) {
  return ['User-agent: *', 'Allow: /', 'Disallow: /auth/', 'Disallow: /admin', 'Disallow: /dev-' + 'login', 'Disallow: /launch', 'Disallow: /repo-sets/', 'Disallow: /settings', 'Disallow: /v1/', '', 'Sitemap: ' + origin + '/sitemap.xml'].join('\n') + '\n'
}

export async function handlePortal(request, ctx) {
  const url = new URL(request.url)
  const path = url.pathname.replace(/\/+$/, '') || '/'
  let user = null
  let csrf = ''
  try {
    user = await readSession(request, ctx)
    if (user) csrf = await csrfFor(user, ctx)


    if (request.method === 'GET' && path === '/health') return text('ok')
    if (request.method === 'GET' && path === '/sitemap.xml') return new Response(sitemapXml(url.origin), {headers: {'content-type': 'application/xml; charset=utf-8', 'cache-control': 'public, max-age=3600'}})
    if (request.method === 'GET' && path === '/robots.txt') return new Response(robotsTxt(url.origin), {headers: {'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=3600'}})
    if (request.method === 'GET' && path === '/auth/github') return await oauthStart(request, ctx)
    if (request.method === 'GET' && path === '/auth/github/callback') return await oauthCallback(request, ctx)

    if (request.method === 'GET' && path === '/') {
      if (!user) return html(landing(ctx))
      return html(await feedPage(url, user, csrf, ctx))
    }

    if (!user) return redirect('/auth/github', 303)

    if (request.method === 'GET' && path === '/api/github/branches') return json(await listGithubBranches(url, user, ctx))
    if (request.method === 'GET' && path === '/api/launches/status') {
      const launches = await ctx.db.all('SELECT id, repo_set_id, prompt AS task, state, session_url, last_event_at, last_status_text, archived, bind_mode, created_at FROM launches WHERE user_id = ? ORDER BY created_at DESC LIMIT 100', [user.id])
      return json(launches)
    }
    if (request.method === 'POST' && path === '/auth/logout') {
      await requireForm(request, user, ctx)
      return redirect('/', 303, [cookie(request, SESSION_COOKIE, '', 0)])
    }
    if (request.method === 'GET' && path === '/repo-sets/new') return html(await repoSetFormPage(url, user, csrf, ctx, null))
    if (request.method === 'POST' && path === '/repo-sets/create') {
      const form = await requireForm(request, user, ctx)
      const members = selectedMembers(form)
      const name = String(form.get('name') || '').trim().slice(0, 100)
      const environment = String(form.get('environment_name') || '').trim().slice(0, 100)
      const created = await createContextRepository(githubClient(user, ctx), {owner: user.login, repoName: repoSlug(name), companyName: name, environmentName: environment, members: members, portalOrigin: url.origin})
      await ctx.db.run('INSERT INTO repo_sets (id, user_id, name, monorepo_full_name, environment_name, members, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)', [crypto.randomUUID(), user.id, name, created.full_name, environment, JSON.stringify(members)])
      return redirect('/?ok=' + encodeURIComponent('Context repo created.'))
    }
    if (request.method === 'POST' && path === '/repo-sets/register') {
      const form = await requireForm(request, user, ctx)
      const name = String(form.get('name') || '').trim().slice(0, 100)
      if (!name) throw new HttpError(422, 'Enter a context repo name.')
      const environment = String(form.get('environment_name') || '').trim().slice(0, 100)
      const registered = await registerContext(form, user, ctx)
      await ctx.db.run('INSERT INTO repo_sets (id, user_id, name, monorepo_full_name, environment_name, members, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)', [crypto.randomUUID(), user.id, name, registered.full_name, environment, JSON.stringify(registered.members)])
      return redirect('/?ok=' + encodeURIComponent('Existing context repo registered.'))
    }

    let match = path.match(/^\/repo-sets\/([^/]+)\/edit$/)
    if (request.method === 'GET' && match) {
      const set = await ctx.db.first('SELECT * FROM repo_sets WHERE id = ? AND user_id = ?', [match[1], user.id])
      if (!set) throw new HttpError(404, 'Context repo not found.')
      return html(await repoSetFormPage(url, user, csrf, ctx, set))
    }
    match = path.match(/^\/repo-sets\/([^/]+)\/update$/)
    if (request.method === 'POST' && match) {
      const set = await ctx.db.first('SELECT * FROM repo_sets WHERE id = ? AND user_id = ?', [match[1], user.id])
      if (!set) throw new HttpError(404, 'Context repo not found.')
      const form = await requireForm(request, user, ctx)
      const members = selectedMembers(form)
      const name = String(form.get('name') || '').trim().slice(0, 100)
      if (!name) throw new HttpError(422, 'Enter a context repo name.')
      const environment = String(form.get('environment_name') || '').trim().slice(0, 100)
      await updateContextRepository(githubClient(user, ctx), {fullName: set.monorepo_full_name, companyName: name, environmentName: environment, members: members, previousMembers: safeMembers(set), portalOrigin: url.origin})
      await ctx.db.run('UPDATE repo_sets SET name = ?, environment_name = ?, members = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND user_id = ?', [name, environment, JSON.stringify(members), set.id, user.id])
      return redirect('/?ok=' + encodeURIComponent('Context repo updated with a new commit.'))
    }
    if (request.method === 'POST' && path === '/launch') {
      const form = await requireForm(request, user, ctx)
      if (String(form.get('vendor') || '') !== 'claude') throw new HttpError(422, 'Only Claude Code is available in portal v0.')
      return await launchResponse(form, user, ctx, url.origin)
    }
    match = path.match(/^\/launches\/([^/]+)\/relaunch$/)
    if (request.method === 'POST' && match) {
      const form = await requireForm(request, user, ctx)
      const launch = await ctx.db.first('SELECT l.prompt, l.variant, r.* FROM launches l JOIN repo_sets r ON r.id = l.repo_set_id WHERE l.id = ? AND l.user_id = ?', [match[1], user.id])
      if (!launch) throw new HttpError(404, 'Launch not found.')
      return await launchResponse(form, user, ctx, url.origin, launch.prompt, launch, launch.variant)
    }
    match = path.match(/^\/launches\/([^/]+)\/archive$/)
    if (request.method === 'POST' && match) {
      await requireForm(request, user, ctx)
      const launch = await ctx.db.first('SELECT id FROM launches WHERE id = ? AND user_id = ?', [match[1], user.id])
      if (!launch) throw new HttpError(404, 'Launch not found.')
      await ctx.db.run('UPDATE launches SET archived = CASE archived WHEN 0 THEN 1 ELSE 0 END WHERE id = ? AND user_id = ?', [launch.id, user.id])
      return redirect('/')
    }
    if (request.method === 'GET' && path === '/settings') return html(settingsPage(url, user, csrf))
    if (request.method === 'POST' && path === '/settings/status-key') {
      await requireForm(request, user, ctx)
      const key = mintStatusKey()
      await ctx.db.run('UPDATE users SET status_key_hash = ?, status_verified_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = ?', [await sha256Hex(key), user.id])
      return html(statusKeyPage(key, user, csrf, url.origin))
    }
    if (request.method === 'POST' && path === '/settings/status-key/disable') {
      await requireForm(request, user, ctx)
      await ctx.db.run("UPDATE users SET status_key_hash = '', status_verified_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = ?", [user.id])
      return redirect('/settings?ok=' + encodeURIComponent('Live status turned off.'))
    }
    if (request.method === 'POST' && path === '/settings/environment') {
      const form = await requireForm(request, user, ctx)
      const environment = String(form.get('default_environment') || '').trim().slice(0, 100)
      await ctx.db.run('UPDATE users SET default_environment = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?', [environment, user.id])
      return redirect('/settings?ok=' + encodeURIComponent('Environment default saved.'))
    }
    if (request.method === 'POST' && path === '/settings/disconnect') {
      await requireForm(request, user, ctx)
      await ctx.db.run('UPDATE users SET access_token = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?', ['', user.id])
      return redirect('/', 303, [cookie(request, SESSION_COOKIE, '', 0)])
    }
    if (request.method === 'POST' && path === '/settings/delete') {
      await requireForm(request, user, ctx)
      await ctx.db.run('DELETE FROM launches WHERE user_id = ?', [user.id])
      await ctx.db.run('DELETE FROM repo_sets WHERE user_id = ?', [user.id])
      await ctx.db.run('DELETE FROM users WHERE id = ?', [user.id])
      return redirect('/', 303, [cookie(request, SESSION_COOKIE, '', 0)])
    }
    return text('Not found', 404)
  } catch (error) {
    if (path === '/api/github/branches' || path === '/api/launches/status') {
      const exposed = error instanceof HttpError || error instanceof ContextRepositoryError
      return json({error: exposed ? error.message : 'Something went wrong. Try again.'}, exposed ? error.status : 500)
    }
    return errorPage(error, user, csrf)
  }
}
