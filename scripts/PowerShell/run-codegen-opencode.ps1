#Requires -Version 5.1
<#
.SYNOPSIS
    Automates OpenCode to generate a project from a PRD in 3 languages,
    each with a "rawdog" (plain) and "securable" (FIASSE module) variant.

.DESCRIPTION
    Produces the following folder structure:
        <OutputDir>/
            aspnet/
                rawdog/     <- Plain OpenCode generation
                securable/  <- Generation with securable-opencode-module active
            jsp/
                rawdog/
                securable/
            node/
                rawdog/
                securable/

    Plugin activation mechanism (securable mode):
        The script clones securable-opencode-module once, then copies the
        module into .securable/ in each securable target directory and writes
        an opencode.json with permissions.

    OpenCode invocation:
        opencode run -f <prompt-file>
        (run mode suppresses interactive TUI; the agent writes files directly
        into the current working directory)

.PARAMETER PrdFile
    Path to your PRD markdown or text file. Required.

.PARAMETER OutputDir
    Root folder for all generated output. Defaults to .\opencode-codegen-output

.PARAMETER PluginRepo
    URL of the securable-opencode-module repo. Defaults to the canonical repo.

.PARAMETER DryRun
    Print the commands that would run without executing OpenCode.

.PARAMETER Resume
    Resume a previous run without wiping existing target directories.
    Useful when token windows or rate limits interrupt generation.

.PARAMETER Modes
        One or more generation modes to run. Supported values:
            rawdog, securable
        Accepts comma-separated values and repeated arguments.
        Defaults to rawdog and securable.

.PARAMETER Clean
    Remove the cached plugin clone and .codegen-finished flags from
    the output directory, then exit.  No generation is performed.
    -PrdFile is not required when -Clean is specified.

.EXAMPLE
    .\run-codegen-opencode.ps1 -PrdFile .\my-prd.md
    .\run-codegen-opencode.ps1 -PrdFile .\my-prd.md -OutputDir D:\tests\opencode -DryRun
    .\run-codegen-opencode.ps1 -PrdFile .\my-prd.md -Resume
    .\run-codegen-opencode.ps1 -OutputDir D:\tests\opencode -Clean
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PrdFile,

    [string]$OutputDir = ".\opencode-codegen-output",

    [string]$PluginRepo = "https://github.com/Xcaciv/securable-opencode-module.git",

    [switch]$DryRun,

    [switch]$Resume,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateCount(1, 32)]
    [string[]]$Modes = @("rawdog", "securable"),

    [Parameter(ParameterSetName = 'Clean')]
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Language definitions
# ---------------------------------------------------------------------------
$Languages = [ordered]@{
    "aspnet" = "ASP.NET Core (C#) Web API / MVC application"
    "jsp"    = "Java web application using JSP (Java Server Pages) and servlets"
    "node"   = "Node.js web application using Express.js"
}

$FinishedFlagFileName = ".codegen-finished"

$ModeDefinitions = [ordered]@{
    "rawdog" = @{
        IsSecurable  = $false
        SummaryLabel = "plain OpenCode generation"
    }
    "securable" = @{
        IsSecurable  = $true
        SummaryLabel = "FIASSE/SSEM secured generation"
    }
}

$SupportedModes = @($ModeDefinitions.Keys)

# ---------------------------------------------------------------------------
# Helper: Coloured status line
# ---------------------------------------------------------------------------
function Write-Step([string]$Message, [string]$Color = "Cyan") {
    Write-Host "`n>>> $Message" -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# Helper: Write text as UTF-8 without BOM (PowerShell 5.1 safe)
#   OpenCode rejects BOM-prefixed JSON/JSONC files.
# ---------------------------------------------------------------------------
function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# ---------------------------------------------------------------------------
# Helper: Verify required tools are present
# ---------------------------------------------------------------------------
function Assert-Tool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' not found on PATH. Please install it and try again."
    }
    Write-Host "  [OK] $Name found: $((Get-Command $Name).Source)" -ForegroundColor DarkGreen
}

