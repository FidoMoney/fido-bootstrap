#Requires -Version 5.1
<#
  Fido installer bootstrap (Windows / PowerShell)
  -----------------------------------------------
  Stage 1 of 2, and deliberately boring. This file is PUBLIC: all it does is
  install the GitHub CLI, sign you in, then fetch the real Fido installer from
  the private FidoMoney/fido-installer repo and run it.

  Run it with:
    iex (irm https://raw.githubusercontent.com/FidoMoney/fido-bootstrap/main/bootstrap.ps1)

  Your GitHub account being a member of the FidoMoney org IS the access
  control. Non-members get a 404 on the installer fetch and nothing else -
  none of the installer's contents are public.

  Environment:
    FIDO_INSTALLER_REF=<ref>   git ref of fido-installer to fetch (default: main)

  Any arguments you pass are handed to the installer verbatim, so this works:
    powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Profile expert

  Notes:
    - This file is ASCII-only on purpose. Windows PowerShell 5.1 decodes
      BOM-less files using the console codepage, so a stray non-ASCII byte
      shows up as mojibake on someone else's machine. Use "->", not arrows.
    - Re-runnable: run the same one-liner again whenever you want an update.
    - Never pipe this into PowerShell from an untrusted source.
#>

$ErrorActionPreference = 'Stop'

$INSTALLER_REPO   = 'FidoMoney/fido-installer'
$INSTALLER_FILE   = 'install.ps1'
$ORG_GATE_MESSAGE = "Your GitHub account isn't in the FidoMoney org yet - ask in #eng-platform for an invite, then re-run this command."

# --- Helpers --------------------------------------------------
function Write-Info    { param([string]$m) Write-Host "i  $m" -ForegroundColor Cyan }
function Write-OK      { param([string]$m) Write-Host "OK $m" -ForegroundColor Green }
function Write-Warn2   { param([string]$m) Write-Host "!  $m" -ForegroundColor Yellow }
function Write-Fail    { param([string]$m) Write-Host "X  $m" -ForegroundColor Red }

# `iex (irm ...)` runs this script inside the host PowerShell process, so a
# bare top-level `exit N` slams the host window shut and the user sees the
# console vanish with no error. Stop-Script exits normally when we were run
# from a file, and otherwise throws a tagged exception that the trap below
# unwinds to the user's prompt.
$script:RunningFromFile = [string]::IsNullOrEmpty($MyInvocation.MyCommand.Path) -eq $false

function Stop-Script { param([int]$Code = 0)
    if ($script:RunningFromFile) { exit $Code }
    throw ([System.Management.Automation.RuntimeException]::new("__FIDO_BOOTSTRAP_HALT__:$Code"))
}

trap [System.Management.Automation.RuntimeException] {
    if ($_.Exception.Message -match '^__FIDO_BOOTSTRAP_HALT__:(-?\d+)$') {
        $rc = [int]$Matches[1]
        if ($script:RunningFromFile) { exit $rc }
        return
    }
}

function Has-Cmd { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# winget updates the *stored* PATH, not this process's copy, so re-read it
# before looking for a freshly installed tool.
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('Path','User')
}

function Get-GhExe {
    $c = Get-Command 'gh' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Print-Banner {
    $pink = "$([char]27)[38;2;214;8;107m"
    $rst  = "$([char]27)[0m"
    Write-Host ""
    Write-Host "${pink}  Fido installer bootstrap${rst}"
    Write-Host "  by platform team" -ForegroundColor DarkGray
    Write-Host ""
}

# Byte-faithful download of one file from a private repo.
#
# install.ps1 ships as UTF-8 *with* a BOM because Windows PowerShell 5.1 needs
# that BOM to decode it correctly, so gh's bytes have to reach disk untouched.
# That rules out `| Out-File` and `| Set-Content` (both re-encode, and can end
# up writing a second BOM), and `cmd /c "gh api ... > file"` is worse than it
# looks: the -H "Accept: ..." argument would have to survive PowerShell's
# quoting and then cmd's. Redirecting the child's stdout stream straight into
# a FileStream sidesteps both problems.
function Get-GhRawFile {
    param(
        [Parameter(Mandatory)] [string]$GhExe,
        [Parameter(Mandatory)] [string]$ApiPath,
        [Parameter(Mandatory)] [string]$Dest
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $GhExe
    $psi.Arguments = 'api -H "Accept: application/vnd.github.raw" "' + $ApiPath + '"'
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = $null
    $fs   = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $fs   = [System.IO.File]::Create($Dest)
        $proc.StandardOutput.BaseStream.CopyTo($fs)
        $fs.Close()
        $fs = $null
        # Safe to read stderr only after draining stdout: gh either streams the
        # file and says nothing, or fails immediately with a one-line error, so
        # neither pipe can fill up while we are busy with the other one.
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return @{ ExitCode = $proc.ExitCode; StdErr = $err }
    } catch {
        return @{ ExitCode = -1; StdErr = "$_" }
    } finally {
        if ($fs)   { $fs.Close() }
        if ($proc) { $proc.Dispose() }
    }
}

# --- 1. GitHub CLI --------------------------------------------
Print-Banner
Write-Info "This will install the GitHub CLI (if you don't have it) -> sign you in to"
Write-Info "GitHub -> download the Fido installer -> run it."
Write-Host ""

$gh = Get-GhExe
if ($gh) {
    Write-OK "GitHub CLI is installed"
} else {
    if (-not (Has-Cmd 'winget')) {
        Write-Fail "winget is needed to install the GitHub CLI, and it isn't available here."
        Write-Host ""
        Write-Info "winget ships with App Installer on Windows 10 1709+ and Windows 11:"
        Write-Info "  1) Install 'App Installer' from the Microsoft Store:"
        Write-Info "     https://apps.microsoft.com/detail/9NBLGGH4NNS1"
        Write-Info "  2) Store disabled on a managed laptop? Grab the latest .msixbundle from"
        Write-Info "     https://github.com/microsoft/winget-cli/releases/latest"
        Write-Info "     then run:  Add-AppxPackage <downloaded.msixbundle>"
        Write-Info "  3) Or ask #eng-platform on Slack - IT can install it remotely."
        Write-Host ""
        Write-Info "Once winget works, re-run this command."
        Stop-Script 1
    }

    Write-Info "Installing the GitHub CLI..."
    try {
        winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements | Out-Null
    } catch {
        Write-Fail "winget couldn't install the GitHub CLI: $_"
        Stop-Script 1
    }
    # winget reports failure through its exit code rather than an exception, so
    # check the code and then confirm the tool is actually usable.
    $code = $LASTEXITCODE
    Refresh-Path
    $gh = Get-GhExe
    if (-not $gh) {
        Write-Fail "The GitHub CLI still isn't on PATH (winget exit $code)."
        Write-Host ""
        Write-Info "Open a new PowerShell window and re-run this command, or install it by hand:"
        Write-Info "  winget install --id GitHub.cli -e"
        Stop-Script 1
    }
    Write-OK "GitHub CLI installed"
}

& $gh --version *> $null
if ($LASTEXITCODE -ne 0) { Write-Warn2 "'gh --version' didn't run cleanly - carrying on anyway." }

# --- 2. GitHub sign-in ----------------------------------------
& $gh auth status -h github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Info "You need to sign in to GitHub. A browser window will open."
    Write-Info "Choose HTTPS if you're asked how to authenticate."
    Write-Host ""
    & $gh auth login -h github.com -p https -w
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "GitHub sign-in didn't finish."
        Write-Info "Sign in with 'gh auth login -h github.com -p https -w', then re-run this command."
        Stop-Script 1
    }
}
# Cosmetic only, so don't let it take the run down: a native command writing to
# stderr can surface as a terminating error while $ErrorActionPreference is Stop.
$who = 'unknown'
try {
    $login = (& $gh api user --jq '.login' 2>$null)
    if ($login) { $who = "$login".Trim() }
} catch { }
Write-OK "Signed in to GitHub as $who"

