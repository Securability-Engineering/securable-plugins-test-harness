# securable-plugins-test-harness

This repository benchmarks securable plugin behavior across CLI coding tools by generating projects from PRDs and comparing outputs across language and mode combinations.

## Current Mode Model

Supported generation modes:

- `rawdog`: baseline generation with no securable plugin active.
- `securable`: generation with a securable plugin/module active.

The previous `fiassed` mode has been removed from requirements and implementations.

## Securable Dispatch Requirements

Securable runs must use the native plugin/tool dispatch mechanism:

- Claude and Copilot with `securable-claude-plugin`: play `code-generation/securable-generation`
- Copilot with native `securable-copilot` plugin: agent `securability-engineer`
- OpenCode with `securable-opencode-module`: command `secure-generate`

## Script Documentation

- PowerShell scripts: [scripts/PowerShell/README.md](scripts/PowerShell/README.md)
- bash scripts: [scripts/bash/README.md](scripts/bash/README.md)
- Canonical requirements spec: [scripts/run-codegen.prd.md](scripts/run-codegen.prd.md)

For generated output snapshots, see [fiasse benchmark output](https://github.com/Xcaciv/fiasse_benchmark_output).
