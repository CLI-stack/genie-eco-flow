# genie_eco plugin

Thin-launcher Claude Code plugin for the **Genie AI ECO flow** (STUDY → APPLY → ROUND → FINAL):
RTL diff → per-stage gate-level ECO study → apply → Formality verification, with hard validator gates.

## What's in the plugin
| Component | File | Role |
|---|---|---|
| Slash command | `commands/eco-analyze.md` | `/eco-analyze <ref_dir> <tile> <jira>` — validates inputs, emits the analyze signal, hands off to the orchestrator |
| Orchestrator agent | `agents/eco_orchestrator/AGENT.md` | the phase state machine + hard gates (ported from the repo's `.claude/CLAUDE.md`) |
| Skill | `skills/genie_eco/SKILL.md` | surfaces the flow in `/plugin`; defers to the command/agent |

The plugin ships **only markdown**. All executable logic — 62 scripts (`script/eco_scripts/*.py`),
13 sub-agent MDs (`config/eco_agents/*.md`), the FM/fenets `.csh`, and `genie_cli.py` — runs **in
place** from the genie_agent repo.

## Hardcoded repo path (Option A)
```
GENIE_ROOT = /home/abinbaba/eco_flow
```
Referenced in `commands/eco-analyze.md` and `agents/eco_orchestrator/AGENT.md`. If the repo moves,
update it in both places.

## Requirements
- The genie_agent repo present at `GENIE_ROOT`, with the user set up (`users/$USER/`).
- The PD environment the flow needs: TileBuilder, Formality (`TileBuilderIntFM`), LSF.
- This is **not** a standalone tool — it launches the existing flow; it does not bundle EDA tools.

## Usage
```
/plugin marketplace add /home/abinbaba/eco_flow/plugins/genie-eco-marketplace
/plugin install genie_eco@genie-eco-marketplace
/eco-analyze <ref_dir> umccmd 9899
```

## Gates (enforced by the orchestrator before APPLY)
1. `<AI_ECO_FLOW_DIR>/data/<TAG>_eco_validate_step3.json` present AND `passed == true` (structural).
2. `<AI_ECO_FLOW_DIR>/data/<TAG>_eco_functional_precheck.json` present AND `passed == true` (functional oracle).

Both must pass or APPLY is refused.
