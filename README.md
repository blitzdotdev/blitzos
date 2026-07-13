# BlitzOS

Your Claude Code cloud sessions, booted knowing your whole codebase. `blitzos` is a free, open-source skill that builds a thin private **context repo** so cloud sessions start warm — your repos, conventions, and a running work log — without copying code, history, or secrets.

Early and rough in places.

**Managed BlitzOS** — want this for your team, with a credential vault, per-task scoped access, and your own VPC? [Join the waitlist →](https://blitzos.app.blitz.dev)

## Quickstart

Needs Claude Code, Git, `gh` (authenticated), `jq`, and Node 18+.

```sh
git clone https://github.com/blitzdotdev/blitzos.git
cd blitzos && ./install.sh
claude "set up blitzos"
```

The skill scans your repos, opens a localhost wizard, shows a context draft for your approval, and creates a private context repo. Then in [claude.ai/code](https://claude.ai/code), select that repo alongside your work repos and start a session.

## What you get

- **Warm multi-repo context** — sessions start with your repo map, conventions, and recent work log.
- **Your connectors** — Claude can use Linear, Slack, or Gmail when they're connected to your account.
- **A real cloud VM** — install, build, and test across your repos.
- **A session log** — short records in `sessions/` carry work forward between sessions.

The default **Trusted** network is enough — git and connectors use separate proxies, and registries are reachable. Only widen it (prefer **Custom** over **Full**) if a task must reach an outside host.

## Not yet

Claude-only (Codex coming). The free tier has no managed credentials, deploy, or per-task scoping — that's [Managed BlitzOS](https://blitzos.app.blitz.dev). Pushing the session log back from cloud is experimental.

## License

MIT — see [LICENSE](LICENSE).
