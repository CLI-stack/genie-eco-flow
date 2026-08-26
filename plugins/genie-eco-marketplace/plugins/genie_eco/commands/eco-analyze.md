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