# --- 3. Fetch the installer -----------------------------------
$ref = 'main'
if ($env:FIDO_INSTALLER_REF) { $ref = $env:FIDO_INSTALLER_REF }

$tmpRoot = $env:TEMP
if (-not $tmpRoot) { $tmpRoot = [System.IO.Path]::GetTempPath() }
# Per-run scratch dir: the installer reads companion files (expert-repos.txt)
# from the directory it runs in, so a fixed path under %TEMP% could silently
# pick up stale copies from earlier downloads. A fresh GUID dir cannot.
$runDir = Join-Path $tmpRoot ("fido-bootstrap-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$dest = Join-Path $runDir 'fido-install.ps1'

try {
    Write-Host ""
    Write-Info "Fetching $INSTALLER_FILE from $INSTALLER_REPO (ref: $ref)..."
    $apiPath = "repos/$INSTALLER_REPO/contents/$INSTALLER_FILE" + "?ref=$ref"
    $fetch = Get-GhRawFile -GhExe $gh -ApiPath $apiPath -Dest $dest

    if ($fetch.ExitCode -ne 0) {
        Write-Host ""
        if ($fetch.StdErr -match '(40[34])|Not Found|Forbidden') {
            Write-Fail $ORG_GATE_MESSAGE
            if ($ref -ne 'main') {
                Write-Info "Note: FIDO_INSTALLER_REF is set to '$ref' - a ref that doesn't exist in $INSTALLER_REPO shows this same error."
            }
        } else {
            Write-Fail "Couldn't download the Fido installer from $INSTALLER_REPO."
            Write-Info "Check your network (VPN or proxy on this machine?) and try again."
            if ($fetch.StdErr) { Write-Info "gh said: $($fetch.StdErr.Trim())" }
        }
        Stop-Script 1
    }

    $size = 0
    if (Test-Path -LiteralPath $dest) { $size = (Get-Item -LiteralPath $dest).Length }
    if ($size -eq 0) {
        Write-Fail "The downloaded installer is empty - refusing to run it."
        Write-Info "Try again in a minute; if it keeps happening, ask in #eng-platform."
        Stop-Script 1
    }
    Write-OK "Downloaded $INSTALLER_FILE ($size bytes)"

    # --- 4. Hand over -----------------------------------------
    # Always powershell.exe: the installer targets Windows PowerShell 5.1, and
    # running it as a child process keeps its own `exit` handling intact.
    $forward = @()
    if ($args) { $forward = @($args) }

    Write-Host ""
    Write-Info "Starting the Fido installer..."
    Write-Host ""
    if ($forward.Count -gt 0) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dest @forward
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dest
    }
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
    Stop-Script $rc
} finally {
    Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
}
