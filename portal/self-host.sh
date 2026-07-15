#!/bin/bash
# BlitzOS portal, self-hosted on your Cloudflare account.
# Requires: Node 18+, a Cloudflare account (free plan works), a GitHub account.
# Safe to re-run: every step checks before it changes anything.
set -euo pipefail

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

command -v node >/dev/null || die "Node 18+ is required (https://nodejs.org)"
command -v npx >/dev/null || die "npx not found (comes with Node)"
[ -f wrangler.jsonc ] || die "run this from the portal directory (wrangler.jsonc not found)"

say "1/6 Cloudflare login"
npx wrangler whoami >/dev/null 2>&1 || npx wrangler login

say "2/6 Database"
DB_NAME="blitzos-selfhost-db"
WORKER_NAME=$(node -e 'const s=require("fs").readFileSync("wrangler.jsonc","utf8");process.stdout.write((s.match(/"name":\s*"([^"]+)"/)||[])[1]||"")')
if grep -q '__DATABASE_ID__' wrangler.jsonc; then
  # Fresh setup: refuse to touch anything that already exists in this account.
  if npx wrangler deployments list >/dev/null 2>&1; then
    die "a worker named '$WORKER_NAME' already exists in this Cloudflare account.
This script never overwrites an existing worker. If it is left over from a
previous run, delete it in the dashboard (Workers & Pages) and re-run.
Otherwise pick a different \"name\" in wrangler.jsonc."
  fi
  EXISTING_ID=$(npx wrangler d1 list --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const db=JSON.parse(s).find(d=>d.name==="'"$DB_NAME"'");process.stdout.write(db?db.uuid:"")}catch(e){process.stdout.write("")}})')
  if [ -n "$EXISTING_ID" ]; then
    die "a D1 database named '$DB_NAME' already exists in this account.
This script never adopts an existing database automatically. To reuse it,
paste its id ($EXISTING_ID) into wrangler.jsonc as database_id. To start
clean, delete it in the dashboard first."
  fi
  say "creating D1 database $DB_NAME"
  CREATE_OUT=$(npx wrangler d1 create "$DB_NAME" 2>&1) || die "d1 create failed: $CREATE_OUT"
  DB_ID=$(printf '%s' "$CREATE_OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  [ -n "$DB_ID" ] || die "could not determine the D1 database id"
  node -e 'const fs=require("fs");fs.writeFileSync("wrangler.jsonc",fs.readFileSync("wrangler.jsonc","utf8").replace("__DATABASE_ID__",process.argv[1]))' "$DB_ID"
  echo "database id written to wrangler.jsonc"
else
  echo "existing setup detected (database id configured), skipping creation guards"
fi

say "3/6 Migrations"
npx wrangler d1 migrations apply "$DB_NAME" --remote

say "4/6 First deploy"
DEPLOY_OUT=$(npx wrangler deploy 2>&1) || die "deploy failed: $DEPLOY_OUT"
PORTAL_URL=$(printf '%s' "$DEPLOY_OUT" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1)
[ -n "$PORTAL_URL" ] || PORTAL_URL="https://<your-worker>.workers.dev (check: npx wrangler deployments list)"
echo "portal deployed: $PORTAL_URL"

say "5/6 GitHub OAuth App"
if grep -q '__GITHUB_CLIENT_ID__' wrangler.jsonc; then
  cat <<INSTRUCTIONS

Open https://github.com/settings/applications/new and create an OAuth App
(this is under "OAuth Apps", NOT "GitHub Apps"):

  Application name:            anything you like (e.g. "my blitzos portal")
  Homepage URL:                $PORTAL_URL
  Authorization callback URL:  $PORTAL_URL/auth/github/callback

Click "Register application", then "Generate a new client secret".
The secret is shown exactly once, copy it now.

INSTRUCTIONS
  read -r -p "Client ID: " CLIENT_ID
  [ -n "$CLIENT_ID" ] || die "client id is required"
  node -e 'const fs=require("fs");fs.writeFileSync("wrangler.jsonc",fs.readFileSync("wrangler.jsonc","utf8").replace("__GITHUB_CLIENT_ID__",process.argv[1]))' "$CLIENT_ID"
  read -r -s -p "Client secret (input hidden): " CLIENT_SECRET; echo
  [ -n "$CLIENT_SECRET" ] || die "client secret is required"
  printf '%s' "$CLIENT_SECRET" | npx wrangler secret put GITHUB_CLIENT_SECRET
else
  echo "client id already configured, skipping (rotate the secret anytime with: npx wrangler secret put GITHUB_CLIENT_SECRET)"
fi

if ! npx wrangler secret list 2>/dev/null | grep -q SESSION_SECRET; then
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))' | npx wrangler secret put SESSION_SECRET
  echo "SESSION_SECRET generated and stored"
fi

say "6/6 Final deploy"
read -r -p "Restrict sign-in to specific GitHub usernames? (comma-separated, empty = anyone can sign in): " LOGINS || true
if [ -n "${LOGINS:-}" ]; then
  node -e 'const fs=require("fs");fs.writeFileSync("wrangler.jsonc",fs.readFileSync("wrangler.jsonc","utf8").replace(/"ALLOWED_LOGINS":\s*"[^"]*"/,`"ALLOWED_LOGINS": "${process.argv[1]}"`))' "$LOGINS"
fi
npx wrangler deploy >/dev/null

say "Done."
cat <<NEXT
Your portal: $PORTAL_URL

Next:
  1. Open it and sign in with GitHub.
  2. Create a context repo from the repos that belong together, and launch.
  3. Optional, for the live agent feed: see "The live feed" in SELF-HOSTING.md
     (one 2-minute setting in your Claude cloud environment).
NEXT
