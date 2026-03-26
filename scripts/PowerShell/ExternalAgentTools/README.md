# ExternalAgentTools

`ExternalAgentTools` is a lightweight PowerShell module that provides a robust wrapper for executing external binaries (CLI tools, agents, compilers, etc.) while:

- streaming **stdout** and **stderr** live to the console  
- writing **timestamped logs** to disk  
- supporting **string or array arguments**  
- avoiding PowerShell’s stream‑merging quirks  
- working reliably with tools like OpenCode, Copilot CLI, and other agent‑style binaries  

---

## Features

### ✔ Live console output  
Stdout and stderr are displayed immediately, unmodified.

### ✔ Timestamped logs  
Log files include timestamps for every line:

```
2026-03-25 21:37:12 <line>
```

### ✔ Flexible argument handling  
Arguments can be passed as a single string or an array.

### ✔ No PowerShell stream interference  
Uses the .NET `Process` API for maximum compatibility.

---

## Installation

Place the module folder anywhere in your `$env:PSModulePath`, or import it directly:

```powershell
Import-Module "C:\Path\To\ExternalAgentTools\ExternalAgentTools.psm1"
```

---

## Usage

### Basic example

```powershell
Invoke-ExternalAgent -Command "opencode.exe" -ArgumentList "< prompt.txt"
```

### Array arguments

```powershell
Invoke-ExternalAgent -Command "mytool.exe" -ArgumentList @("--flag", "value", "--verbose")
```

### Custom log paths

```powershell
Invoke-ExternalAgent `
    -Command "opencode.exe" `
    -ArgumentList "< prompt.txt" `
    -StdOutLog "logs/out.log" `
    -StdErrLog "logs/err.log"
```

---

## Return Value

The function returns the external process’s exit code.

## ALSO

In any script that needs the function:

```powershell
Import-Module "C:\Path\To\ExternalAgentTools\ExternalAgentTools.psm1"
```

Or if you install it into your `$env:PSModulePath`:

```powershell
Import-Module ExternalAgentTools
```

Then call it:

```powershell
Invoke-ExternalAgent -Command "opencode.exe" -ArgumentList "< prompt.txt"
```