# ---------------------------------------------------------------------------
# Helper: Configure OpenCode permissions so it can write to the target
#   directory without interactive prompts.
#
#   Two mechanisms:
#     1. opencode.json alongside AGENTS.md with permission config
#     2. OPENCODE_PERMISSION environment variable (set at invocation time)
#
#   This function writes the opencode.json with edit permissions.
#   The env var is set in Invoke-OpenCode for the process scope.
# ---------------------------------------------------------------------------
function Set-OpenCodePermissions {
    param(
        [string]$TargetDir
    )

    $configPath = Join-Path $TargetDir "opencode.json"

    # If an opencode.json already exists (e.g. from plugin install), merge
    # permissions into it; otherwise create a minimal one.
    if (Test-Path $configPath) {
        $existing = Get-Content $configPath -Raw | ConvertFrom-Json
        # Add permission block
        $existing | Add-Member -NotePropertyName "permission" -NotePropertyValue @{ "edit" = "allow"; "bash" = "allow" } -Force
        Write-Utf8NoBomFile -Path $configPath -Content ($existing | ConvertTo-Json -Depth 10)
    } else {
        $config = @{
            "`$schema"   = "https://opencode.ai/config.json"
            "permission" = @{
                "edit" = "allow"
                "bash" = "allow"
            }
        }
        Write-Utf8NoBomFile -Path $configPath -Content ($config | ConvertTo-Json -Depth 10)
    }
}

