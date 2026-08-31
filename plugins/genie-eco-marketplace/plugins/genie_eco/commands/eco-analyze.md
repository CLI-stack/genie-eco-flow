---
description: Kick off the Genie AI ECO flow for an RTL change. Mode = complete (full STUDY->APPLY->ROUND->FINAL) or simple (steps 1,3,4 only).
argument-hint: <ref_dir> <tile> <jira> [complete|simple]
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
- `mode` (optional, default `complete`) — one of:

| mode | steps | pipeline |
|---|---|---|
| `complete` (default) | 1-6 | STUDY (1,2,3) → APPLY (4,5,6) → ROUND loop (on FM mismatch, max 10) → FINAL. Full fenets + validators + Formality. |
| `simple` | 1,3,4 | STUDY-lite (1 = RTL diff; **skip 2/fenets**, do structural cone tracing; 3 = study) → APPLY (4). **No** validators, verifier, pre-FM, FM, ROUND, FINAL, report, or email — the step-1/3/4 artifacts are the whole deliverable. |

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

1. **Parse & validate** `$ARGUMENTS` into `mode` (optional; default `complete`, else `complete`|`simple`)
   and the inputs. Two input styles are accepted:
   - **TileBuilder dir** (both modes): `<ref_dir> <tile> <jira>` where `ref_dir` is a directory with
     `revrc.main`. This is the only style for `complete`.
   - **direct inputs (explicit paths)** (`simple` mode ONLY): the user gives no TileBuilder dir but instead
     the fields `RTL_BEFORE`, `RTL_AFTER` (each a `.v` file OR a directory), `NETLIST_SYNTH`
     (**required**), `NETLIST_PREPLACE` and `NETLIST_ROUTE` (**optional** — omit for a Synthesize-only
     run), plus `TILE` and `JIRA` (for net naming / reports). Accept them pasted in one message
     (`RTL_BEFORE: … RTL_AFTER: … NETLIST_SYNTH: …`) and **ask only for missing REQUIRED fields**
     (`RTL_BEFORE`, `RTL_AFTER`, `NETLIST_SYNTH`, `TILE`, `JIRA`). If the user gives only
     `NETLIST_SYNTH`, proceed Synth-only — do NOT ask for PrePlace/Route. Then go to **step 1b**.

   If `mode == complete` and no valid TileBuilder `ref_dir` is given, or any of `tile`/`jira` is
   missing, stop with usage: `/genie_eco:eco-analyze <ref_dir> <tile> <jira> [complete|simple]`.

1b. **(simple + direct-input style only) Build a shim ref_dir.** Turn the explicit paths into the
   TileBuilder layout the flow expects, so the whole simple flow runs unchanged. Generate a `<TAG>`
   (`date +%Y%m%d%H%M%S`) and:
   ```bash
   cd /home/abinbaba/eco_flow
   python3 script/eco_scripts/eco_build_shim_refdir.py \
       --rtl-before <RTL_BEFORE> --rtl-after <RTL_AFTER> \
       --netlist-synth <NETLIST_SYNTH> \
       --tag <TAG> --workdir "$(dirname <NETLIST_SYNTH>)"
   #   Append --netlist-preplace <NETLIST_PREPLACE> and/or --netlist-route <NETLIST_ROUTE>
   #   ONLY for the stages the user actually provided (omit for a Synthesize-only run).
   ```
   It prints `SHIM_REF_DIR=<path>`. Use that as `ref_dir` for steps 2–3. **Remember the
   original `NETLIST_*` paths the user provided** — you write the patched result back to them in step
   3b (only the stages given). The shim symlinks the originals (read-only) and patches PostEco copies,
   so nothing is overwritten until 3b.

