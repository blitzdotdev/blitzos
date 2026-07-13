# BlitzOS

## What this project is

BlitzOS is the managed runtime for Claude cloud sessions. This repository is its free, open-source skill: a thin company-context generator that gives Claude cloud sessions a warm start across multiple repositories.

The skill discovers repository evidence, collects repository and Claude.ai connector declarations in a localhost wizard, drafts one company `CLAUDE.md` for approval, and emits a small private context repository. Users select that repository beside their real work repositories in native multi-repo Claude cloud sessions.

## Product contract

- Keep the generator thin: emitted repositories contain only the approved `CLAUDE.md` and the `sessions/` scaffold.
- Keep work repositories independent. Do not vendor source, copy Git history, create Git bundles, or rebuild a runtime monorepo.
- Keep the warm-start loop: sessions read the index and relevant recent records at start, then write one concise factual record after meaningful work.
- Treat Claude.ai connector choices as declarations. The skill cannot inspect the user's connector accounts.
- Keep the free skill Claude-only for now. Codex support belongs to a future product iteration.
- Treat session push-back through the GitHub proxy as experimental until it is verified across supported connected-session paths.

## Platform facts

- Properly connected Claude cloud sessions support native multi-repository selection, full Git history, and private-repository clone authentication through GitHub integration.
- Network access is configured per cloud environment. Users should select Full for the workflow documented in the README.
- Network reachability is not credential provisioning. The free skill does not manage deployment credentials or per-task scopes.
- CLI-dispatched sessions can differ from properly connected web sessions; do not generalize platform limits from the degraded path.
- Context committed as ordinary files reaches cloud sessions through the platform checkout and is the basis of the warm-start mechanism.
- Managed Agents API sessions are API-billed and are not interchangeable with subscription-backed Claude cloud sessions.

## Working rules

- Never commit secret values to this repository, generated repositories, fixtures, or logs. Environment evidence is names only.
- Generated output lives outside this checkout and must remain a private context repository.
- Preserve the single approval gate for the complete drafted company context before building.
- Preserve cleanup of temporary files and the localhost wizard on success, failure, or abort.
- Keep repository discovery origin-deduplicated and do not clone GitHub-only repositories for drafting.
- Run `tests/build-thin-repo.sh` after changes that could affect generation or validation.
- Keep documentation honest about experimental push-back and other unverified platform behavior.

## Repository map

- `skill/SKILL.md`: Claude-only workflow and safety contract.
- `skill/scripts/scan.sh`: repository evidence discovery.
- `skill/scripts/wizard-server.mjs` and `skill/wizard.html`: local selection flow.
- `skill/scripts/build-monorepo.sh`: validated thin-repository builder.
- `tests/build-thin-repo.sh`: no-push build and schema test.
- `docs/architecture.md`: current architecture.
- `docs/spike-results.md`: historical cloud capability evidence.