# ---------------------------------------------------------------------------
# Helper: Run OpenCode non-interactively in a given directory.
#
#   OpenCode CLI non-interactive invocation:
#     opencode run -f <prompt-file>
#
#   The 'run' subcommand suppresses the interactive TUI. The -f flag
#   attaches the prompt file. The agent writes files directly into the
#   current working directory.
#
#   Write permissions are granted via OPENCODE_PERMISSION env var and
#   via the opencode.json permission config written by
#   Set-OpenCodePermissions.
# ---------------------------------------------------------------------------
function Invoke-OpenCode {
    param(
        [string]$WorkingDir,
        [string]$Prompt,
        [string]$Label
    )

    $logFile = Join-Path $WorkingDir "opencode-output.log"

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would run in: $WorkingDir" -ForegroundColor Yellow
        Write-Host "  [DRY-RUN] Prompt starts: $($Prompt.Substring(0, [Math]::Min(120, $Prompt.Length)))..." -ForegroundColor Yellow
        return
    }

    Write-Step "Running OpenCode for: $Label" "Green"
    Write-Host "  Output dir : $WorkingDir"
    Write-Host "  Log file   : $logFile"

    Push-Location $WorkingDir
    try {
        # Write prompt to a temp file and pass via -f
        $promptFile = Join-Path $env:TEMP "opencode_prompt_$([System.IO.Path]::GetRandomFileName()).txt"
        Write-Host "  Running in $WorkingDir using temp prompt file: $promptFile" -ForegroundColor DarkGray
        try {
            Set-Content -Path $promptFile -Value $Prompt -Encoding UTF8

            # Set permission env var for the process so OpenCode does not prompt
            $env:OPENCODE_PERMISSION = '{"edit": "allow", "bash": "allow"}'

            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & cmd /c "opencode run < $promptFile" |
                    Tee-Object -FilePath $logFile
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
                # Clean up the env var
                Remove-Item Env:\OPENCODE_PERMISSION -ErrorAction SilentlyContinue
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "opencode run exited with code $LASTEXITCODE for $Label - check $logFile"
            }
        }
        finally {
            if (Test-Path $promptFile) { Remove-Item -Force $promptFile }
        }
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Helper: Install the securable-opencode-module into a target directory.
#
#   The module is copied into .securable/ in the target directory, and an
#   opencode.json is written at the target root to configure permissions.
#
#   Module layout:
#     .securable/config.json
#     .securable/tools/
#     .securable/workflows/
#     .securable/scripts/
# ---------------------------------------------------------------------------
function Install-SecurableModule {
    param(
        [string]$PluginSource,   # path to the cloned module repo
        [string]$TargetDir       # project directory to install into
    )

    $dstSecurable = Join-Path $TargetDir ".securable"

    # Copy the module contents into .securable/
    $assetDirs = @("tools", "data", "templates")
    $assetFiles = @("config.json", "instructions.md")

    New-Item -ItemType Directory -Force -Path $dstSecurable | Out-Null

    foreach ($dir in $assetDirs) {
        $srcPath = Join-Path $PluginSource $dir
        $dstPath = Join-Path $dstSecurable $dir
        if (Test-Path $srcPath) {
            Copy-Item -Recurse -Force $srcPath $dstPath
            Write-Host "  Installed $dir/ -> $dstPath" -ForegroundColor DarkGray
        }
    }

    foreach ($file in $assetFiles) {
        $srcPath = Join-Path $PluginSource $file
        $dstPath = Join-Path $dstSecurable $file
        if (Test-Path $srcPath) {
            Copy-Item -Force $srcPath $dstPath
            Write-Host "  Installed $file -> $dstPath" -ForegroundColor DarkGray
        }
    }

    # Write opencode.json at the target root:
    #   - registers the MCP server so OpenCode discovers the securability tools
    #   - grants write and shell permissions for generation
    $opencodeConfig = @{
        "`$schema"  = "https://opencode.ai/config.json"
        "mcp"       = @{
            "securable" = @{
                "type"        = "local"
                "command"     = @("node", "./.securable/tools/mcp_server.js")
                "environment" = @{
                    "SECURABLE_DATA_DIR"      = "./.securable/data"
                    "SECURABLE_TEMPLATES_DIR" = "./.securable/templates"
                }
            }
        }
        "permission" = @{
            "edit" = "allow"
            "bash" = "allow"
        }
    }

    if (Test-Path (Join-Path $dstSecurable "instructions.md")) {
        $opencodeConfig["instructions"] = @("./.securable/instructions.md")
    }

    $configPath = Join-Path $TargetDir "opencode.json"
    Write-Utf8NoBomFile -Path $configPath -Content ($opencodeConfig | ConvertTo-Json -Depth 10)
    Write-Host "  Wrote opencode.json -> $configPath" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Helper: Read securable instructions from the module for prompt embedding.
#
#   Primary source: instructions.md (system instructions)
#   The MCP tools (securability_review, secure_generate, fiasse_lookup)
#   are available at runtime via the MCP server, but we embed the
#   instructions directly in the prompt to ensure they are applied
#   even if the MCP server is not fully initialized.
# ---------------------------------------------------------------------------
function Get-SecurableInstructions([string]$PluginSource) {
    $parts = [System.Collections.Generic.List[string]]::new()

    $instrFile = Join-Path $PluginSource "instructions.md"
    if (Test-Path $instrFile) {
        $parts.Add((Get-Content $instrFile -Raw))
    }

    if ($parts.Count -gt 0) {
        return $parts -join "`n`n"
    }

    # Fallback if module files not found
    return @(
        "Apply FIASSE/SSEM securability engineering principles as hard constraints.",
        "Satisfy all nine SSEM attributes:",
        "  Maintainability: Analyzability, Modifiability, Testability",
        "  Trustworthiness: Confidentiality, Accountability, Authenticity",
        "  Reliability:     Availability, Integrity, Resilience",
        "Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all",
        "trust boundaries. Enforce the Derived Integrity Principle for business-critical",
        "values. Produce structured audit logging for all accountable actions."
    ) -join "`n"
}

# ===========================================================================
# MAIN
# ===========================================================================

$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

# ---------------------------------------------------------------------------
# -Clean: remove cached module clone and finished flags, then exit
# ---------------------------------------------------------------------------
if ($Clean) {
    Write-Step "Cleaning cache files from $OutputDir" "Magenta"

    $PluginTemp = Join-Path $OutputDir "_securable_opencode_temp"
    if (Test-Path $PluginTemp) {
        Write-Host "  Removing module cache: $PluginTemp" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $PluginTemp
    } else {
        Write-Host "  Module cache not found (already clean)" -ForegroundColor DarkGray
    }

    $flagsRemoved = 0
    if (Test-Path $OutputDir) {
        Get-ChildItem -Path $OutputDir -Filter $FinishedFlagFileName -Recurse -Force | ForEach-Object {
            Write-Host "  Removing finished flag: $($_.FullName)" -ForegroundColor Yellow
            Remove-Item -Force $_.FullName
            $flagsRemoved++
        }
    }
    Write-Host "  Removed $flagsRemoved finished flag(s)." -ForegroundColor DarkGray

    Write-Step "Clean complete." "Magenta"
    return
}

$NormalizedModes = [System.Collections.Generic.List[string]]::new()
foreach ($modeArg in $Modes) {
    foreach ($candidate in ($modeArg -split ",")) {
        $normalized = $candidate.Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $NormalizedModes.Add($normalized)
        }
    }
}

