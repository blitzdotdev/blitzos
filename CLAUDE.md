# BlitzOS

## What this project is

BlitzOS is a context manager for cloud coding agents. This repository is its free, open-source skill: it generates a private context monorepo so Claude Code cloud sessions boot already knowing a user's repositories. The hosted portal at https://blitzos.com creates and launches the same artifact from the browser.

The skill offers two setup paths: browser (blitzos.com) or local. The local path scans repository evidence, collects repository and connector selections in a localhost wizard, drafts one company `CLAUDE.md` for approval, and builds. The generated monorepo contains the approved `CLAUDE.md`, a README with a one-click launch link, member repositories as gitlink submodules, `bootstrap.sh`, `docs/CLOUD-SETUP.md`, and a `sessions/` scaffold.

## Product contract

- Two launch modes, one artifact. DEFAULT: the launch link selects the monorepo plus every member repository natively; zero credentials; `bootstrap.sh` is unused. POWER MODE: select only the monorepo; `bootstrap.sh` materializes members using `BLITZOS_GIT_TOKEN` from a personal cloud environment.
- Never vendor member source or copy Git history into the generated repository. Members are gitlink pointers only.
- Keep the warm-start loop: sessions read `sessions/` at start and write one concise factual record after meaningful work, pushed back natively.
- Connector choices are declarations. The skill cannot inspect Claude.ai accounts.
- Claude-only today. Codex integration is researched but not shipped.
- Free for individuals. Managed BlitzOS is the company tier (waitlist at https://blitzos.com/waitlist).

## Platform facts (verified)

- The in-VM git credential covers only repositories selected in the composer. Selection is the security boundary; see `docs/verify-push.md`.
- Native push and PR creation to selected repositories work with no PAT (tested on the working branch).
- The default Trusted network access is enough; git and connectors ride separate proxies. Custom allowlists exist for additional egress.
- claude.ai/code deep links prefill `repositories` (literal `owner/repo,owner/repo` format), `prompt`, and `environment`. Percent-encoded slashes or commas in `repositories` break the composer.
- Cloud VMs expose `CLAUDE_CODE_REMOTE_SESSION_ID`; replacing `cse_` with `session_` yields the session URL.

## Working rules

- Never commit secret values anywhere: this repository, generated repositories, fixtures, or logs. Environment evidence is names only.
- Generated output lives outside this checkout and must remain a private repository.
- Preserve the single approval gate for the drafted company context before building; preserve wizard and temp-file cleanup on success, failure, or abort.
- Run `bash skill/tests/test-build-monorepo.sh` after any change that could affect generation or validation.
- Keep documentation honest about unverified behavior. Canary before claiming.

## Repository map

- `skill/SKILL.md`: workflow and safety contract (browser/local fork, monorepo drafting, handoff).
- `skill/scripts/scan.sh`: local repository evidence discovery.
- `skill/scripts/wizard-server.mjs` and `skill/wizard.html`: localhost selection wizard.
- `skill/scripts/build-monorepo.sh`: gitlink monorepo builder and launch-link generation.
- `skill/tests/test-build-monorepo.sh`: no-push build and validation suite.
- `docs/verify-push.md`: the native-push canary and its results.
- `docs/architecture.md` and `docs/spike-results.md`: architecture and historical capability evidence.
