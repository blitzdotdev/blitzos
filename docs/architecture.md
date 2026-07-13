# BlitzOS architecture

## Connected-session model

Claude cloud sessions launched from claude.ai/code can select multiple connected GitHub repositories, receive full Git history, and use the account's Claude.ai connectors. BlitzOS therefore does not assemble a runtime monorepo. The free skill creates one thin context repository that is selected beside the real work repositories.

## Scan and selection

`scan.sh` uses local Claude project evidence to resolve Git roots and ranks them by recent use. It also lists repositories for the authenticated GitHub user and organizations with `gh repo list`. Results are deduplicated by normalized origin, preferring a local record when one exists so current, default, and recent branches remain available.

The scanner may retain environment variable names from shallow `.env.example`/`.env.sample`/`.env.template` discovery. Real environment files are never opened, and values are never emitted. It does not inspect MCP servers, deployment credentials, heavy dependencies, or Claude.ai account connector data.

The localhost wizard binds to `127.0.0.1`. It collects GitHub repository/branch selections and declarations for Linear, Slack, Gmail, Google Drive, GitHub, and free-text Claude.ai connectors. It cannot inspect the account behind those declarations.

## Thin repository

After the user approves the complete company brain, `build-monorepo.sh` creates a new local Git repository containing only:

- `CLAUDE.md`, with the selected repository map, relationships, conventions, connector guidance, and warm-start session-log instructions;
- `sessions/README.md`, with the short factual work-record convention and template; and
- an empty `sessions/INDEX.md` for chronological session summaries.

The builder rejects unknown plan fields and common credential material before committing. It creates and pushes the GitHub repository with `gh repo create --private`, then verifies that GitHub reports it as private. It never clones work repositories, copies source, creates bundles, or reads environment files.

At session start, Claude reads the index and recent relevant records. After meaningful work, it creates one dated task record, appends one index entry, and commits and pushes both to the context repository. This push-back requires the context repository to be selected and depends on unverified GitHub proxy push support.

## Session launch

The user connects the context repository and work repositories to Claude, sets the cloud environment's Network access to Full, and launches from claude.ai/code with all relevant repositories selected. Context arrives through the thin repository while code and history arrive through Claude's native connected-repository support.
