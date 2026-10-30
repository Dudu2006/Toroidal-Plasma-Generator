<#
.SYNOPSIS
    Sets up the project's Python environment on Windows.

.DESCRIPTION
    1. Lets PowerShell run local scripts (needed for venv activation).
    2. Installs the requested Python with the Python install manager (`py install`) if it's missing.
    3. Creates .venv with that exact Python, recreating it if it uses a different version.
    4. Activates .venv and pip-installs requirements.txt, or the default packages if there's none.
    5. Writes .vscode\settings.json, keeping any other settings already in it.

.EXAMPLE
    . .\setup.ps1
    Dot-source it (note the leading ". ") so .venv stays active in your terminal afterwards.

.EXAMPLE
    .\setup.ps1 -PythonVersion 3.15.2 -Packages streamlit,numpy,scipy,pint
#>
param(
    [string]   $PythonVersion = "3.15.2",
    [string[]] $Packages      = @("streamlit", "numpy", "scipy")
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$VenvDir     = Join-Path $ProjectRoot ".venv"
$VenvPython  = Join-Path $VenvDir "Scripts\python.exe"

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Fail($text) { Write-Host "`nERROR: $text" -ForegroundColor Red; throw $text }

function Get-PythonVersion($exe) {
    # Returns e.g. "3.15.2", or $null if the executable can't run.
    try {
        $v = & $exe -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
        if ($LASTEXITCODE -eq 0) { return "$v".Trim() }
    } catch { }
    return $null
}

# --- 1. Execution policy -----------------------------------------------------
Step "Allowing local scripts to run (execution policy: RemoteSigned, current user)"
try {
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
    Write-Host "Execution policy for your user is now: $(Get-ExecutionPolicy -Scope CurrentUser)"
} catch {
    Write-Warning "Couldn't change the execution policy: $($_.Exception.Message)"
    Write-Warning "A group policy may be overriding it. Activation may need: powershell -ExecutionPolicy Bypass"
}

# --- 2. Python install manager and the requested version ---------------------
Step "Looking for Python $PythonVersion"
if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
    Fail "The 'py' command wasn't found. Install the Python install manager from https://www.python.org/downloads/ and run this script again."
}

# 'py list' only exists in the new install manager, not the old 'py' launcher.
& py list *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "Your 'py' is the older launcher, which can't install Python. Install the Python install manager from https://www.python.org/downloads/ and run this script again."
}

function Find-Python($version) {
    $paths = & py list --one -f=exe $version 2>$null
    foreach ($p in @($paths)) {
        $p = "$p".Trim()
        if ($p -and (Test-Path $p) -and ((Get-PythonVersion $p) -eq $version)) { return $p }
    }
    return $null
}

$PythonExe = Find-Python $PythonVersion
if (-not $PythonExe) {
    Write-Host "Python $PythonVersion isn't installed. Installing it with 'py install $PythonVersion'..."
    & py install $PythonVersion
    if ($LASTEXITCODE -ne 0) {
        Fail "'py install $PythonVersion' failed. Check the version exists with: py list --online $PythonVersion"
    }
    $PythonExe = Find-Python $PythonVersion
    if (-not $PythonExe) { Fail "Python $PythonVersion was installed but couldn't be located. Run 'py list' to check." }
}
Write-Host "Using $PythonExe"

# --- 3. Virtual environment --------------------------------------------------
Step "Preparing .venv"
if (Test-Path $VenvDir) {
    $existing = if (Test-Path $VenvPython) { Get-PythonVersion $VenvPython } else { $null }
    if ($existing -eq $PythonVersion) {
        Write-Host ".venv already uses Python $PythonVersion; keeping it."
    } else {
        $label = if ($existing) { "Python $existing" } else { "a broken or unknown Python" }
        Write-Host ".venv uses $label. Recreating it with $PythonVersion..."
        if ($env:VIRTUAL_ENV -and (Get-Command deactivate -ErrorAction SilentlyContinue)) { deactivate }
        try {
            Remove-Item -Recurse -Force $VenvDir
        } catch {
            Fail ("Couldn't delete .venv because a file in it is in use. Stop Streamlit, close notebook kernels " +
                  "and other terminals using it, then run this again. ($($_.Exception.Message))")
        }
    }
}

if (-not (Test-Path $VenvPython)) {
    & $PythonExe -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { Fail "Creating .venv failed." }
    Write-Host "Created .venv with Python $PythonVersion."
}

# --- 4. Activate and install packages ----------------------------------------
Step "Activating .venv and installing packages"
. (Join-Path $VenvDir "Scripts\Activate.ps1")

python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { Fail "Upgrading pip failed." }

$Requirements = Join-Path $ProjectRoot "requirements.txt"
if (Test-Path $Requirements) {
    Write-Host "Installing from requirements.txt"
    python -m pip install -r $Requirements
} else {
    Write-Host "No requirements.txt found. Installing: $($Packages -join ', ')"
    python -m pip install @Packages
}
if ($LASTEXITCODE -ne 0) { Fail "Package installation failed. See the pip output above." }

# --- 5. VS Code settings -----------------------------------------------------
Step "Writing .vscode\settings.json"
$VsCodeDir    = Join-Path $ProjectRoot ".vscode"
$SettingsPath = Join-Path $VsCodeDir "settings.json"
New-Item -ItemType Directory -Force -Path $VsCodeDir | Out-Null

# Single quotes keep ${workspaceFolder} literal for VS Code to expand.
$wanted = [ordered]@{
    "python.defaultInterpreterPath"       = '${workspaceFolder}\.venv\Scripts\python.exe'
    "python.terminal.activateEnvironment" = $true
    "python.languageServer"               = "Pylance"
}

$settings = [ordered]@{}
if (Test-Path $SettingsPath) {
    try {
        $current = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        foreach ($prop in $current.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
        Write-Host "Merging into your existing settings."
    } catch {
        # VS Code allows comments in settings.json, which ConvertFrom-Json can't read.
        $backup = "$SettingsPath.bak"
        Copy-Item $SettingsPath $backup -Force
        Write-Warning "Couldn't read the existing settings.json (it may contain comments). Saved a copy as settings.json.bak."
    }
}
foreach ($key in $wanted.Keys) { $settings[$key] = $wanted[$key] }

$json = $settings | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))

# --- Done ---------------------------------------------------------------------
Step "Done"
Write-Host "Python: $(python --version)  ($((Get-Command python).Source))"
Write-Host "Next: in VS Code, open a new terminal; .venv activates automatically."
if ($MyInvocation.InvocationName -ne ".") {
    Write-Host "This terminal isn't activated, because the script wasn't dot-sourced. Run: .venv\Scripts\activate"
}
