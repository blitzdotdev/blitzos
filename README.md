<div align="center">
  <h1>BlitzOS</h1>
  <p><b>Claude/Codex Cloud VMs that boot knowing your whole codebase</b></p>

  [![Website](https://img.shields.io/badge/blitzos.com-website-black)](https://blitzos.com)
  [![Discord](https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white)](https://discord.gg/v3vQdAgPq6)
  [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
</div>

<br />

Your Claude Code cloud sessions, booted knowing your whole codebase. `blitzos` is a free, open-source skill that builds a thin private **context repo** so cloud sessions start warm: your repos, conventions, and a running work log, without copying code, history, or secrets.

Early and rough in places.

## Managed BlitzOS

want this for your team, with a credential vault, per-task scoped access, and your own VPC? [Join the waitlist](https://blitzos.app.blitz.dev)

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

## Troubleshooting

**Claude can "add" files from my repo but 404s when I ask it to read the repo — even with full access.**
You're likely using the **GitHub connector in regular Claude chat**, which only attaches individual files. To have Claude actually read and work *across* a repo, use **Claude Code on the web** — [claude.ai/code](https://claude.ai/code): connect GitHub there, then **select the repo when you start a session**. The session clones the whole repo into its environment and reads files natively — no 404. The chat connector and the coding session are different surfaces; this skill targets the coding session.

Still 404ing in claude.ai/code? Make sure the **Claude GitHub App is authorized on that specific repo** (GitHub → Settings → Applications → Claude). Org-owned and private repos often need to be granted individually, even if your account already has "full access."

## License

MIT — see [LICENSE](LICENSE).
