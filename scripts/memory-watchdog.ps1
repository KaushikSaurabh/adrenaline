# adrenaline memory watchdog (Windows). PURE git / filesystem / notify.
# Never runs `claude` (headless `claude -p` hangs on Windows Git-Bash). Consolidation
# is in-session (the /wrap command). This reconciles what's on disk:
#   secret-scan (incremental every run, full sweep <= weekly) -> commit -> push ->
#   consistency-check -> heartbeat -> notify-on-issue.
#
# Usage:  pwsh -NoProfile -File memory-watchdog.ps1 [-DryRun] [-ShowArm]
# Env:    ADRENALINE_HOME (default ~/.adrenaline), ADRENALINE_NTFY_TOPIC (optional)

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$ShowArm,
  [string]$MemDir    = $(if($env:ADRENALINE_HOME){ $env:ADRENALINE_HOME } else { Join-Path $HOME '.adrenaline' }),
  [string]$NtfyTopic = $env:ADRENALINE_NTFY_TOPIC
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $MemDir '.watchdog.log'; $heart = Join-Path $MemDir '.watchdog.heartbeat'; $fullMarker = Join-Path $MemDir '.watchdog.lastfullscan'
function Log($m){ ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append }
function Notify($t,$msg){ if(-not $NtfyTopic){ Log "NOTIFY (no topic set): $t - $msg"; return } try { & curl.exe -s -H "Title: $t" -H "Priority: high" -d $msg "https://ntfy.sh/$NtfyTopic" | Out-Null } catch { Log "ntfy failed: $_" } }

if($ShowArm){
@"
# Arm the watchdog (elevated pwsh, once):
`$a = New-ScheduledTaskAction -Execute 'pwsh' -Argument '-NoProfile -File "$PSCommandPath"'
`$t = New-ScheduledTaskTrigger -AtLogOn
`$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
Register-ScheduledTask -TaskName 'AdrenalineWatchdog' -Action `$a -Trigger `$t -Settings `$s
"@ | Write-Output
  return
}

if(-not (Test-Path (Join-Path $MemDir '.git'))){ Write-Output "adrenaline: no git repo at $MemDir  (run: git -C `"$MemDir`" init)"; return }
Set-Location $MemDir
Log "=== watchdog start (DryRun=$DryRun) ==="

$secretPatterns = @('github_pat_[A-Za-z0-9_]{20,}','gh[pousr]_[A-Za-z0-9]{20,}','glpat-[A-Za-z0-9_-]{20,}','sk-[A-Za-z0-9_-]{20,}','sk_(live|test)_[0-9A-Za-z]{16,}','AKIA[0-9A-Z]{16}','AIza[0-9A-Za-z_-]{35}','GOCSPX-[0-9A-Za-z_-]{20,}','xox[baprse]-[A-Za-z0-9-]{10,}','xapp-[0-9]-[A-Za-z0-9-]{10,}','eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}','-----BEGIN [A-Z ]*PRIVATE KEY-----')

# 1. secret scan: incremental (changed/new) every run; full sweep at most weekly.
$fullDue = $true
if(Test-Path $fullMarker){ try { $fullDue = ((Get-Date) - [datetime](Get-Content $fullMarker -Raw)).TotalDays -ge 7 } catch { $fullDue = $true } }
if($fullDue){
  $scanFiles = @(Get-ChildItem -Recurse -File -Path $MemDir | Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -notlike '.watchdog.*' -and $_.Name -ne 'memory-watchdog.ps1' } | ForEach-Object { $_.FullName })
  $scanMode = "full sweep, $($scanFiles.Count) files"
} else {
  $scanFiles = @()
  foreach($line in @(git status --porcelain)){
    if($line.Length -lt 4){ continue }
    if($line.Substring(0,2) -match 'D'){ continue }
    $rel = $line.Substring(3).Trim('"'); if($rel -match ' -> '){ $rel = ($rel -split ' -> ')[-1].Trim('"') }
    $abs = Join-Path $MemDir $rel; $leaf = Split-Path $abs -Leaf
    if((Test-Path -LiteralPath $abs) -and $abs -notmatch '\\\.git\\' -and $leaf -notlike '.watchdog.*' -and $leaf -ne 'memory-watchdog.ps1'){ $scanFiles += $abs }
  }
  $scanMode = "incremental, $($scanFiles.Count) changed"
}
$hits = @()
foreach($f in $scanFiles){ $c = Get-Content -Raw -LiteralPath $f -ErrorAction SilentlyContinue; if($null -eq $c){ continue }; foreach($p in $secretPatterns){ if($c -match $p){ $hits += ("{0}: {1}" -f (Split-Path $f -Leaf), $p) } } }
if($hits.Count -gt 0){ Log ("SECRET SCAN FAILED - refusing to commit/push: " + ($hits -join '; ')); Notify "adrenaline: SECRET DETECTED" ($hits -join '; '); Log "=== abort (secrets present) ==="; return }
Log ("secret scan clean ($scanMode)")
if($fullDue -and -not $DryRun){ (Get-Date -Format o) | Set-Content -LiteralPath $fullMarker }

# 2. commit (one serialized committer)
if(git status --porcelain){ if($DryRun){ Log "DRYRUN would commit" } else { git add -A | Out-Null; git -c user.name=watchdog -c user.email=watchdog@local commit -q -m ("watchdog: memory commit {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')); Log "committed working changes" } } else { Log "nothing to commit" }

# 3. push (fast-forward, never --force) if a remote exists
if(@(git remote).Count -gt 0){ if(-not $DryRun){ try { git push origin HEAD -q; Log "pushed -> origin" } catch { Log "push FAILED: $_"; Notify "adrenaline: push failed" "$_" } } } else { Log "no remote configured - local only" }

# 4. consistency + backlog (reminder, not blocking)
$mdCount  = (Get-ChildItem -Path $MemDir -Filter *.md -File | Where-Object { $_.Name -ne 'MEMORY.md' -and $_.Name -ne '_UNCERTAIN.md' -and $_.Name -ne 'README.md' }).Count
$idxCount = @(Get-Content (Join-Path $MemDir 'MEMORY.md') -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*-\s*\[' }).Count
Log ("facts={0}  index={1}" -f $mdCount, $idxCount)
$unc = Join-Path $MemDir '_UNCERTAIN.md'
$uncEntries = @(Get-Content $unc -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*-\s*\[' }).Count
if($uncEntries -gt 0){ Log ("reminder: _UNCERTAIN.md has {0} awaiting triage" -f $uncEntries) }
if($uncEntries -ge 3){ Notify "adrenaline: uncertain backlog" ("{0} inferred facts to triage" -f $uncEntries) }

# 5. heartbeat
if(-not $DryRun){ (Get-Date -Format o) | Set-Content -LiteralPath $heart }
Log "=== watchdog done ==="
