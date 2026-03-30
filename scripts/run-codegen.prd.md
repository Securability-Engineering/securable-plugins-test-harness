# run-codegen Script — Product Requirements Document

> Canonical specification for the `run-codegen-*` family of scripts.
> Implementations exist (or should exist) for every `[shell]` × `[llm_cli_tool]` × `[plugin_type]` combination listed below.

---

## 1. Purpose

Automate an LLM-powered CLI tool to generate a complete project from a PRD file in multiple programming languages, each produced in one of the supported variants:

| Variant | Description |
|---------|-------------|
| **rawdog** | Plain generation — no security plugin, no FIASSE constraints. |
| **securable** | Generation with the `[securable_plugin]` active, enforcing FIASSE/SSEM securability attributes. |

The scripts exist to enable reproducible, side-by-side comparison of plain vs. security-enhanced code generation across languages and LLM CLI tools.

---

## 2. Placeholder Reference

Scripts are parameterised by the following variable dimensions. Implementations replace each placeholder with a concrete value.

| Placeholder | Description | Known Values |
|---|---|---|
| `[llm_cli_tool]` | The LLM CLI executable name | `claude`, `copilot`, `opencode` |
| `[llm_cli_tool_label]` | Human-readable name for status messages | `Claude Code`, `GitHub Copilot CLI` |
| `[shell]` | Script language / shell | `PowerShell`, `bash` |
| `[securable_plugin]` | The security plugin used for "securable" runs | `securable-claude-plugin`, `securable-copilot`, `securable-opencode-module` |
| `[plugin_repo_url]` | Git clone URL for the plugin | `https://github.com/Xcaciv/securable-claude-plugin.git`, `https://github.com/Xcaciv/securable-copilot.git` |
| `[plugin_temp_dir_name]` | Subfolder name for the cached plugin clone | `_plugin_temp`, `_securable_claude_plugin_temp`, `_securable_copilot_temp` |
| `[default_output_dir]` | Default root output folder | `./codegen-output`, `./copilot-codegen-output` |
| `[output_log_filename]` | Per-variation log file name | `claude-output.log`, `copilot-output.log` |
| `[context_fence_file]` | File placed in rawdog dirs to stop upward context loading | `CLAUDE.md` |
| `[finished_flag_file]` | Sentinel file marking a variation as complete | `.codegen-finished` |

---

## 3. Output Folder Structure

All implementations MUST produce the following directory layout under `[default_output_dir]`:

```
[default_output_dir]/
├── [plugin_temp_dir_name]/    # Cached clone of [securable_plugin] (transient)
├── aspnet/
│   ├── rawdog/                # Plain [llm_cli_tool] generation
│   │   ├── [context_fence_file]
│   │   ├── [output_log_filename]
│   │   ├── [finished_flag_file]
│   │   └── <generated project files...>
│   ├── securable/             # [securable_plugin]-enhanced generation
│       ├── [output_log_filename]
│       ├── [finished_flag_file]
│       └── <generated project files + plugin assets...>
├── jsp/
│   ├── rawdog/
│   ├── securable/
└── node/
    ├── rawdog/
    └── securable/
```

---

## 4. Parameters / Options

All implementations MUST accept the following parameters. The flag syntax is shell-appropriate (`-PrdFile` / `--prd`, etc.).

| Parameter | Required | Default | Description |
|---|---|---|---|
| `PrdFile` / `--prd` | Yes (except with `Clean`) | — | Path to the PRD markdown or text file to feed to the LLM. |
| `OutputDir` / `--output-dir` | No | `[default_output_dir]` | Root folder for all generated output. |
| `PluginRepo` / `--plugin-repo` | No | `[plugin_repo_url]` | Git URL of the `[securable_plugin]` repository. |
| `DryRun` / `--dry-run` | No | `false` | Print what would run without invoking `[llm_cli_tool]`. Creates stub plugin structures so the full flow can be traced. |
| `Resume` / `--resume` | No | `false` | Preserve existing output directories and skip variations that have a `[finished_flag_file]`. Useful when token limits or rate limits interrupt a run. |
| `Modes` / `--modes` | No | `rawdog,securable` | One or more generation modes to execute. Accepts a list (e.g., `rawdog,securable` or repeated flags). Implementations MUST validate all requested modes and fail early if any mode is unsupported. Error text MUST include the list of available modes. Supported modes are `rawdog` and `securable`. |
| `Clean` / `--clean` | No | `false` | Remove the cached plugin clone (`[plugin_temp_dir_name]`) and all `[finished_flag_file]` flags from the output directory, then exit. No generation is performed. `PrdFile` is NOT required when `Clean` is active. |

### Parameter Interactions

- `Resume` and `Clean` are mutually exclusive with normal generation semantics:
  - `Clean` exits immediately after cleanup — no other work is performed.
  - `Resume` only skips variations where `[finished_flag_file]` exists; all other variations proceed normally (preserving existing content rather than wiping).