$Modes = @($NormalizedModes | Select-Object -Unique)
if ($Modes.Count -eq 0) {
    throw "At least one mode must be provided via -Modes. Available modes: $($SupportedModes -join ', ')"
}

$InvalidModes = @($Modes | Where-Object { $_ -notin $SupportedModes })
if ($InvalidModes.Count -gt 0) {
    throw "Unsupported mode(s): $($InvalidModes -join ', '). Available modes: $($SupportedModes -join ', ')"
}

$PrdFile = Resolve-Path $PrdFile | Select-Object -ExpandProperty Path

Write-Step "Starting OpenCode codegen run" "Magenta"
Write-Host "  PRD file   : $PrdFile"
Write-Host "  Output dir : $OutputDir"
Write-Host "  Dry run    : $DryRun"
Write-Host "  Resume     : $Resume"
Write-Host "  Modes      : $($Modes -join ', ')"

# ---------------------------------------------------------------------------
# Prerequisite check
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites ..."
if (-not $DryRun) {
    Assert-Tool "opencode"
    Assert-Tool "git"
    Assert-Tool "node"
} else {
    Write-Host "  [DRY-RUN] Skipping tool checks" -ForegroundColor Yellow
}

# Read PRD
$PrdContent = Get-Content $PrdFile -Raw

# Create root output dir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ---------------------------------------------------------------------------
# Step 1: Clone the module once
# ---------------------------------------------------------------------------
$PluginTemp = Join-Path $OutputDir "_securable_opencode_temp"

if (Test-Path $PluginTemp) {
    Write-Step "Module already cloned at $PluginTemp - updating" "Yellow"
    if ($DryRun) {
        Write-Host "  [DRY-RUN] git -C $PluginTemp pull --ff-only" -ForegroundColor Yellow
    } else {
        if (-not (Test-Path (Join-Path $PluginTemp ".git"))) {
            throw "Existing module cache is not a git repository: $PluginTemp. Run -Clean and retry."
        }
        git -C $PluginTemp pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw "git update failed for module cache at $PluginTemp" }
    }
} else {
    Write-Step "Cloning securable-opencode-module ..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] git clone $PluginRepo $PluginTemp" -ForegroundColor Yellow
        # Stub structure for dry-run
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "tools") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "data\fiasse") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "data\asvs") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "templates") | Out-Null
        Set-Content (Join-Path $PluginTemp "config.json") "{}"
        Set-Content (Join-Path $PluginTemp "instructions.md") "# securable-opencode-module stub (dry-run)"
        Set-Content (Join-Path $PluginTemp "tools\prd_securability_enhance.js") "// dry-run stub"
        Set-Content (Join-Path $PluginTemp "tools\mcp_server.js") "// dry-run stub"
        Set-Content (Join-Path $PluginTemp "opencode.json") "{}"
    } else {
        git clone $PluginRepo $PluginTemp
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
}

$SecurableInstructions = Get-SecurableInstructions $PluginTemp

