# Self-hosting the BlitzOS portal

Run the same portal that powers the hosted BlitzOS service on your own Cloudflare account. Your GitHub OAuth app, your database, your domain. Nothing touches BlitzOS servers.

What you get: sign in with GitHub, bundle repos into context repos, one-click multi-repo launches into Claude Code cloud, and a live feed showing every cloud agent's status (working / quiet / done) on your own domain.

Takes about 10 minutes. The only fiddly part is creating your GitHub OAuth App, and the script walks you through it.

## Prerequisites

- A Cloudflare account. The free plan is enough (Workers, D1, and Durable Objects are all within free-tier limits for personal use).
- Node 18 or newer.
- A GitHub account.

## Setup

```sh
git clone https://github.com/blitzdotdev/blitzos.git
cd blitzos/portal
./self-host.sh
```

The script does six things, in order, and is safe to re-run:

1. Logs you into Cloudflare (opens a browser the first time).
2. Checks nothing with these names exists yet (it never overwrites existing workers or databases), then creates a D1 database named `blitzos-selfhost-db` and writes its id into `wrangler.jsonc`.
3. Applies the database migrations.
4. Deploys the worker and prints your portal URL (something like `https://blitzos-portal-selfhost.your-subdomain.workers.dev`).
5. Walks you through creating your GitHub OAuth App (details below), then stores the client id and secret.
6. Generates a session secret, optionally restricts sign-in to your username, and deploys again.

## The GitHub OAuth App (the part people get wrong)

The portal signs users in with GitHub, so it needs its own OAuth App. Two minutes:

1. Go to https://github.com/settings/applications/new. Make sure you are creating an **OAuth App**. A "GitHub App" is a different thing and will not work here.
2. Fill exactly three fields (the script prints your real URL to paste):

| Field | Value |
|---|---|
| Application name | anything, only you see it |
| Homepage URL | `https://your-portal-url.workers.dev` |
| Authorization callback URL | `https://your-portal-url.workers.dev/auth/github/callback` |

3. Register, then click "Generate a new client secret". GitHub shows the secret **once**. Copy it immediately.
4. Paste the Client ID and the secret into the script when it asks. The secret is stored as an encrypted Cloudflare secret, never in a file.

Common failures, all caused by the callback URL: a trailing slash, `http` instead of `https`, or a typo'd subdomain make GitHub show "redirect_uri mismatch" at sign-in. The callback must match character for character.

## The live feed (optional, 2 minutes)

Launched agents can report status back to your portal so the feed shows working / quiet / done live. Cloud VMs only reach domains you allow, so:

1. In the claude.ai cloud environment you launch with, set Network access to **Custom**.
2. Add your portal domain to the allowlist, next to the package registries you already allow. Your portal's Settings page shows the exact list to copy for your instance.

Skip this and everything still works; the feed just cannot show live status.

## Keeping it private

By default anyone with a GitHub account could sign in to your portal. Set `ALLOWED_LOGINS` in `wrangler.jsonc` (comma-separated GitHub usernames) to lock it down. The setup script asks about this at the end. Change it later by editing the value and running `npm run deploy`.

## Custom domain (optional)

Cloudflare dashboard, your worker, Settings, Domains & Routes, add your domain. Then update the two URLs in your GitHub OAuth App to match. Nothing else changes.

## Updating

```sh
git pull
npm run migrate   # applies any new database migrations
npm run deploy
```

## Troubleshooting

- The script aborts with "already exists": it found a worker or database with the same name in your account and refuses to overwrite it. That protects anything else you run on Cloudflare. Follow the message: delete the leftover, or rename in `wrangler.jsonc`.
- "redirect_uri mismatch" at sign-in: your OAuth App callback URL does not exactly match your portal URL. Fix it in GitHub settings.
- Sign-in works but repos are missing: the portal lists repos your OAuth token can see. Organization repos may need the org to approve OAuth App access (GitHub org settings, Third-party access).
- Deploy fails mentioning workers.dev: enable your workers.dev subdomain once in the Cloudflare dashboard (Workers & Pages, your subdomain).
- Feed never shows status: the environment allowlist step above is missing, or the launched session was started outside the portal.
- Want to start over: delete the worker and the D1 database in the Cloudflare dashboard and re-run the script.

## Security notes

- Secrets (`GITHUB_CLIENT_SECRET`, `SESSION_SECRET`) live only in Cloudflare's encrypted secret store. Do not put them in files.
- The portal stores your GitHub OAuth token in your own D1 database to list repos and create context repos on your behalf. It is your instance; the data goes nowhere else.
- Repository code is never copied: context repos pin member repos by reference, and cloud sessions access code through Anthropic's own GitHub integration.