2. **Run the analyze validator** from the shared repo root (`GENIE_ROOT`):
   ```bash
   cd /home/abinbaba/eco_flow
   python3 script/genie_cli.py -i "analyze eco at <ref_dir> for <tile> <jira>" --execute
   ```
   This runs `eco_analyze.csh`, which validates the PreEco/PostEco netlists + RTL dirs and
   emits an `ECO_ANALYZE_MODE_ENABLED` block (with `TAG REF_DIR TILE JIRA LOG_FILE SPEC_FILE`).

   **Multi-user note — do NOT cd into `users/$USER`.** The standalone flow writes **all** output
   into `<ref_dir>/AI_ECO_FLOW_<TAG>/` (writable by whoever owns the run), and only **reads** the
   shared config CSVs from `GENIE_ROOT` (world-readable). Running from `GENIE_ROOT` therefore needs
   **no per-user workspace and no write access to the repo** — any teammate can run it read-only, and
   notifications default to `$USER@amd.com`. (The old genie_agent "always run from `users/$USER`" rule
   does not apply here — that was for per-user `data/`/`runs/` isolation, which `AI_ECO_FLOW_DIR`
   already provides.)

3. **Hand off to the orchestrator.** When you see `ECO_ANALYZE_MODE_ENABLED`, spawn the
   `eco_orchestrator` agent (this plugin), passing the block's fields (`TAG REF_DIR TILE JIRA
   LOG_FILE SPEC_FILE`) **plus `MODE=<mode>`** (`complete` or `simple`). The orchestrator branches
   on MODE: `complete` runs the full STUDY -> APPLY -> ROUND -> FINAL state machine with all hard
   gates; `simple` runs only Steps 1,3,4 (via `config/eco_agents_simple/`) and stops. Do NOT run
   the phases yourself.

3b. **(simple + direct-input style only) Write the patched netlists back in place.** After the
   orchestrator finishes, the patched netlists are in `<SHIM_REF_DIR>/data/PostEco/<Stage>.v.gz` for
   each stage that was provided. Overwrite each **original** `NETLIST_*` path the user gave, backing
   it up once (explicit per stage, no word-splitting). **Run only the lines for the stages provided**
   — skip PrePlace/Route entirely on a Synthesize-only run:
   ```bash
   SHIM=<SHIM_REF_DIR>; SYN=<NETLIST_SYNTH>
   [ -e "$SYN.preeco_bak" ] || cp "$SYN" "$SYN.preeco_bak"; cp "$SHIM/data/PostEco/Synthesize.v.gz" "$SYN"
   # PrePlace — only if NETLIST_PREPLACE was provided:
   PP=<NETLIST_PREPLACE>; [ -e "$PP.preeco_bak" ] || cp "$PP" "$PP.preeco_bak"; cp "$SHIM/data/PostEco/PrePlace.v.gz" "$PP"
   # Route — only if NETLIST_ROUTE was provided:
   RT=<NETLIST_ROUTE>; [ -e "$RT.preeco_bak" ] || cp "$RT" "$RT.preeco_bak"; cp "$SHIM/data/PostEco/Route.v.gz" "$RT"
   ```
   The artifacts (`eco_rtl_diff.json`, `eco_preeco_study.json`, applied JSON) remain under
   `<SHIM_REF_DIR>/AI_ECO_FLOW_<TAG>/`.

4. When the orchestrator returns, relay its one-line summary. For **complete**: e.g. "ECO analysis
   complete. Email sent." For **simple + TileBuilder**: the "Steps 1,3,4 done" summary. For
   **simple + direct-input**: report the overwritten netlist path(s) (the stages provided) + their
   `.preeco_bak` backups + the shim artifact dir.

## Notes
- **Input styles for `simple` mode:** either a TileBuilder `ref_dir` (positional, like complete),
  or direct explicit fields (`RTL_BEFORE`/`RTL_AFTER` + `NETLIST_SYNTH` **required**, `NETLIST_PREPLACE`
  /`NETLIST_ROUTE` **optional** + `TILE`/`JIRA`), which are turned into a shim ref_dir by
  `eco_build_shim_refdir.py` and written back in place with `.preeco_bak`. A Synthesize-only run is
  allowed — the flow processes only the stages provided. Complete mode is TileBuilder-only (it needs
  Formality/PNR context, all 3 stages).
- Long-running phases (FM, fenets) are polled INSIDE the spawned agents, never from this
  command's session. See `agents/eco_orchestrator/AGENT.md`.
- This command does not modify any genie_agent file; it only launches the existing flow.
