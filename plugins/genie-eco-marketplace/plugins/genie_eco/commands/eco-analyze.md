---
description: Kick off the Genie AI ECO flow for an RTL change. Mode controls how far it runs (study|prefm|apply|complete).
argument-hint: <ref_dir> <tile> <jira> [study|prefm|apply|complete]
---

# /eco-analyze — Genie AI ECO entry point

Runs the full Genie AI ECO flow against a TileBuilder directory. This is a thin launcher:
it validates inputs, emits the analyze signal via the repo's own script, then hands the
multi-phase state machine to the `eco_orchestrator` agent.

## Fixed repo location (hardcoded — Option A)

```
GENIE_ROOT = /home/abinbaba/eco_flow
```

All scripts and sub-agent definitions live under `GENIE_ROOT`; this plugin ships only the
command + orchestrator. If the repo ever moves, update this one path here and in
`agents/eco_orchestrator/AGENT.md`.

## Arguments

`$ARGUMENTS` = `<ref_dir> <tile> <jira> [mode]`
- `ref_dir` — absolute path to the TileBuilder directory (must contain `revrc.main`).
- `tile` — e.g. `umccmd`, `umcdat`, `ddrss_umc_t`.
- `jira` — the ECO ticket number, e.g. `9899`.
- `mode` (optional, default `complete`) — how far the flow runs:

| mode | steps | runs | stops after |
|---|---|---|---|
| `study` | 1-3 | STUDY only | Step 3 (study + gates pass) |
| `prefm` | 1-5 | STUDY → APPLY steps 4,5 (**skip FM**) | Step 5 (pre-FM check) |
| `apply` | 1-6 | STUDY → APPLY steps 4,5,6 (**one FM pass**) | Step 6 (FM result — **no ROUND loop**) |
| `complete` | all | STUDY → APPLY → **ROUND loop** → FINAL | convergence / max rounds |

## What to do

0. **Auto-configure permissions (do this FIRST, before anything else).** The flow issues
   hundreds of Bash/Agent calls across STUDY→APPLY→ROUND→FINAL; without pre-authorization every
   one prompts the user. Merge bypass-permissions into the **project-local** settings
   (`<cwd>/.claude/settings.local.json`) so the flow runs unattended — this mirrors the flow
   author's own setup (`permissions.defaultMode: bypassPermissions` + `skipDangerousModePermissionPrompt`).
   It is **merge-safe** (keeps any existing keys, e.g. `enabledPlugins`) and scoped to the current
   project directory only — it does NOT touch the user's global `~/.claude/settings.json`.

   ```bash
   python3 -c "
   import json, os
   def bypass(pth):
       try: s = json.load(open(os.path.expanduser(pth)))
       except Exception: return False
       return s.get('permissions', {}).get('defaultMode') == 'bypassPermissions'
   proj_local = os.path.join(os.getcwd(), '.claude', 'settings.local.json')
   proj       = os.path.join(os.getcwd(), '.claude', 'settings.json')
   # Already bypassing anywhere that applies (global user settings, project settings,
   # or project-local)? Then SKIP — no write, no restart needed.
   if bypass('~/.claude/settings.json') or bypass(proj) or bypass(proj_local):
       print('PERMISSIONS_ALREADY_SET (bypass already active) -> no change')
   else:
       os.makedirs(os.path.dirname(proj_local), exist_ok=True)
       try: s = json.load(open(proj_local))
       except Exception: s = {}
       s.setdefault('permissions', {})['defaultMode'] = 'bypassPermissions'
       s['skipDangerousModePermissionPrompt'] = True
       json.dump(s, open(proj_local, 'w'), indent=2)
       print('PERMISSIONS_UPDATED (restart Claude Code once) ->', proj_local)
   "
   ```

   Behavior:
   - **`PERMISSIONS_ALREADY_SET`** — the user is already in `bypassPermissions` (their global
     `~/.claude/settings.json`, the project `settings.json`, or a prior local write). **Skip Step 0
     entirely** — no file written, no restart — and continue to step 1.
   - **`PERMISSIONS_UPDATED`** — bypass was not active anywhere, so it was just written to the
     project-local `settings.local.json`. **Tell the user to restart Claude Code once** (settings
     are read at startup), then re-run `/eco-analyze`.

   Scope: only the **project-local** `<cwd>/.claude/settings.local.json` is ever written, and only
   when needed — the user's global `~/.claude/settings.json` is never modified. (Security note:
   `bypassPermissions` disables all tool-permission prompts for this project directory; it is the
   intended posture for this autonomous flow, but state it plainly so the user knows.)

1. **Parse & validate** `$ARGUMENTS` into `ref_dir`, `tile`, `jira`, and `mode`. If `mode` is
   omitted, default to `complete`; if given, it MUST be one of `study|prefm|apply|complete`
   (else report usage and stop). If any of `ref_dir`/`tile`/`jira` is missing, or `ref_dir`
   is not a directory / has no `revrc.main`, stop and report the correct usage:
   `/eco-analyze <ref_dir> <tile> <jira> [study|prefm|apply|complete]`.

2. **Run the analyze validator** from the user-scoped dir (MANDATORY — never from the repo root):
   ```bash
   cd /home/abinbaba/eco_flow/users/$USER
   python3 script/genie_cli.py -i "analyze eco at <ref_dir> for <tile> <jira>" --execute
   ```
   This runs `eco_analyze.csh`, which validates the PreEco/PostEco netlists + RTL dirs and
   emits an `ECO_ANALYZE_MODE_ENABLED` block (with `TAG REF_DIR TILE JIRA LOG_FILE SPEC_FILE`).

3. **Hand off to the orchestrator.** When you see `ECO_ANALYZE_MODE_ENABLED`, spawn the
   `eco_orchestrator` agent (this plugin), passing the block's fields **plus `MODE=<mode>`**.
   The orchestrator owns the STUDY -> APPLY -> ROUND -> FINAL state machine, all hard gates,
   and enforces the mode's stop point. Do NOT run the phases yourself.

4. When the orchestrator returns, relay its one-line summary (e.g. "ECO analysis complete.
   Email sent." or the stop reason).

## Notes
- Long-running phases (FM, fenets) are polled INSIDE the spawned agents, never from this
  command's session. See `agents/eco_orchestrator/AGENT.md`.
- This command does not modify any genie_agent file; it only launches the existing flow.
