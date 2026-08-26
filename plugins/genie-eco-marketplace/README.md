# genie-eco-marketplace

Internal Claude Code plugin marketplace for the **Genie AI ECO flow**.

## Plugins
| Plugin | Description |
|---|---|
| `genie_eco` | Run the Genie AI ECO flow (STUDY → APPLY → ROUND → FINAL) end to end. Thin launcher over the genie_agent repo. See `plugins/genie_eco/README.md`. |

## Add + install
```
/plugin marketplace add /home/abinbaba/eco_flow/plugins/genie-eco-marketplace
/plugin install genie_eco@genie-eco-marketplace
```
Then:
```
/eco-analyze <ref_dir> <tile> <jira>
```

## Layout
```
genie-eco-marketplace/
├── .claude-plugin/marketplace.json     # catalog (1 plugin: genie_eco)
├── README.md
└── plugins/genie_eco/
    ├── .claude-plugin/plugin.json
    ├── README.md
    ├── commands/eco-analyze.md
    ├── agents/eco_orchestrator/AGENT.md
    └── skills/genie_eco/SKILL.md
```

## Design: thin launcher
The plugin ships only markdown (command + orchestrator + skill). All scripts and sub-agents run in
place from the genie_agent repo at `/home/abinbaba/eco_flow` (hardcoded —
"Option A"). This avoids duplicating 62 scripts / 13 sub-agent MDs and keeps the PD/FM/LSF
environment coupling intact. It is not a standalone/portable ECO tool.