# ---------------------------------------------------------------------------
# Step 2: Loop over languages x modes
# ---------------------------------------------------------------------------
foreach ($langKey in $Languages.Keys) {
    $langLabel = $Languages[$langKey]

    foreach ($mode in $Modes) {
        $modeConfig = $ModeDefinitions[$mode]

        $targetDir = Join-Path $OutputDir "$langKey\$mode"
        $finishedFlagPath = Join-Path $targetDir $FinishedFlagFileName

        if ($Resume -and (Test-Path $finishedFlagPath)) {
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would skip completed variation: $targetDir" -ForegroundColor Yellow
            } else {
                Write-Host "  Skipping completed variation: $targetDir" -ForegroundColor DarkGreen
            }
            continue
        }

        # By default, wipe prior output so generation starts from a clean slate.
        # In -Resume mode, preserve existing content to continue interrupted runs.
        if (Test-Path $targetDir) {
            if ($Resume) {
                if ($DryRun) {
                    Write-Host "  [DRY-RUN] Would keep existing (resume mode): $targetDir" -ForegroundColor Yellow
                } else {
                    Write-Host "  Resume mode: keeping existing directory: $targetDir" -ForegroundColor DarkGray
                }
            } else {
                if ($DryRun) {
                    Write-Host "  [DRY-RUN] Would wipe existing: $targetDir" -ForegroundColor Yellow
                } else {
                    Write-Host "  Cleaning previous run: $targetDir" -ForegroundColor DarkGray
                    Remove-Item -Recurse -Force $targetDir
                }
            }
        }
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

        # Isolation: place a minimal AGENTS.md in rawdog directories as a context
        # fence. OpenCode uses AGENTS.md as the project context file, so placing
        # one here prevents it from walking up the directory tree and loading
        # module files from parent directories.
        if (-not $modeConfig.IsSecurable) {
            $fenceContent = @(
                "# codegen-test: rawdog baseline",
                "# This file exists only to prevent context from parent directories",
                "# being loaded into this isolated test run.  Do not add instructions here."
            ) -join "`n"
            Set-Content (Join-Path $targetDir "AGENTS.md") $fenceContent
        }

        # ---- Build the prompt ----
        $effectivePrdContent = $PrdContent
        if (-not $modeConfig.IsSecurable) {
            $prompt = @(
                "Generate a complete, working $langLabel project based on the following PRD.",
                "",
                "Create all necessary source files, configuration files, and folder structure",
                "inside the current working directory.",
                "",
                "Include a README.md with setup and run instructions.",
                "When the project is fully complete, create a file named $FinishedFlagFileName in the",
                "current working directory. Only create this file after all required project files are done.",
                "",
                "PRD:",
                "---",
                $effectivePrdContent,
                "---"
            ) -join "`n"
        } else {
            # Install module files first so OpenCode auto-loads the MCP server
            Install-SecurableModule -PluginSource $PluginTemp -TargetDir $targetDir

            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would dispatch securable command: secure-generate" -ForegroundColor Yellow
            } else {
                Write-Host "  Dispatching securable command: secure-generate" -ForegroundColor DarkGray
            }

            $prompt = @(
                "You are operating with the securable-opencode-module active (.securable/ directory",
                "and opencode.json are present in this directory). The module tools and workflows are available,",
                "including fiasse_lookup, securability_review, secure_generate, and prd_securability_enhance.",
                "Execute secure-generate and use it as the authoritative generation workflow.",
                "",
                "The following securability engineering instructions are your primary",
                "constraints - treat them as non-negotiable design requirements.",
                "",
                "=== SECURABLE-OPENCODE-MODULE INSTRUCTIONS ===",
                $SecurableInstructions,
                "=== END MODULE INSTRUCTIONS ===",
                "",
                "Now generate a complete, working $langLabel project based on the following PRD,",
                "applying every FIASSE/SSEM constraint above throughout all generated code.",
                "",
                "Create all necessary source files, configuration files, and folder structure",
                "inside the current working directory.",
                "",
                "Include a README.md with:",
                "  - Setup and run instructions",
                "  - A brief SSEM attribute coverage summary describing how each of the nine",
                "    attributes is addressed in the generated code",
                "When the project is fully complete, create a file named $FinishedFlagFileName in the",
                "current working directory. Only create this file after all required project files are done.",
                "",
                "PRD:",
                "---",
                $effectivePrdContent,
                "---"
            ) -join "`n"
        }

        $label = "$langKey / $mode"

        # Ensure OpenCode has write permissions (skip in dry-run)
        if (-not $DryRun) {
            Set-OpenCodePermissions -TargetDir $targetDir
        }

        Invoke-OpenCode -WorkingDir $targetDir -Prompt $prompt -Label $label
    }
}

# ---------------------------------------------------------------------------
# Step 3: Summary
# ---------------------------------------------------------------------------
Write-Step "All done!" "Magenta"
Write-Host ""
Write-Host "Generated folder structure:" -ForegroundColor White
foreach ($langKey in $Languages.Keys) {
    Write-Host "  $OutputDir\" -NoNewline -ForegroundColor Gray
    Write-Host "$langKey\" -ForegroundColor Cyan
    foreach ($mode in $Modes) {
        Write-Host "    $mode\  - $($ModeDefinitions[$mode].SummaryLabel)" -ForegroundColor Gray
    }
}
Write-Host ""
Write-Host "Each folder contains an opencode-output.log with the full CLI response." -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host "`n[DRY-RUN MODE] No OpenCode calls were made." -ForegroundColor Yellow
    Write-Host "Remove -DryRun to execute for real." -ForegroundColor Yellow
}
