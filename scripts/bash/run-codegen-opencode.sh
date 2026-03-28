#!/usr/bin/env bash
# =============================================================================
# run-codegen-opencode.sh
#
# Automates OpenCode CLI to generate a project from a PRD in 3 languages,
# each with a selectable generation mode such as rawdog, securable, or fiassed.
#
# Uses the securable-opencode-module for the securable runs. The module is
# copied into .securable/ in each target directory, and an opencode.json is
# written at the project root to configure the MCP server and instructions.
# OpenCode discovers the MCP tools and instructions automatically.
#
# OpenCode invocation:
#   opencode run -f <prompt-file>
#   (run mode suppresses the interactive TUI; the agent writes files directly
#   into the current working directory)
#
# Output structure:
#   <output-dir>/
#     aspnet/
#       rawdog/     <- Plain OpenCode generation
#       securable/  <- Generation with securable-opencode-module active
#       fiassed/    <- securable + PRD enhancement workflow
#     jsp/
#       rawdog/
#       securable/
#       fiassed/
#     node/
#       rawdog/
#       securable/
#       fiassed/
#
# Usage:
#   ./run-codegen-opencode.sh --prd <file> [--output-dir <dir>] [--plugin-repo <url>] [--dry-run] [--resume] [--modes <list>]
#   ./run-codegen-opencode.sh --clean [--output-dir <dir>]
#
# Options:
#   --prd          Path to your PRD markdown or text file (required unless --clean)
#   --output-dir   Root folder for generated output (default: ./opencode-codegen-output)
#   --plugin-repo  Git URL of the securable-opencode-module (default: canonical repo)
#   --dry-run      Print what would run without calling OpenCode
#   --resume       Skip completed variations and preserve existing directories
#   --modes        Comma-separated or repeated mode list (default: rawdog,securable,fiassed)
#   --clean        Remove cached module clone and finished flags, then exit
#   -h, --help     Show this help text
#
# Requirements:
#   - bash 4+, git, opencode, python (3.10+ for MCP server), tee, mktemp
#
# Examples:
#   ./run-codegen-opencode.sh --prd ./my-prd.md
#   ./run-codegen-opencode.sh --prd ./my-prd.md --output-dir ~/tests/opencode --dry-run
#   ./run-codegen-opencode.sh --prd ./my-prd.md --modes fiassed
#   ./run-codegen-opencode.sh --prd ./my-prd.md --resume
#   ./run-codegen-opencode.sh --clean --output-dir ~/tests/opencode
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# ANSI colour helpers
# -----------------------------------------------------------------------------
_cyan()    { printf '\033[0;36m%s\033[0m\n' "$*"; }
_green()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
_yellow()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
_magenta() { printf '\033[0;35m%s\033[0m\n' "$*"; }
_gray()    { printf '\033[0;90m%s\033[0m\n' "$*"; }
_red()     { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }

write_step() { echo; _cyan ">>> $*"; }

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
PRD_FILE=""
OUTPUT_DIR="./opencode-codegen-output"
PLUGIN_REPO="https://github.com/Xcaciv/securable-opencode-module.git"
DRY_RUN=false
RESUME=false
CLEAN=false
FINISHED_FLAG=".codegen-finished"
MODES_INPUTS=()

# -----------------------------------------------------------------------------
# Language definitions
# -----------------------------------------------------------------------------
LANG_KEYS=("aspnet" "jsp" "node")
declare -A LANG_LABELS=(
    ["aspnet"]="ASP.NET Core (C#) Web API / MVC application"
    ["jsp"]="Java web application using JSP (Java Server Pages) and servlets"
    ["node"]="Node.js web application using Express.js"
)

declare -A MODE_IS_SECURABLE=(
    [rawdog]=false
    [securable]=true
    [fiassed]=true
)

declare -A MODE_IS_FIASSED=(
    [rawdog]=false
    [securable]=false
    [fiassed]=true
)

