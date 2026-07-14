# Verify native push (canary)

Claude Code cloud sessions are documented to push branches and open PRs to your **selected** repos through Anthropic's GitHub proxy — with no personal access token inside the VM. This canary confirms it works in *your* setup before you rely on it (for the warm-start session log, or for coordinated changes across several repos in one session).

**Why bother:** a `git push` can return a 401 that looks like "push is broken" but is actually the *wrong credential*. `gh` uses a separate `GH_TOKEN` you never set, and `$GITHUB_TOKEN` in the VM is a stub. Native `git` gets a scoped credential from Anthropic's proxy instead. A clean `git push` on the session's **working branch** of a **selected** repo is the only real test.

## Setup

1. Create two disposable **private** repos on the connected GitHub account (e.g. `push-canary-a`, `push-canary-b`), each with one commit.
2. In [claude.ai/code](https://claude.ai/code), start a session and **select both repos**.
3. Leave the environment's Network access on the default **Trusted** — GitHub uses a separate proxy, so the network mode shouldn't matter, and this run confirms that.

## Run (ask the session to do this, per repo, on its working branch)

1. Inspect the credential wiring without printing secrets:
   ```sh
   git remote -v
   git config --show-origin --get-all credential.helper
   ```
2. Make a trivial change, commit, and push the working branch:
   ```sh
   echo "canary" >> CANARY.md
   git add CANARY.md && git commit -m "canary push test"
   git push
   ```
3. Open a PR for that branch using the session's PR tooling.

## Pass criteria

- [ ] `git push` succeeds on the working branch of **both** selected repos (no 401).
- [ ] A PR is created for each repo.
- [ ] Commit author / PR actor are what you expect (note who: your account vs. the Claude app).
- [ ] Pushing to a **different** branch/ref is rejected (confirms pushes are restricted to the working branch).
- [ ] Still works with Network access set to **None** or **Trusted** (confirms git rides the separate proxy, not the VM network).

## If it passes

Native multi-repo read / write / push is real for your account — **no PAT needed.** The warm-start session log and coordinated multi-repo edits work through the native path. This is the "one session, all your repos, full git" workflow.

## If a clean working-branch push still 401s

That contradicts Anthropic's documentation and is worth reporting to Anthropic — it means the native path isn't available on your rollout. **Do not** fall back to committing a token into a repo (it leaks into history, forks, and clones forever). Use a managed broker instead, where credentials stay server-side. See [Managed BlitzOS](https://blitzos.com/waitlist).

## Scope: selection is the boundary (tested)

The in-VM git credential is scoped to the **selected repos only**. Cloning or pushing an unselected repo fails even when the connected account (and the Claude GitHub App) has full access to it — we verified this directly. That's good news for security posture: selecting repos *is* choosing the session's blast radius. The flip side is that an agent cannot reach a repo you didn't select, so multi-repo work requires selecting every repo up front — or a separately provisioned credential. A **scoped machine user** remains useful defense-in-depth for teams.
