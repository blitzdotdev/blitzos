# BlitzOS

BlitzOS is the managed runtime for Claude cloud sessions; this free, open-source skill gives you the warm-start hook so **your Claude cloud sessions boot knowing your whole codebase**.

It discovers your repositories, lets you declare the Claude.ai connectors you already use, and generates a thin private context repository. Select that repository beside your work repositories in Claude cloud to carry repository context and a concise work log from session to session—without copying source code, Git history, connector data, or secrets.

BlitzOS is early. Expect rough edges and a few manual setup steps while the cloud workflow settles.

## Quickstart

You need Claude Code, Git, GitHub CLI (`gh`) authenticated to the account that will own the generated private context repository, `jq`, and Node.js 18 or newer.

```sh
git clone https://github.com/blitzdotdev/blitzos.git
cd blitzos
./install.sh
claude "set up cloud claude"
```

The installer links the bundled skill into `~/.claude/skills`. The setup flow scans repository metadata, opens a localhost wizard, shows the complete company-context draft for approval, and creates a new private GitHub repository only after you approve it.

## Turn on Full network access

For the Claude cloud environment you will use:

1. Open the environment settings in Claude.
2. Find **Network access**.
3. Select **Full** and save the environment.

This setting controls network reachability. It does not add deployment credentials or expose secrets to the generated context repository.

## One-time Claude <-> GitHub connect

1. Connect GitHub to Claude if it is not connected already.
2. Allow Claude access to the generated context repository and each work repository you want available in cloud sessions.
3. In [claude.ai/code](https://claude.ai/code), start a session and select the context repository together with the relevant work repositories.

Repository access is still governed by the permissions you grant through GitHub and Claude.

## What you get

- Warm multi-repo context: Claude starts with the approved repository map, relationships, conventions, and recent work records.
- Your Claude connectors: ask Claude to check Linear, Slack, Gmail, or other connectors already connected to your Claude account when a task needs that context.
- A real cloud VM: install dependencies and build or test across the selected work repositories.
- A warm-start session log: short factual records in `sessions/` accrue across sessions so later work can pick up where earlier work stopped.

## How it works

The generated private repository contains only:

- `CLAUDE.md`, with the approved repository map, conventions, connector guidance, and warm-start instructions;
- `sessions/README.md`, with the concise session-record convention and template; and
- an initially empty `sessions/INDEX.md`, which becomes the chronological lookup for prior work.

The skill never vendors work repositories or copies their Git history. It does not inspect connector accounts, read secret values, or write secret values to the generated repository.

## What it doesn't do (yet)

- The free tier does not provide managed credentials, deployment automation, or per-task credential scoping.
- It is Claude-only today. Codex support is coming.
- Pushing session records back to the context repository from Claude cloud is experimental and remains unverified across the supported session paths.

## Managed BlitzOS

Want this managed for your team — vault, per-task scoped credentials, your own VPC? Join the waitlist: https://blitzos.app.blitz.dev

## License

MIT. See [LICENSE](LICENSE).
