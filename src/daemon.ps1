# daemon.ps1 -- agent-caffeine sleep-inhibit daemon (logon-triggered)
#
# Design:
#   - A resident process launched once at user logon via Task Scheduler.
#     Because it runs under the logon session, it is bound to the interactive
#     desktop (WinSta0\Default) and SendKeys / Cursor.Position DO reset the
#     Windows IdleTimer. When spawned via Git Bash `nohup powershell &` the
#     process loses that binding and SendKeys silent-fails -- that was the
#     root cause of the previous "running but ineffective" state.
#   - Polls the holders directory every 60 seconds. Injects fake activity
#     only while at least one holder file exists. The agent-caffeine CLI
#     only creates/deletes holder files; it no longer spawns any process.
#     This separation means an agent-caffeine bug or crash cannot leak a
#     process.
#   - Interval = 60s. Sleep timeouts on this PC are AC=300s / DC=180s, so
#     60s gives 3x margin against the tightest (DC) threshold. The old 240s
#     was longer than DC 180s and let the machine sleep.
#
# Triple defense (documented per line inside the loop):
#   1) SetThreadExecutionState(0x80000003) -- effective on non-GPO-managed hosts
#   2) SendKeys('{F15}') -- F15 is a virtual key with no visible effect
#   3) 1px mouse nudge (then restore) -- pointer activity is another signal
#
# Env vars:
#   AGENT_CAFFEINE_STATE        state dir (default: $env:USERPROFILE\.local\state\agent-caffeine)
#   AGENT_CAFFEINE_INTERVAL_SEC injection interval seconds (default: 60)
#   AGENT_CAFFEINE_LOG          log file (default: $stateDir\daemon.log)
#   AGENT_CAFFEINE_WATCH_VSCODE opt-in: '1'/'true' auto-holds a 'vscode-alive'
#                               holder while any VSCode process is running.
#                               Default OFF.
#                               Purpose: when running Claude Code on EC2 via
#                               VSCode Remote SSH, the Windows-side hook does
#                               not fire and the machine sleeps after DC 180s.
#                               Treat VSCode being open as "user is working on
#                               this PC" and inhibit sleep. Detecting Remote
#                               SSH via TCP or host allowlists was judged
#                               overkill; VSCode process liveness is a cheap
#                               proxy that also covers the "stepped away
#                               during a permission prompt" case.
#                               Side effect: leaving VSCode open with no work
#                               keeps inhibit alive (harm is battery drain
#                               only, accepted).

$ErrorActionPreference = 'Continue'

$stateDir = if ($env:AGENT_CAFFEINE_STATE) { $env:AGENT_CAFFEINE_STATE } else { Join-Path $env:USERPROFILE '.local\state\agent-caffeine' }
$holdersDir = Join-Path $stateDir 'holders'
$intervalSec = if ($env:AGENT_CAFFEINE_INTERVAL_SEC) { [int]$env:AGENT_CAFFEINE_INTERVAL_SEC } else { 20 }
$logFile = if ($env:AGENT_CAFFEINE_LOG) { $env:AGENT_CAFFEINE_LOG } else { Join-Path $stateDir 'daemon.log' }
$pidFile = Join-Path $stateDir 'daemon.pid'
$heartbeatFile = Join-Path $stateDir 'daemon.heartbeat'

# Auto-hold holder name defined in one place. Future auto-hold sources such
# as 'remote-ssh-alive' should be listed alongside here so that magic strings
# do not scatter across the file.
$VSCodeHolderName = 'vscode-alive'

New-Item -ItemType Directory -Force -Path $holdersDir | Out-Null

# Guard against multiple daemons.
# NOTE: Just checking (Get-Process -Id $oldPid) is unsafe -- Windows recycles PIDs,
# and if the old PID has been reassigned to some unrelated powershell.exe (or any
# process), we would falsely exit while no daemon is actually running.
# Verify the old process is really a powershell running our script.
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue | Out-String).Trim()
    if ($oldPid -match '^\d+$') {
        $oldProc = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue
        if ($oldProc -and $oldProc.Name -match '^(powershell|pwsh)\.exe$' -and $oldProc.CommandLine -match 'daemon\.ps1') {
            "[$(Get-Date -Format s)] daemon already running (pid=$oldPid), exiting" | Out-File -Append $logFile
            exit 0
        }
    }
}
"$PID" | Out-File -FilePath $pidFile -Encoding ascii -NoNewline

Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint s);
'@
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Write-Log($msg) {
    "[$(Get-Date -Format s)] $msg" | Out-File -Append $logFile -Encoding utf8
}

function Get-HolderCount {
    (Get-ChildItem -File -Path $holdersDir -ErrorAction SilentlyContinue | Measure-Object).Count
}

# Loose match for the opt-in flag. '1' or 'true' (case variants) count as
# enabled; unset / '0' / empty count as disabled. Kept as one function so the
# flag name or accepted true-values can be changed in a single place.
function Test-WatchVSCodeEnabled {
    $v = $env:AGENT_CAFFEINE_WATCH_VSCODE
    if (-not $v) { return $false }
    return ($v -in @('1', 'true', 'TRUE', 'True'))
}

