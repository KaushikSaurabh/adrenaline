# adrenaline memory watchdog (Windows). PURE git / filesystem / notify.
# Never runs `claude` (headless `claude -p` hangs on Windows Git-Bash). Consolidation
# is in-session (the /wrap command). This reconciles what's on disk:
#   secret-scan (incremental every run, full sweep <= weekly) -> commit -> push ->
#   consistency-check -> heartbeat -> notify-on-issue.
#
# Usage:  pwsh -NoProfile -File memory-watchdog.ps1 [-DryRun] [-ShowArm]
# Env:    ADRENALINE_HOME (default ~/.adrenaline), ADRENALINE_NTFY_TOPIC (optional),
#         ADRENALINE_SECRET_PATTERNS (default .\secret-patterns.txt, shared with the sh)

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$ShowArm,
  [string]$MemDir    = $(if($env:ADRENALINE_HOME){ $env:ADRENALINE_HOME } else { Join-Path $HOME '.adrenaline' }),
  [string]$NtfyTopic = $env:ADRENALINE_NTFY_TOPIC,
  [string]$PatternFile = $(if($env:ADRENALINE_SECRET_PATTERNS){ $env:ADRENALINE_SECRET_PATTERNS } else { Join-Path $PSScriptRoot 'secret-patterns.txt' })
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $MemDir '.watchdog.log'; $heart = Join-Path $MemDir '.watchdog.heartbeat'; $fullMarker = Join-Path $MemDir '.watchdog.lastfullscan'
function Log($m){ ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append }
function Notify($t,$msg){ if(-not $NtfyTopic){ Log "NOTIFY (no topic set): $t - $msg"; return } try { & curl.exe -s -H "Title: $t" -H "Priority: high" -d $msg "https://ntfy.sh/$NtfyTopic" | Out-Null } catch { Log "ntfy failed: $_" } }
# shared secret-reject patterns (same file the bash watchdog reads); '#'/blank lines are comments
function Get-SecretPattern($path){ @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }) }
# a file the scanner should read: exists, and is not git internals or the watchdog's own files
function Test-Scannable($path){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return $false }
  if($path -match '[\\/]\.git[\\/]'){ return $false }
  $leaf = Split-Path $path -Leaf
  return -not ($leaf -like '.watchdog.*' -or $leaf -like 'memory-watchdog.*' -or $leaf -eq 'secret-patterns.txt')
}
# index/backlog pointers are markdown list links: '- [slug](...)'
function Get-PointerCount($path){ @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*-\s*\[' }).Count }

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

$secretPatterns = Get-SecretPattern $PatternFile
if($secretPatterns.Count -eq 0){ Log "no usable secret patterns at $PatternFile"; Notify "adrenaline: watchdog misconfigured" "missing/empty secret patterns: $PatternFile"; Log "=== abort (cannot secret-scan) ==="; return }

# 1. secret scan: incremental (changed/new) every run; full sweep at most weekly.
$fullDue = $true
if(Test-Path $fullMarker){ try { $fullDue = ((Get-Date) - [datetime](Get-Content $fullMarker -Raw)).TotalDays -ge 7 } catch { $fullDue = $true } }
if($fullDue){
  $scanFiles = @(Get-ChildItem -Recurse -File -Path $MemDir | ForEach-Object { $_.FullName } | Where-Object { Test-Scannable $_ })
  $scanMode = "full sweep, $($scanFiles.Count) files"
} else {
  $scanFiles = @()
  foreach($line in @(git status --porcelain)){
    if($line.Length -lt 4){ continue }
    if($line.Substring(0,2) -match 'D'){ continue }
    $rel = $line.Substring(3).Trim('"'); if($rel -match ' -> '){ $rel = ($rel -split ' -> ')[-1].Trim('"') }
    $abs = Join-Path $MemDir $rel
    if(Test-Scannable $abs){ $scanFiles += $abs }
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
$mdCount  = (Get-ChildItem -Path $MemDir -Filter *.md -File | Where-Object { $_.Name -notin @('MEMORY.md','_UNCERTAIN.md','README.md','_INDEX.md') }).Count
$idxFile  = if(Test-Path (Join-Path $MemDir '_INDEX.md')){ '_INDEX.md' } else { 'MEMORY.md' }   # _INDEX = full index when the hot/full split is in use
$idxCount = Get-PointerCount (Join-Path $MemDir $idxFile)
Log ("facts={0}  index({1})={2}" -f $mdCount, $idxFile, $idxCount)
# MEMORY.md is the HOT injected index - guard its size (auto-memory cap ~25KB) so it never silently truncates.
$memFile = Join-Path $MemDir 'MEMORY.md'
if(Test-Path $memFile){ $memKB = [math]::Round((Get-Item $memFile).Length / 1KB, 1); Log ("hot MEMORY.md = ${memKB}KB"); if($memKB -gt 16){ Notify "adrenaline: MEMORY.md near cap" ("hot index ${memKB}KB (cap ~25KB) - split cold entries into _INDEX.md") } }
$unc = Join-Path $MemDir '_UNCERTAIN.md'
$uncEntries = Get-PointerCount $unc
if($uncEntries -gt 0){ Log ("reminder: _UNCERTAIN.md has {0} awaiting triage" -f $uncEntries) }
if($uncEntries -ge 3){ Notify "adrenaline: uncertain backlog" ("{0} inferred facts to triage" -f $uncEntries) }

# 5. heartbeat
if(-not $DryRun){ (Get-Date -Format o) | Set-Content -LiteralPath $heart }
Log "=== watchdog done ==="
