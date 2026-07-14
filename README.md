<div align="center">
  <h1>BlitzOS</h1>
  <p><b>Claude/Codex Cloud VMs that boot knowing your whole codebase</b></p>

  [![Website](https://img.shields.io/badge/blitzos.com-website-black)](https://blitzos.com)
  [![Discord](https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white)](https://discord.gg/v3vQdAgPq6)
  [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
</div>

<br />

**One launch link. Your whole codebase inside.** `blitzos` is a free, open-source skill that builds a private context monorepo so Claude Code cloud sessions start warm with your repos, conventions, and running work log.

Early and rough in places.

**Managed BlitzOS:** want this for your team, with a credential vault, per-task scoped access, and your own VPC? [Join the waitlist →](https://blitzos.com/waitlist)

## Quickstart

### Two ways to set up

**Browser:** Go to [blitzos.com](https://blitzos.com) for the fastest setup, GitHub sign-in, repo selection, one-click launches, and a launch feed.

**Local:** Use this skill for a private setup that grants nothing to BlitzOS servers and drafts evidence-based conventions from local repos.

Needs Claude Code, Git, `gh` (authenticated), `jq`, and Node 18+.

```sh
git clone https://github.com/blitzdotdev/blitzos.git
cd blitzos && ./install.sh
claude "set up blitzos"
```

The skill scans your repos, opens a localhost wizard, shows the company context for your approval, and creates a private context monorepo. It returns one Claude Code launch link that pre-selects the context repo plus every work repo. Open it, select nothing manually, and click Start.

## What you get

- **One-click launch:** a launch link that pre-selects all your repos in the right order.
- **Warm multi-repo context:** sessions start with conventions and recent work records.
- **Native repository access:** Claude works directly in each selected checkout and can push branches and open PRs.
- **Your connectors:** Claude can use Linear, Slack, Gmail, and other connectors already connected to your account.
- **Cross-repo delivery:** record member-repo PRs and decisions in one shared session log.

The default **Trusted** network setting is enough.

## Security model

The default flow needs zero credentials. The launch link selects the context monorepo and every member repo through Anthropic's native GitHub proxy, so reads, writes, pushes, and PRs stay on Claude's native repository rail. No PAT is used anywhere in the default path.

Optional power mode selects only the context monorepo and materializes member repos as submodules with `bootstrap.sh`. It uses a scoped, expiring fine-grained PAT stored only in your **personal** Claude cloud environment, never in Git. Anthropic warns that environment variables are visible to anyone using an environment, so never use this mode in a shared environment. Follow the generated `docs/CLOUD-SETUP.md` if you intentionally choose it.

## Not yet

Claude-only (Codex coming). The free tier has no managed credentials, deploy, or per-task scoping. Those are part of [Managed BlitzOS](https://blitzos.com/waitlist).

## Troubleshooting

If a repo is missing in the default flow, confirm the Claude GitHub App can access that repository, then reopen the generated launch link. In optional power mode, open the generated `docs/CLOUD-SETUP.md` for token setup and rotation steps.

## License

MIT. See [LICENSE](LICENSE).