# VSCode process liveness. No distinction between stable / Insiders / Cursor
# for the initial version -- if any parent Code.exe is alive we return true.
# Get-Process throws when the target name has no matches, so
# -ErrorAction SilentlyContinue is required.
function Test-VSCodeAlive {
    $procs = Get-Process -Name Code -ErrorAction SilentlyContinue
    return [bool]$procs
}

# Reflect VSCode liveness into holders/. Idempotent: when enabled and alive,
# touch the fixed-name holder every iteration; when enabled and gone, delete
# it. When disabled, remove the fixed-name holder if it happens to exist
# (leaked from a previous enabled run); other holders are never touched,
# so flipping opt-in off never disturbs unrelated CLI-acquired holders.
function Update-VSCodeHolder {
    $holderPath = Join-Path $holdersDir $VSCodeHolderName
    if (-not (Test-WatchVSCodeEnabled)) {
        # Clean up only the fixed-name holder; leave every other file alone.
        if (Test-Path $holderPath) {
            try { Remove-Item -Force $holderPath -ErrorAction SilentlyContinue } catch { Write-Log "vscode-alive cleanup (disabled) failed: $_" }
            return 'disabled-cleaned'
        }
        return $null
    }
    $alive = Test-VSCodeAlive
    if ($alive) {
        # touch: WriteAllText with empty string just refreshes mtime and
        # creates the file if missing. New-Item -Force works too but emits a
        # warning on some hosts when overwriting an existing item.
        try { [System.IO.File]::WriteAllText($holderPath, '') } catch { Write-Log "vscode-alive touch failed: $_" }
        return 'alive'
    } else {
        if (Test-Path $holderPath) {
            try { Remove-Item -Force $holderPath -ErrorAction SilentlyContinue } catch { Write-Log "vscode-alive remove failed: $_" }
        }
        return 'gone'
    }
}

Write-Log "daemon started pid=$PID interval=${intervalSec}s stateDir=$stateDir"

# ES_CONTINUOUS is retained by the process, so set it once up front.
# Ineffective under strict GPO -- kept as belt-and-braces for other hosts.
# Values: 2147483651 = 0x80000003 (ES_CONTINUOUS|ES_SYSTEM_REQUIRED|ES_AWAYMODE_REQUIRED)
#         2147483648 = 0x80000000 (ES_CONTINUOUS, releases prior request)
# PS 5.1 parses 0x8xxxxxxx literals as Int32 (negative), and [uint32] cast fails
# because the negative Int32 can't convert to UInt32. Use decimal literals.
[Win32.Power]::SetThreadExecutionState(2147483651) | Out-Null

# Fire once before the loop so that if the daemon is restarted while the DC
# 180s timer is already ticking, we do not wait a full interval before the
# first holder appears. When the flag is off Update-VSCodeHolder returns
# $null and this is a no-op.
$vscodeState = Update-VSCodeHolder
if ($null -ne $vscodeState) {
    Write-Log "vscode-watch initial state=$vscodeState"
}
$lastVSCodeState = $vscodeState

$lastHolderCount = -1
try {
    while ($true) {
        # Update VSCode state BEFORE Get-HolderCount so a fresh transition
        # takes effect in the same iteration (VSCode just opened -> holder=1
        # -> inhibit re-asserts on this same tick, not the next).
        # Update-VSCodeHolder returns: 'alive' (enabled+running),
        # 'gone' (enabled+no VSCode), 'disabled-cleaned' (disabled but had to
        # remove leaked holder), or $null (disabled, nothing to do).
        $vscodeState = Update-VSCodeHolder
        if ($vscodeState -ne $lastVSCodeState) {
            if ($null -ne $vscodeState) { Write-Log "vscode-watch state=$vscodeState" }
            $lastVSCodeState = $vscodeState
        }
        $holders = Get-HolderCount
        if ($holders -gt 0) {
            # Re-assert ES_CONTINUOUS defensively.
            [Win32.Power]::SetThreadExecutionState(2147483651) | Out-Null
            # F15: virtual key that produces no visible input.
            try { [System.Windows.Forms.SendKeys]::SendWait('{F15}') } catch { Write-Log "SendKeys failed: $_" }
            # 1px cursor nudge then restore -- some GPOs only track pointer motion.
            try {
                $pos = [System.Windows.Forms.Cursor]::Position
                [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($pos.X + 1, $pos.Y)
                [System.Windows.Forms.Cursor]::Position = $pos
            } catch { Write-Log "Cursor move failed: $_" }
        } else {
            # No holders: release ES_CONTINUOUS so the OS can sleep normally.
            [Win32.Power]::SetThreadExecutionState(2147483648) | Out-Null
        }
        # Log only on transitions to keep the log small.
        if ($holders -ne $lastHolderCount) {
            Write-Log "holders=$holders"
            $lastHolderCount = $holders
        }
        # Heartbeat: janitor checks the mtime of this file to detect a hung daemon
        # (process alive but SendKeys silent-failing / loop stalled). Written every
        # iteration so an mtime older than a few intervals is a strong hang signal.
        try { [System.IO.File]::WriteAllText($heartbeatFile, "$PID`n$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())") } catch {}
        Start-Sleep -Seconds $intervalSec
    }
} finally {
    Remove-Item -Force $pidFile -ErrorAction SilentlyContinue
    Remove-Item -Force $heartbeatFile -ErrorAction SilentlyContinue
    Write-Log "daemon exiting pid=$PID"
}
