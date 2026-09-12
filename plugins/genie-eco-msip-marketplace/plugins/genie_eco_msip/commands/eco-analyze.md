---
description: Kick off the Genie AI ECO flow for an RTL change. Prompts for mode (required - complete or simple), then ref_dir/RTL paths, jira and tile.
argument-hint: [complete|simple] [<ref_dir> <jira> <tile>] — run bare to be prompted for each input
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

`$ARGUMENTS` is **fully optional**. Anything not supplied is asked interactively (see step 1).
All four inputs are **REQUIRED** — there are no defaults, including `mode`.

- `mode` — **required**, `complete` or `simple`. Never assume a default; if the user did not
  state it, ASK.
- `ref_dir` — absolute path to the TileBuilder directory (must contain `revrc.main`).
  In `simple` mode this may instead be direct RTL/netlist paths (see step 1a).
- `jira` — the ECO ticket number, e.g. `9899`.
- `tile` — e.g. `umccmd`, `umcdat`, `ddrss_umc_t`.

| mode | steps | pipeline |
|---|---|---|
| `complete` | 1-6 | STUDY (1,2,3) → APPLY (4,5,6) → ROUND loop (on FM mismatch, max 10) → FINAL. Full fenets + validators + Formality. |
| `simple` | 1,(2 optional),3,4 | STUDY-lite (1 = RTL diff; **2 = fenets, OPTIONAL, off by default** — see Q2.5; 3 = study, structural cone tracing, or fenets-bound if Step 2 ran) → APPLY (4). **No** validators, verifier (beyond simple mode's own structural one), pre-FM, FM, ROUND, FINAL, report, or email — the step-1/(2)/3/4 artifacts are the whole deliverable. |

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

1. **Collect the inputs — ASK, in this exact order.** First take whatever the user already gave
   in `$ARGUMENTS` or in their message. For every input still missing, ask the user — one question
   at a time, in this order, and do NOT proceed until each is answered. **Never invent a default;
   `mode` in particular is REQUIRED, not optional.**

   **Q1 — mode (always first).** Ask via `AskUserQuestion`:
   - `complete` — full STUDY → APPLY → ROUND → FINAL, with fenets, all validators and Formality.
     Requires a TileBuilder directory.
   - `simple` — Steps 1, 3, 4 only. Fast, no Formality/rounds. Accepts either a TileBuilder
     directory or direct RTL/netlist paths.

   **Q2 — the design inputs (branches on the Q1 answer).**
   - If `mode == complete`: ask for the **TileBuilder directory** (absolute path containing
     `revrc.main`). This is the only accepted style for `complete` — there is no direct-path option.
   - If `mode == simple`: ask which input style the user wants, then collect it:
     - **TileBuilder directory** — an absolute path containing `revrc.main`; or
     - **direct paths** — `RTL_BEFORE`, `RTL_AFTER` (each a `.v` file OR a directory) and
       `NETLIST_SYNTH` (**required**), plus `NETLIST_PREPLACE` / `NETLIST_ROUTE` (**optional** —
       omit for a Synthesize-only run). Accept them pasted in one message
       (`RTL_BEFORE: … RTL_AFTER: … NETLIST_SYNTH: …`) and ask only for missing REQUIRED fields.
       If the user gives only `NETLIST_SYNTH`, proceed Synth-only — do NOT ask for PrePlace/Route.
       This style routes through **step 1b**.

   **Q2.5 — run fenets? (simple mode ONLY — skip entirely for complete mode, which always runs it).**
   Ask via `AskUserQuestion`, regardless of whether Q2 was answered TileBuilder-dir style or
   direct-paths style:
   - `No (default, recommended)` — Step 2 is skipped; Step 3 uses structural cone tracing only
     (today's behavior, unchanged).
   - `Yes` — Step 2 runs. Requires a **separate** input, `FM_SESSION_DIR`: an absolute path to a
     TileBuilder directory that already has a runnable, genuine **PreEco** FM target/session (e.g.
     `FmEqvPreEcoSynthesizeVsPreEcoSynRtl`). This is required **even when Q2 was answered with the
     direct-paths style** — `FM_SESSION_DIR` may be the same directory as a TileBuilder-dir-style
     `ref_dir`, or a completely different directory; it is independent of where the RTL/netlist
     inputs came from.

   If `Yes`, validate `FM_SESSION_DIR` immediately, before proceeding:
   ```bash
   cd /home/abinbaba/eco_flow
   python3 script/eco_scripts/eco_fm_targets.py --detect <FM_SESSION_DIR> PreEco
   ```
   This always returns *something* (it falls back to canonical names like
   `FmEqvPreEcoSynthesizeVsPreEcoSynRtl` even when nothing real was found) — **do not trust the
   printed name alone.** For each name returned, confirm it is backed by a real file on disk:
   `<FM_SESSION_DIR>/cmds/<name>.cmd` or a `<FM_SESSION_DIR>/rpts/<name>/` directory. If **none** of
   the returned names have real backing files, reject: tell the user plainly what was found instead
   (e.g. "only `FmEqvSynthesizeVsSynRtl` exists there — that's a normal post-synthesis check, not a
   PreEco-phase ECO target, so it can't be reused for fenets") and re-ask — either a different
   `FM_SESSION_DIR`, or fall back to `No`. **Never accept a non-PreEco target** (anything without
   `PreEco` in its name) as a substitute, and never silently proceed on the canonical-fallback string
   if it isn't backed by a real file.

   On success, record `RUN_FENETS=true`, `FM_SESSION_DIR=<path>`, and `PREECO_TARGETS=<the validated,
   comma-separated per-stage names>`. On `No`, record `RUN_FENETS=false` (no other fields needed).

   **Q3 — jira.** The ECO ticket number, e.g. `9899`.

   **Q4 — tile.** e.g. `umccmd`, `umcdat`, `ddrss_umc_t`.

   **Validate** before continuing: `mode ∈ {complete, simple}`; a TileBuilder `ref_dir` actually
   contains `revrc.main` (or, for simple + direct paths, the required RTL/netlist paths exist);
   `jira` and `tile` are non-empty. If a supplied value fails validation, re-ask that one question
   rather than stopping. Only stop with usage if the user declines to answer:
   `/genie_eco_msip:eco-analyze <complete|simple> <ref_dir> <jira> <tile>`.

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
   ECO_MODE=<mode> python3 script/genie_cli.py -i "analyze eco at <ref_dir> for <tile> <jira>" --execute
   ```
   This runs `eco_analyze.csh`, which validates the PreEco/PostEco netlists + RTL dirs and
   emits an `ECO_ANALYZE_MODE_ENABLED` block (with `TAG REF_DIR TILE JIRA LOG_FILE SPEC_FILE`).
   Simple mode creates `<ref_dir>/AI_ECO_FLOW_SIMPLE_<TAG>/`; complete mode creates `<ref_dir>/AI_ECO_FLOW_<TAG>/`.

   **Multi-user note — do NOT cd into `users/$USER`.** The standalone flow writes **all** output
   into the tile's `AI_ECO_FLOW_[SIMPLE_]<TAG>/` directory (writable by whoever owns the run), and only **reads** the
   shared config CSVs from `GENIE_ROOT` (world-readable). Running from `GENIE_ROOT` therefore needs
   **no per-user workspace and no write access to the repo** — any teammate can run it read-only, and
   notifications default to `$USER@amd.com`. (The old genie_agent "always run from `users/$USER`" rule
   does not apply here — that was for per-user `data/`/`runs/` isolation, which `AI_ECO_FLOW_DIR`
   already provides.)

3. **Hand off to the orchestrator.** When you see `ECO_ANALYZE_MODE_ENABLED`, spawn the
   `eco_orchestrator` agent (this plugin), passing the block's fields (`TAG REF_DIR TILE JIRA
   LOG_FILE SPEC_FILE`) **plus `MODE=<mode>`** (`complete` or `simple`). For `simple` mode, also pass
   `RUN_FENETS=<true|false>` and, when `true`, `FM_SESSION_DIR=<path>` and
   `PREECO_TARGETS=<validated names>` from Q2.5. The orchestrator branches on MODE: `complete` runs the
   full STUDY -> APPLY -> ROUND -> FINAL state machine with all hard gates (always with fenets);
   `simple` runs Steps 1,(2 optional),3,4 (via `config/eco_agents_simple/SIMPLE_ORCHESTRATOR.md`,
   which branches on `RUN_FENETS` for its optional Step 2) and stops. Do NOT run the phases yourself.
   - **For `simple` mode with `RUN_FENETS=false` (the default), spawn `eco_orchestrator` in the
     FOREGROUND (blocking — no `run_in_background`).** This path is fast (minutes) with no
     long-running FM/fenets phase, so running it foreground streams its per-step progress ("Step 1
     OK …", "Step 3a OK …") straight to the session. Using the background/auto-notify pattern here is
     what makes the flow look like it "spawned an agent and stopped" without any update.
   - **For `simple` mode with `RUN_FENETS=true`, spawn `eco_orchestrator` in the BACKGROUND** (same
     pattern as `complete` mode), since its optional Step 2 can take up to ~60 minutes of FM
     polling/retry — blocking the session that long in the foreground is not acceptable. Relay that
     Step 2 is running in the background before Steps 1/3/4 resume in the foreground once it returns
     (per `SIMPLE_ORCHESTRATOR.md`'s own internal foreground/background split for this case).
   - **For `complete` mode, spawn in the background** per the phase pattern (STUDY/APPLY/ROUND own
     their hours-long internal polling).

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
- **`mode` is required.** When the command is invoked bare (`/genie_eco_msip:eco-analyze`), ask for
  every input in order: **mode → TileBuilder dir or direct RTL paths → jira → tile**. Never fall
  back to `complete` silently.
- **Input styles for `simple` mode:** either a TileBuilder `ref_dir` (positional, like complete),
  or direct explicit fields (`RTL_BEFORE`/`RTL_AFTER` + `NETLIST_SYNTH` **required**, `NETLIST_PREPLACE`
  /`NETLIST_ROUTE` **optional** + `TILE`/`JIRA`), which are turned into a shim ref_dir by
  `eco_build_shim_refdir.py` and written back in place with `.preeco_bak`. A Synthesize-only run is
  allowed — the flow processes only the stages provided. Complete mode is TileBuilder-only (it needs
  Formality/PNR context, all 3 stages).
- Long-running phases (FM, fenets) are polled INSIDE the spawned agents, never from this
  command's session. See `agents/eco_orchestrator/AGENT.md`.
- **Simple mode's Step 2 (fenets) is optional (Q2.5), off by default.** Opting in requires a
  `FM_SESSION_DIR` with a genuine, validated **PreEco** FM target (never a generic/already-repurposed
  target like `FmEqvSynthesizeVsSynRtl` — that lacks the PreEco phase marker and may be pointed at an
  already-ECO'd netlist, which is circular for Step 2's purpose). See `SIMPLE_ORCHESTRATOR.md` STEP 2
  for the full validation/fallback behavior. Fenets failure/timeout in simple mode is non-fatal — Step
  3 always proceeds, with or without a rename map.
- This command does not modify any genie_agent file; it only launches the existing flow.