declare -A MODE_SUMMARY=(
    [rawdog]="plain OpenCode generation"
    [securable]="FIASSE/SSEM secured generation"
    [fiassed]="FIASSE/SSEM secured generation with PRD securability enhancement"
)

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# =\+$/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prd)          PRD_FILE="$2";    shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";  shift 2 ;;
        --plugin-repo)  PLUGIN_REPO="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true;     shift   ;;
        --resume)       RESUME=true;      shift   ;;
        --modes)        MODES_INPUTS+=("$2"); shift 2 ;;
        --clean)        CLEAN=true;       shift   ;;
        -h|--help)      usage ;;
        *) _red "Unknown option: $1"; usage ;;
    esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

if [[ ${#MODES_INPUTS[@]} -eq 0 ]]; then
    MODES_INPUTS=("rawdog" "securable" "fiassed")
fi

MODES=()
declare -A _seen_modes=()
for mode_arg in "${MODES_INPUTS[@]}"; do
    IFS=',' read -r -a _parts <<< "$mode_arg"
    for candidate in "${_parts[@]}"; do
        normalized="${candidate,,}"
        normalized="${normalized//[[:space:]]/}"
        [[ -z "$normalized" ]] && continue
        if [[ -z "${MODE_SUMMARY[$normalized]+x}" ]]; then
            _red "Error: Unsupported mode '$normalized'. Available modes: rawdog, securable, fiassed"
            exit 1
        fi
        if [[ -z "${_seen_modes[$normalized]+x}" ]]; then
            MODES+=("$normalized")
            _seen_modes[$normalized]=1
        fi
    done
done

if [[ ${#MODES[@]} -eq 0 ]]; then
    _red "Error: At least one mode must be provided via --modes. Available modes: rawdog, securable, fiassed"
    exit 1
fi

# --clean mode: early exit — no PRD required
if [[ "$CLEAN" == true ]]; then
    _magenta ">>> Cleaning cache files from $OUTPUT_DIR"

    PLUGIN_TEMP="$OUTPUT_DIR/_securable_opencode_temp"
    if [[ -d "$PLUGIN_TEMP" ]]; then
        _yellow "  Removing module cache: $PLUGIN_TEMP"
        rm -rf "$PLUGIN_TEMP"
    else
        _gray "  Module cache not found (already clean)"
    fi

    flags_removed=0
    if [[ -d "$OUTPUT_DIR" ]]; then
        while IFS= read -r -d '' flag_file; do
            _yellow "  Removing finished flag: $flag_file"
            rm -f "$flag_file"
            ((flags_removed++))
        done < <(find "$OUTPUT_DIR" -name "$FINISHED_FLAG" -print0 2>/dev/null)
    fi
    _gray "  Removed $flags_removed finished flag(s)."

    _magenta ">>> Clean complete."
    exit 0
fi

if [[ -z "$PRD_FILE" ]]; then
    _red "Error: --prd is required."
    usage
fi

if [[ ! -f "$PRD_FILE" ]]; then
    _red "Error: PRD file not found: $PRD_FILE"
    exit 1
fi

PRD_FILE="$(cd "$(dirname "$PRD_FILE")" && pwd)/$(basename "$PRD_FILE")"

# -----------------------------------------------------------------------------
# Prerequisite check
# -----------------------------------------------------------------------------
assert_tool() {
    local name="$1"
    if ! command -v "$name" &>/dev/null; then
        _red "Error: Required tool '$name' not found on PATH. Please install it."
        exit 1
    fi
    _gray "  [OK] $name -> $(command -v "$name")"
}

# -----------------------------------------------------------------------------
# install_module  <module-source-dir>  <target-dir>
#
# Copies the securable-opencode-module into .securable/ in the target
# directory, and writes an opencode.json at the target root to configure
# the MCP server, instructions, and permissions.
#
# Module layout in target:
#   .securable/instructions.md
#   .securable/tools/mcp_server.py
#   .securable/workflows/
#   .securable/data/fiasse/
#   .securable/data/asvs/
#   .securable/templates/
#   .securable/scripts/
#   opencode.json  (MCP server config + permissions)
# -----------------------------------------------------------------------------
install_module() {
    local src="$1"
    local dst="$2"
    local dst_securable="$dst/.securable"

    mkdir -p "$dst_securable"

    # Copy module directories
    for asset_dir in tools workflows data templates scripts; do
        if [[ -d "$src/$asset_dir" ]]; then
            cp -r "$src/$asset_dir" "$dst_securable/"
            _gray "  Installed $asset_dir/ -> $dst_securable/$asset_dir"
        fi
    done

    # Copy module files
    if [[ -f "$src/instructions.md" ]]; then
        cp "$src/instructions.md" "$dst_securable/instructions.md"
        _gray "  Installed instructions.md -> $dst_securable/instructions.md"
    fi

    # Write opencode.json at target root with MCP server config and permissions
    cat > "$dst/opencode.json" <<'OCJSON'
{
  "$schema": "https://opencode.ai/config.json",
  "mcpServers": {
    "securable": {
      "command": "python",
      "args": ["./.securable/tools/mcp_server.py"],
      "env": {
        "SECURABLE_DATA_DIR": "./.securable/data",
        "SECURABLE_TEMPLATES_DIR": "./.securable/templates",
        "SECURABLE_WORKFLOWS_DIR": "./.securable/workflows"
      }
    }
  },
  "instructions": "./.securable/instructions.md",
  "permission": {
    "edit": "allow",
    "bash": "allow"
  }
}
OCJSON
    _gray "  Wrote opencode.json -> $dst/opencode.json"
}

# -----------------------------------------------------------------------------
# get_secure_instructions  <module-source-dir>
#
# Reads instructions.md and the review workflow from the module, printing them
# to stdout for inline embedding in the prompt.
# -----------------------------------------------------------------------------
get_secure_instructions() {
    local src="$1"
    local instr_file="$src/instructions.md"
    local review_file="$src/workflows/securability-engineering-review.md"
    local output=""

    if [[ -f "$instr_file" ]]; then
        output+="$(cat "$instr_file")"$'\n\n'
    fi

    if [[ -f "$review_file" ]]; then
        output+="---"$'\n'"# Securability Engineering Review Workflow"$'\n'
        output+="$(cat "$review_file")"$'\n'
    fi

    if [[ -n "$output" ]]; then
        printf '%s' "$output"
        return
    fi

    # Fallback if module files not found
    cat <<'FALLBACK'
Apply FIASSE/SSEM securability engineering principles as hard constraints.
Satisfy all nine SSEM attributes:
  Maintainability: Analyzability, Modifiability, Testability
  Trustworthiness: Confidentiality, Accountability, Authenticity
  Reliability:     Availability, Integrity, Resilience
Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all
trust boundaries. Enforce the Derived Integrity Principle for business-critical
values. Produce structured audit logging for all accountable actions.
FALLBACK
}

# -----------------------------------------------------------------------------
# resolve_fiassed_workflow_path  <module-source-dir>
#
# Resolves the PRD enhancement workflow used by fiassed mode.
# -----------------------------------------------------------------------------
resolve_fiassed_workflow_path() {
    local src="$1"
    local candidate
    local candidates=(
        "$src/workflows/prd-securability-enhanced.md"
        "$src/workflows/requirements-analysis/prd-securability-enhanced.md"
        "$src/workflows/prd-securability-enhancement.md"
        "$src/workflows/requirements-analysis/prd-securability-enhancement.md"
        "$src/workflows/prd-fiasse-asvs-enhancement.md"
        "$src/workflows/requirements-analysis/prd-fiasse-asvs-enhancement.md"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    if [[ -d "$src/workflows" ]]; then
        candidate="$(find "$src/workflows" -type f -name '*.md' 2>/dev/null | grep -E 'prd.*secur.*enhanc|prd.*fiasse.*asvs.*enhanc' | sort | head -n 1 || true)"
        if [[ -n "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    fi

    return 1
}

# -----------------------------------------------------------------------------
# get_fiassed_prd_content  <working-dir>  <module-source-dir>  <label>  <input-prd-file>
#
# Runs OpenCode to execute the PRD securability enhancement workflow and prints
# the enhanced PRD markdown to stdout.
# -----------------------------------------------------------------------------
get_fiassed_prd_content() {
    local working_dir="$1"
    local plugin_source="$2"
    local label="$3"
    local input_prd_file="$4"
    local workflow_path=""

    if ! workflow_path="$(resolve_fiassed_workflow_path "$plugin_source")"; then
        _red "Error: fiassed mode requires a PRD enhancement workflow in the plugin repository (expected under workflows/)."
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] Would enhance PRD via fiassed workflow for: $label" >&2
        _yellow "  [DRY-RUN] Workflow file: $workflow_path" >&2
        cat "$input_prd_file"
        return 0
    fi

    local workflow_content
    workflow_content="$(cat "$workflow_path")"

    local enhance_prompt_file
    local enhance_log_file
    local enhanced_prd_file
    local enhanced_output
    local exit_code

    enhance_prompt_file="$(mktemp /tmp/opencode_prd_enhance_XXXXXX.txt)"
    enhance_log_file="$working_dir/opencode-prd-enhancement.log"
    enhanced_prd_file="$working_dir/enhanced-prd.md"

    cat > "$enhance_prompt_file" <<PROMPT
Run the following PRD securability enhancement workflow exactly.

Output requirements:
- Return ONLY the enhanced PRD markdown
- Do not wrap output in code fences
- Do not add explanations before or after

=== WORKFLOW: prd securability enhanced ===
${workflow_content}
=== END WORKFLOW ===

=== INPUT PRD ===
$(cat "$input_prd_file")
=== END INPUT PRD ===
PROMPT

    write_step "Enhancing PRD via fiassed workflow for: $label"
    _gray "  Workflow   : $workflow_path"
    _gray "  Log file   : $enhance_log_file"

    set +e
    enhanced_output="$(
        cd "$working_dir"
        export OPENCODE_PERMISSION='{"edit": "allow", "bash": "allow"}'
        opencode run -f "$enhance_prompt_file" 2>&1 | tee "$enhance_log_file"
    )"
    exit_code=$?
    set -e

    rm -f "$enhance_prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        _red "Error: opencode PRD enhancement failed with exit code $exit_code for $label — check $enhance_log_file"
        return 1
    fi

    if [[ -z "${enhanced_output//[[:space:]]/}" ]]; then
        _red "Error: opencode PRD enhancement produced empty output for $label — check $enhance_log_file"
        return 1
    fi

    printf '%s\n' "$enhanced_output" > "$enhanced_prd_file"
    _gray "  Enhanced PRD written: $enhanced_prd_file"

    printf '%s' "$enhanced_output"
}

# -----------------------------------------------------------------------------
# set_opencode_permissions  <target-dir>
#
# Writes or merges permission config into opencode.json at the target root.
# Also sets the OPENCODE_PERMISSION env var at invocation time (done in
# invoke_opencode).
# -----------------------------------------------------------------------------
set_opencode_permissions() {
    local target_dir="$1"
    local config_path="$target_dir/opencode.json"

    if [[ ! -f "$config_path" ]]; then
        cat > "$config_path" <<'OCJSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "edit": "allow",
    "bash": "allow"
  }
}
OCJSON
    fi
    # If it already exists (e.g. from install_module), permissions are
    # already included in the template. No further action needed.
}

# -----------------------------------------------------------------------------
# invoke_opencode  <working-dir>  <prompt-file>  <label>
#
# Runs `opencode run -f <prompt-file>` in the given directory.
# The run subcommand suppresses the interactive TUI.
# Output is tee'd to opencode-output.log.
#
# Write permissions are granted via:
#   1. OPENCODE_PERMISSION env var (set for the subprocess)
#   2. opencode.json permission config (written by set_opencode_permissions)
# -----------------------------------------------------------------------------
invoke_opencode() {
    local working_dir="$1"
    local prompt_file="$2"
    local label="$3"
    local log_file="$working_dir/opencode-output.log"

    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] Would run in: $working_dir"
        _yellow "  [DRY-RUN] Prompt starts: $(head -c 120 "$prompt_file")..."
        return
    fi

    write_step "Running OpenCode for: $label"
    _gray "  Output dir : $working_dir"
    _gray "  Log file   : $log_file"

    (
        cd "$working_dir"
        # Set permission env var for the subprocess
        export OPENCODE_PERMISSION='{"edit": "allow", "bash": "allow"}'
        opencode run -f "$prompt_file" 2>&1 | tee "$log_file"
    ) || _yellow "  WARNING: opencode run exited non-zero for $label — check $log_file"
}

# =============================================================================
# MAIN
# =============================================================================

_magenta ">>> Starting OpenCode codegen run"
_gray "  PRD file   : $PRD_FILE"
_gray "  Output dir : $OUTPUT_DIR"
_gray "  Dry run    : $DRY_RUN"
_gray "  Resume     : $RESUME"
_gray "  Modes      : ${MODES[*]}"

write_step "Checking prerequisites ..."
if [[ "$DRY_RUN" == false ]]; then
    assert_tool "opencode"
    assert_tool "git"
    assert_tool "python"
else
    _yellow "  [DRY-RUN] Skipping tool checks"
fi

PRD_CONTENT="$(cat "$PRD_FILE")"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 1 — Clone the module once
# ---------------------------------------------------------------------------
PLUGIN_TEMP="$OUTPUT_DIR/_securable_opencode_temp"

if [[ -d "$PLUGIN_TEMP" ]]; then
    write_step "Module already cloned at $PLUGIN_TEMP — skipping clone"
else
    write_step "Cloning securable-opencode-module ..."
    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] git clone $PLUGIN_REPO $PLUGIN_TEMP"
        # Create stub structure for dry-run
        mkdir -p "$PLUGIN_TEMP/tools"
        mkdir -p "$PLUGIN_TEMP/workflows"
        mkdir -p "$PLUGIN_TEMP/data/fiasse"
        mkdir -p "$PLUGIN_TEMP/data/asvs"
        mkdir -p "$PLUGIN_TEMP/templates"
        mkdir -p "$PLUGIN_TEMP/scripts"
        echo "# securable-opencode-module stub (dry-run)" > "$PLUGIN_TEMP/instructions.md"
        echo "# prd securability enhanced (dry-run stub)" > "$PLUGIN_TEMP/workflows/prd-securability-enhanced.md"
        echo "{}" > "$PLUGIN_TEMP/opencode.json"
    else
        git clone "$PLUGIN_REPO" "$PLUGIN_TEMP"
    fi
fi

SECURE_INSTRUCTIONS="$(get_secure_instructions "$PLUGIN_TEMP")"

# ---------------------------------------------------------------------------
# Step 2 — Loop over languages × modes
# ---------------------------------------------------------------------------
PROMPT_TMP="$(mktemp /tmp/opencode_prompt_XXXXXX.txt)"
trap 'rm -f "$PROMPT_TMP"' EXIT

for lang_key in "${LANG_KEYS[@]}"; do
    lang_label="${LANG_LABELS[$lang_key]}"

    for mode in "${MODES[@]}"; do
        target_dir="$OUTPUT_DIR/$lang_key/$mode"
        finished_flag_path="$target_dir/$FINISHED_FLAG"

        # ------------------------------------------------------------------
        # Resume: skip completed variations
        # ------------------------------------------------------------------
        if [[ "$RESUME" == true ]] && [[ -f "$finished_flag_path" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                _yellow "  [DRY-RUN] Would skip completed variation: $target_dir"
            else
                _green "  Skipping completed variation: $target_dir"
            fi
            continue
        fi

        # ------------------------------------------------------------------
        # Directory preparation
        # ------------------------------------------------------------------
        if [[ -d "$target_dir" ]]; then
            if [[ "$RESUME" == true ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    _yellow "  [DRY-RUN] Would keep existing (resume mode): $target_dir"
                else
                    _gray "  Resume mode: keeping existing directory: $target_dir"
                fi
            else
                if [[ "$DRY_RUN" == true ]]; then
                    _yellow "  [DRY-RUN] Would wipe existing: $target_dir"
                else
                    _gray "  Cleaning previous run: $target_dir"
                    rm -rf "$target_dir"
                fi
            fi
        fi
        mkdir -p "$target_dir"

        # ------------------------------------------------------------------
        # Isolation: place a minimal AGENTS.md in rawdog directories as a
        # context fence. OpenCode uses AGENTS.md as the project context file,
        # so placing one here prevents it from walking up the directory tree
        # and loading module files from parent directories.
        # ------------------------------------------------------------------
        if [[ "${MODE_IS_SECURABLE[$mode]}" == "false" ]]; then
            cat > "$target_dir/AGENTS.md" <<'FENCE'
# codegen-test: rawdog baseline
# This file exists only to prevent context from parent directories
# being loaded into this isolated test run.  Do not add instructions here.
FENCE
        fi

        effective_prd_file="$(mktemp /tmp/opencode_effective_prd_XXXXXX.md)"
        printf '%s\n' "$PRD_CONTENT" > "$effective_prd_file"

        if [[ "${MODE_IS_SECURABLE[$mode]}" == "false" ]]; then
            cat > "$PROMPT_TMP" <<PROMPT
Generate a complete, working ${lang_label} project based on the following PRD.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with setup and run instructions.
When the project is fully complete, create a file named ${FINISHED_FLAG} in the
current working directory. Only create this file after all required project files are done.

PRD:
---
$(cat "$effective_prd_file")
---
PROMPT

        else
            # Install module files so OpenCode auto-loads MCP server
            install_module "$PLUGIN_TEMP" "$target_dir"

            # Ensure permissions are set before fiassed enhancement run
            if [[ "$DRY_RUN" == false ]]; then
                set_opencode_permissions "$target_dir"
            fi

            if [[ "${MODE_IS_FIASSED[$mode]}" == "true" ]]; then
                get_fiassed_prd_content "$target_dir" "$PLUGIN_TEMP" "$lang_key / $mode" "$effective_prd_file" > "$effective_prd_file"
            fi

            cat > "$PROMPT_TMP" <<PROMPT
You are operating with the securable-opencode-module active (.securable/ directory
and opencode.json are present in this directory). The MCP tools securability_review,
secure_generate, and fiasse_lookup are available.

The following securability engineering instructions are your primary
constraints — treat them as non-negotiable design requirements.

=== SECURABLE-OPENCODE-MODULE INSTRUCTIONS ===
${SECURE_INSTRUCTIONS}
=== END MODULE INSTRUCTIONS ===

Now generate a complete, working ${lang_label} project based on the following PRD,
applying every FIASSE/SSEM constraint above throughout all generated code.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with:
  - Setup and run instructions
  - A brief SSEM attribute coverage summary describing how each of the nine
    attributes is addressed in the generated code
When the project is fully complete, create a file named ${FINISHED_FLAG} in the
current working directory. Only create this file after all required project files are done.

PRD:
---
$(cat "$effective_prd_file")
---
PROMPT
        fi

    rm -f "$effective_prd_file"

        # Ensure OpenCode has write permissions
        if [[ "$DRY_RUN" == false ]]; then
            set_opencode_permissions "$target_dir"
        fi

        invoke_opencode "$target_dir" "$PROMPT_TMP" "$lang_key / $mode"
    done
done

# ---------------------------------------------------------------------------
# Step 3 — Summary
# ---------------------------------------------------------------------------
write_step "All done!"
echo
_cyan "Generated folder structure:"
for lang_key in "${LANG_KEYS[@]}"; do
    _cyan "  $OUTPUT_DIR/$lang_key/"
    for mode in "${MODES[@]}"; do
        _gray "    $mode/  <- ${MODE_SUMMARY[$mode]}"
    done
done
echo
_gray "Each folder contains an opencode-output.log with the full CLI response."

if [[ "$DRY_RUN" == true ]]; then
    echo
    _yellow "[DRY-RUN MODE] No OpenCode calls were made."
    _yellow "Remove --dry-run to execute for real."
fi