- `Modes` accepts one or more values and defaults to the built-in baseline modes (`rawdog`, `securable`).
- If any value in `Modes` is not in the implementation's supported mode list, the script MUST fail before generation starts and print both the invalid values and all available mode options.
- Without `Resume`, existing target directories are **wiped and recreated** before generation.
- Without `Resume`, the `[finished_flag_file]` is **ignored** — completed variations are re-run.

---

## 5. Language Definitions

All implementations MUST use the same set of target languages and labels:

| Key | Label (used in prompts) |
|---|---|
| `aspnet` | ASP.NET Core (C#) Web API / MVC application |
| `jsp` | Java web application using JSP (Java Server Pages) and servlets |
| `node` | Node.js web application using Express.js |

### 5.1 Mode Definitions

Each implementation MUST maintain an explicit supported mode definition map/list and drive execution from that source.

Minimum required built-in modes:

| Mode | Required Behavior |
|---|---|
| `rawdog` | Plain generation with no security plugin constraints. |
| `securable` | Generation with `[securable_plugin]` assets installed and securability constraints applied. |

`securable` mode execution requirements:

- For `claude` and for `copilot` with `securable-claude-plugin`, use the `code-generation/securable-generation` play.
- For `copilot` with `securable-copilot` (native plugin), explicitly invoke the `securability-engineer` agent.
- For `opencode`, use `secure-generate`.
- Implementations MUST execute securable generation through the active plugin/tool's native play/command/agent mechanism, not by assuming one CLI's invocation semantics for all tools.
- If no usable securable mechanism exists for the selected plugin/CLI combination, fail early with a clear error.

Future mode additions MUST only require adding a new mode definition and should not require rewriting the core execution loop structure.

---

## 6. Execution Flow

### 6.1 Clean Mode (early exit)

When `Clean` is specified:

1. Resolve `OutputDir` to an absolute path.
2. If `[plugin_temp_dir_name]` exists under `OutputDir`, remove it recursively.
3. Recursively find and delete all `[finished_flag_file]` files under `OutputDir`.
4. Print a summary of what was removed.
5. Exit — no generation is performed.

### 6.2 Normal Mode

#### Step 0 — Initialisation

1. Resolve `PrdFile` and `OutputDir` to absolute paths.
2. Print a status banner showing all parameters.
3. Read the PRD file content into memory once.
4. Create the root `OutputDir` if it does not exist.

#### Step 1 — Prerequisite Check

1. Verify `[llm_cli_tool]` is on PATH (skip in `DryRun` mode).
2. Verify `git` is on PATH (skip in `DryRun` mode).
3. If a required tool is missing, terminate with a clear error message.

#### Step 2 — Clone the Plugin

1. Target directory: `OutputDir/[plugin_temp_dir_name]`.
2. If the directory already exists, run a git update in that directory (for example, `git pull --ff-only`) and print a notice.
3. If the existing directory is not a valid git working tree, fail with a clear error and instruct the user to run `Clean`.
4. Otherwise, run `git clone [plugin_repo_url] [plugin_temp_dir_name]`.
5. In `DryRun` mode: create a minimal stub directory structure so later steps can reference plugin files.

#### Step 3 — Generate per Language × Mode

For each language key (`aspnet`, `jsp`, `node`) and each selected mode from `Modes`:

##### 3a. Resume / Skip Check

- If `Resume` is active **and** `[finished_flag_file]` exists in the target directory → skip this variation.
- Otherwise, proceed.

##### 3b. Directory Preparation

- **Without `Resume`**: If the target directory exists, remove it recursively, then recreate it.
- **With `Resume`**: If the target directory exists, keep it as-is.
- Ensure the target directory exists.

##### 3c. Context Isolation (rawdog only)

- Write a minimal `[context_fence_file]` into the rawdog target directory.
- Purpose: prevents `[llm_cli_tool]` from walking up the directory tree and loading plugin files from parent directories.
- Content:
  ```
  # codegen-test: rawdog baseline
  # This file exists only to prevent context from parent directories
  # being loaded into this isolated test run.  Do not add instructions here.
  ```

##### 3d. Plugin Installation (securable)

- Copy plugin assets from the cached clone into the target directory.
- Assets vary by `[securable_plugin]`:

  | Plugin | Assets Copied |
  |---|---|
  | `securable-claude-plugin` | `.claude/`, `skills/`, `data/`, `CLAUDE.md` |
  | `securable-copilot` | `.github/` (includes `prompts/`, `agents/`, `copilot-instructions.md`) |

##### 3e. Securable Workflow Dispatch

When processing `securable` mode, dispatch generation using the plugin/tool native mechanism:

- `claude` + `securable-claude-plugin`: run `code-generation/securable-generation`.
- `copilot` + `securable-claude-plugin`: run `code-generation/securable-generation`.
- `copilot` + `securable-copilot`: explicitly use the `securability-engineer` agent.
- `opencode`: run `secure-generate`.

In `DryRun`, print the exact dispatch action that would run.

##### 3f. Prompt Construction

**Rawdog prompt** (all tools):
```
Generate a complete, working [lang_label] project based on the following PRD.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with setup and run instructions.
When the project is fully complete, create a file named [finished_flag_file] in the
current working directory. Only create this file after all required project files are done.

PRD:
---
<prd_content>
---
```

**Securable prompt** (plugin-loaded tools):
```
You are operating with the [securable_plugin] active ([context_files] are
present in this directory).

Use the installed plugin files in the working directory as the active source of
securability constraints.

Generate a complete, working [lang_label] project based on the following PRD,
applying the plugin's FIASSE/SSEM constraints throughout all generated code.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with:
  - Setup and run instructions
  - A brief SSEM attribute coverage summary describing how each of the nine
    attributes is addressed in the generated code
When the project is fully complete, create a file named [finished_flag_file] in the
current working directory. Only create this file after all required project files are done.

PRD:
---
<prd_content>
---
```

##### 3g. Plugin-Loaded Constraint Handling

For CLIs that automatically load project-local plugin files, the securable prompt
SHOULD rely on the installed plugin assets rather than duplicating plugin content
inline in the prompt.

Implementations MAY still embed workflow content for one-off operations that are
not automatically dispatched by the CLI.

##### 3h. Write Permissions Configuration

Before invoking `[llm_cli_tool]`, configure write permissions so the tool can write to the target directory without interactive prompts:

| Tool | Mechanism |
|---|---|
| `claude` | Write `.claude/claude.json` with `allowed_write_directories` pointing to the target dir |
| `copilot` | Write `.claude/claude.json` with `allowed_write_directories` listing all target dirs; pass `--add-dir` on invocation |

##### 3i. LLM CLI Invocation

Invoke `[llm_cli_tool]` non-interactively in the target directory. The tool writes generated files directly into the working directory.

| Tool | Invocation Pattern | Permission Bypass | Prompt Delivery |
|---|---|---|---|
| `claude` | `claude --print --permission-mode bypassPermissions` | `--permission-mode bypassPermissions` | Piped via stdin |
| `copilot` | `copilot -p <prompt-file> --allow-all-tools --add-dir <dir> --allow-all-urls --no-alt-screen` | `--allow-all-tools`, `--allow-all-urls` | Written to a temp file, path passed via `-p` |
| `copilot` (variant) | `copilot -p <prompt-file> --allow-tool=write --add-dir <dir> --allow-all-urls --no-alt-screen` | `--allow-tool=write`, `--allow-all-urls` | Written to a temp file, path passed via `-p` |

- All output (stdout + stderr) MUST be captured to `[output_log_filename]` in the target directory via `tee` or equivalent.
- Non-zero exit codes produce a **warning** (not a fatal error) so the loop continues to the next variation.
- Temp prompt files (copilot only) MUST be cleaned up in a finally/trap block.
- When `Resume` is active, pass `--resume` to copilot invocations.

#### Step 4 — Summary

Print a structured summary showing:
1. The generated folder structure with annotations for each mode.
2. Where to find log files.
3. In `DryRun` mode: a clear notice that no LLM calls were made.

---

## 7. DryRun Behaviour

When `DryRun` is active, the script MUST:

- Skip prerequisite tool checks (print a notice instead).
- Create stub plugin directory structures with placeholder files instead of running `git clone`.
- Print each command that **would** run (working directory, prompt preview) without executing it.
- Still exercise the full control flow (directory creation, prompt construction, iteration) so the operator can verify correctness.

---

## 8. Error Handling

- Use strict mode (`Set-StrictMode -Version Latest` / `set -euo pipefail`).
- Stop on errors by default (`$ErrorActionPreference = "Stop"` / `set -e`).
- LLM CLI non-zero exit codes produce a **warning** and continue to the next variation (do not abort the entire run).
- `git update` (for existing cache directories) failure is **fatal** — terminate immediately.
- `git clone` failure is **fatal** — terminate immediately.
- Missing required tools are **fatal** — terminate with a clear message.

---

## 9. Implementation Matrix

| Shell | LLM Tool | Plugin | Script Name | Status |
|---|---|---|---|---|
| PowerShell | `claude` | `securable-claude-plugin` | `PowerShell/run-codegen-claude.ps1` | Implemented |
| PowerShell | `copilot` | `securable-claude-plugin` | `PowerShell/run-codegen-copilot-claude-plugin.ps1` | Implemented |
| PowerShell | `copilot` | `securable-copilot` | `PowerShell/run-codegen-copilot.ps1` | Implemented |
| PowerShell | `opencode` | `securable-opencode-module` | `PowerShell/run-codegen-opencode.ps1` | Implemented |
| bash | `claude` | `securable-claude-plugin` | `bash/run-codegen-claude.sh` | Implemented |
| bash | `copilot` | `securable-claude-plugin` | `bash/run-codegen-copilot-claude-plugin.sh` | Implemented |
| bash | `copilot` | `securable-copilot` | `bash/run-codegen-copilot.sh` | Implemented |
| bash | `opencode` | `securable-opencode-module` | `bash/run-codegen-opencode.sh` | Implemented |

---

## 10. Known Gaps

All previously identified gaps (bash `--resume`, `--clean`, `[finished_flag_file]` in prompts, and missing script variants) have been resolved. All shell × tool × plugin combinations in the matrix above are fully implemented.
