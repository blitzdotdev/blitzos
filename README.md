<div align="center">
  <h1>BlitzOS</h1>
  <p><b>Cloud agents that boot already knowing your work, and keep working with your laptop closed</b></p>

  [![Website](https://img.shields.io/badge/blitzos.com-website-black)](https://blitzos.com)
  [![Discord](https://img.shields.io/badge/Discord-join-5865F2?logo=discord&logoColor=white)](https://discord.gg/v3vQdAgPq6)
  [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
</div>

<br />

## What is this?

Your Claude subscription includes free cloud computers. Every cloud agent you start at [claude.ai/code](https://claude.ai/code) gets a fresh VM that keeps working after you close your laptop.

The problem: **every new VM boots knowing nothing.** It doesn't know which repos belong together, how they relate, what your conventions are, or what the last agent did. Also, if your work involves multiple repos, you must manually select repos to load every time you launch a cloud agent.

BlitzOS fixes the problem by building you a **context repo**: one private GitHub repo owned by you that teaches every new cloud agent your whole setup:

```
your-context-repo/
  CLAUDE.md      # the map: your repos, how they relate, conventions, work loop
  .gitmodules    # member repos pinned by reference: no code is ever copied in
  sessions/      # every cloud agent commits a record of what it did
  docs/          # optional power-mode setup
```

Launching a cloud agent that can do real work becomes one click: the VM boots with the context repo plus every work repo auto-selected. Cloud agents read CLAUDE.md, read what previous cloud agents did, and start working with no blockers. Your laptop can be off the entire time.

**Managed BlitzOS:** Context repository, but for your whole company. Give cloud agents a role and launch them with scoped context, your team's tools (Google Workspace, Slack, Linear, Stripe, etc), and credentials. Agents become as capable as your coworkers. [Join the waitlist →](https://blitzos.com/waitlist)

Early and rough in places.

## Quickstart

Two ways to set up, same context repo either way:

**Browser (fastest):** sign in with GitHub at [blitzos.com](https://blitzos.com), pick the repos that belong together, and BlitzOS creates the context repo and gives you one-click launches, plus a feed that tracks every cloud agent's live status.

**Local (most private):** this skill builds everything on your machine and grants nothing to BlitzOS servers.

Needs Claude Code, Git, `gh` (authenticated), `jq`, and Node 18+.

```sh
git clone https://github.com/blitzdotdev/blitzos.git
cd blitzos && ./install.sh
claude "set up blitzos"
```

The skill scans your repos, opens a localhost wizard, shows you the drafted context for approval, and creates the private context repo under your GitHub account. It hands back one launch link that pre-selects the context repo plus every work repo: open it and click Start.

## What you get

- **One-click launch** a link that selects the context repo and every member repo, in the right order, every time.
- **Warm multi-repo context** cloud agents start knowing your conventions, the repo map, and what previous agents did.
- **Native repository access** Claude reads, writes, pushes branches, and opens PRs on every selected repo through Anthropic's own GitHub rail. Zero tokens in the default path.
- **A cloud agent feed** [blitzos.com](https://blitzos.com) shows every cloud agent's live status (working / quiet / done) with a link to open any of them, from any device. One 2-minute environment setup.
- **Your connectors** cloud agents can use Linear, Slack, Gmail, and whatever else is already connected to your claude.ai account.
- **A shared work log** each cloud agent records PRs and decisions in `sessions/`, so work compounds instead of evaporating.

The default **Trusted** network setting is enough.

## Security model

The default flow needs **zero credentials**. The launch link selects the context repo and every member repo through Anthropic's native GitHub proxy, so all repository access stays on Claude's own rail. No PAT anywhere. Your source code is never copied into the context repo (members are pinned by reference) and never touches BlitzOS servers.

Optional **power mode** selects only the context repo and materializes members as submodules via `bootstrap.sh`, using a scoped, expiring fine-grained PAT stored only in your **personal** Claude cloud environment never in Git. Anthropic warns that environment variables are visible to anyone using an environment, so never do this in a shared one. The generated `docs/CLOUD-SETUP.md` walks through it if you deliberately opt in.

## Vision & roadmap

**Your agent setup should live in a repo, not on a machine.**

Local Claude Code is powerful because your machine accumulates state: checkouts, skills, config, memory. That's also the trap: the state is stuck in one laptop. BlitzOS moves it into git, where it's versioned, reviewable, and portable. Once your context, your skills, and your work log live in a repo, a fresh cloud VM isn't a downgrade from your laptop — it's your setup, available in unlimited copies, from anywhere, in parallel, and always current. The durable unit of agentic work stops being the machine or the cloud agent. It's the context repo.

Shipped:

- [x] **Context repos** — map + pinned member repos + sessions log, generated in one command
- [x] **One-click multi-repo launch** — zero tokens, native GitHub rail
- [x] **Live cloud agent feed** — cloud agents report status to blitzos.com; see working / quiet / done and open any cloud agent from any device

Shipping now:

- [ ] **Clean-prompt status** — cloud agents connect to the feed through a one-time environment key; nothing gets appended to your prompt
- [ ] **Guided setup** — the feed walks you through the 2-minute environment config and verifies it live

Next:

- [ ] **Steer from the feed** — reply to a running cloud agent from blitzos.com; the last reason to keep a terminal open goes away
- [ ] **Skills travel with the repo** — put your skills in the context repo and every VM boots with them: your `~/.claude`, versioned and portable
- [ ] **Self-updating context** — cloud agents propose PRs back to the context repo when they learn something (a new convention, a decision, a map change), so context compounds instead of rotting
- [ ] **Codex support** — the same context repo boots OpenAI Codex cloud agents; your context stops being vendor-locked

**Managed BlitzOS** — agents as capable as your coworkers, scoped and audited ([waitlist](https://blitzos.com/waitlist)):

- [ ] **Roles, not setups** — give a cloud agent a role and launch: it gets the company repo (code, plans, research, docs, goals), your team's tools — Google Workspace, Slack, Linear, analytics, Stripe — and the credentials that role needs.
- [ ] **Whole loops, not just code** — read the support ticket, check the code, ship the fix, reply to the customer, close the ticket — one cloud agent, start to finish.
- [ ] **Policy layer over capability and credentials** — every grant is per role and per agent, never account-wide; each cloud agent is a fork of your company holding only what its job needs.
- [ ] **Audit trail end to end** — everything every agent touched, when, and with which credential.
- [ ] **Runs where you need it** — our managed cloud or your own VPC.

## Troubleshooting

If a repo is missing in the default flow, confirm the Claude GitHub App can access that repository, then reopen the generated launch link. In power mode, follow the generated `docs/CLOUD-SETUP.md` for token setup and rotation.

## License

MIT. See [LICENSE](LICENSE).
