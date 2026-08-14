# adrenaline memory watchdog (Windows). PURE git / filesystem / notify.
# Never runs `claude` (headless `claude -p` hangs on Windows Git-Bash). Consolidation
# is in-session (the /wrap command). This reconciles what's on disk:
#   secret-scan (incremental every run, full sweep <= weekly) -> commit -> push ->
#   consistency-check -> heartbeat -> notify-on-issue.
#
# Usage:  pwsh -NoProfile -File memory-watchdog.ps1 [-DryRun] [-ShowArm]
# Env:    ADRENALINE_HOME (default ~/.adrenaline), ADRENALINE_NTFY_TOPIC (optional),
#         ADRENALINE_NTFY_TOKEN (optional ntfy access token)

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$ShowArm,
  [string]$MemDir    = $(if($env:ADRENALINE_HOME){ $env:ADRENALINE_HOME } else { Join-Path $HOME '.adrenaline' }),
  [string]$NtfyTopic = $env:ADRENALINE_NTFY_TOPIC,
  [string]$NtfyToken = $env:ADRENALINE_NTFY_TOKEN
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $MemDir '.watchdog.log'; $heart = Join-Path $MemDir '.watchdog.heartbeat'; $fullMarker = Join-Path $MemDir '.watchdog.lastfullscan'
function Log($m){ ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append }
# ntfy topics are unauthenticated by default: anyone who knows the topic can read it,
# so notifications carry file names only, never file contents.
function Notify($t,$msg){
  if(-not $NtfyTopic){ Log "NOTIFY (no topic set): $t - $msg"; return }
  if($NtfyTopic -notmatch '^[A-Za-z0-9_-]+$'){ Log "NOTIFY (invalid ADRENALINE_NTFY_TOPIC, refusing to call ntfy): $t - $msg"; return }
  $headers = @('-H', "Title: $t", '-H', 'Priority: high')
  if($NtfyToken){ $headers += @('-H', "Authorization: Bearer $NtfyToken") }
  try { & curl.exe -s --proto '=https' --max-time 10 @headers --data-binary $msg "https://ntfy.sh/$NtfyTopic" | Out-Null } catch { Log "ntfy failed: $_" }
}

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

if(-not (Test-Path -LiteralPath (Join-Path $MemDir '.git'))){ Write-Output "adrenaline: no git repo at $MemDir  (run: git -C `"$MemDir`" init)"; exit 1 }
Set-Location $MemDir
Log "=== watchdog start (DryRun=$DryRun) ==="

$secretPatterns = @('github_pat_[A-Za-z0-9_]{20,}','gh[pousr]_[A-Za-z0-9]{20,}','glpat-[A-Za-z0-9_-]{20,}','sk-[A-Za-z0-9_-]{20,}','(sk|rk)_(live|test)_[0-9A-Za-z]{16,}','A(KIA|SIA)[0-9A-Z]{16}','npm_[A-Za-z0-9]{36}','hf_[A-Za-z0-9]{30,}','dop_v1_[a-f0-9]{64}','SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}','Authorization: *(Bearer|Basic) +[A-Za-z0-9._~+/=-]{16,}','AIza[0-9A-Za-z_-]{35}','GOCSPX-[0-9A-Za-z_-]{20,}','xox[baprse]-[A-Za-z0-9-]{10,}','xapp-[0-9]-[A-Za-z0-9-]{10,}','eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}','-----BEGIN [A-Z ]*PRIVATE KEY-----')

# 1. secret scan: incremental (changed/new) every run; full sweep at most weekly.
$fullDue = $true
if(Test-Path $fullMarker){ try { $fullDue = ((Get-Date) - [datetime](Get-Content $fullMarker -Raw)).TotalDays -ge 7 } catch { $fullDue = $true } }
function Test-Scannable($path){
  $leaf = Split-Path $path -Leaf
  if($path -match '[\\/]\.git[\\/]'){ return $false }
  if($leaf -like '.watchdog.*'){ return $false }
  if($leaf -in @('memory-watchdog.ps1','memory-watchdog.sh')){ return $false }
  return $true
}
if($fullDue){
  # -Force so hidden/dot files are scanned too - they get committed by `git add -A` either way.
  $scanFiles = @(Get-ChildItem -Recurse -File -Force -LiteralPath $MemDir | Where-Object { Test-Scannable $_.FullName } | ForEach-Object { $_.FullName })
  $scanMode = "full sweep, $($scanFiles.Count) files"
} else {
  # -z + core.quotePath=false + -uall: paths with spaces/quotes/non-ASCII bytes stay
  # verbatim and untracked directories expand to their files, so nothing `git add -A`
  # is about to commit slips past the scan unseen.
  $scanFiles = @()
  $entries = @(((& git -c core.quotePath=false status --porcelain -z -uall | Out-String).TrimEnd("`r","`n")) -split "`0" | Where-Object { $_ -ne '' })
  for($i = 0; $i -lt $entries.Count; $i++){
    $line = $entries[$i]
    if($line.Length -lt 4){ continue }
    $xy = $line.Substring(0,2)
    if($xy -match 'R|C'){ $i++ }        # rename/copy: the next field is the source path
    if($xy -match 'D'){ continue }
    $abs = Join-Path $MemDir $line.Substring(3)
    if((Test-Path -LiteralPath $abs -PathType Leaf) -and (Test-Scannable $abs)){ $scanFiles += $abs }
  }
  $scanMode = "incremental, $($scanFiles.Count) changed"
}
$hits = @()
foreach($f in $scanFiles){ $c = Get-Content -Raw -LiteralPath $f -ErrorAction SilentlyContinue; if($null -eq $c){ continue }; foreach($p in $secretPatterns){ if($c -match $p){ $hits += ("{0}: {1}" -f (Split-Path $f -Leaf), $p) } } }
if($hits.Count -gt 0){ Log ("SECRET SCAN FAILED - refusing to commit/push: " + ($hits -join '; ')); Notify "adrenaline: SECRET DETECTED" ($hits -join '; '); Log "=== abort (secrets present) ==="; exit 2 }
Log ("secret scan clean ($scanMode)")
if($fullDue -and -not $DryRun){ (Get-Date -Format o) | Set-Content -LiteralPath $fullMarker }

# 2. commit (one serialized committer)
if(git status --porcelain){ if($DryRun){ Log "DRYRUN would commit" } else { git add -A | Out-Null; git -c user.name=watchdog -c user.email=watchdog@local commit -q -m ("watchdog: memory commit {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')); Log "committed working changes" } } else { Log "nothing to commit" }

# 3. push (fast-forward, never --force) if a remote exists
if(@(git remote).Count -gt 0){ if(-not $DryRun){ try { git push origin HEAD -q; Log "pushed -> origin" } catch { Log "push FAILED: $_"; Notify "adrenaline: push failed" "$_" } } } else { Log "no remote configured - local only" }

# 4. consistency + backlog (reminder, not blocking)
$mdCount  = (Get-ChildItem -Path $MemDir -Filter *.md -File | Where-Object { $_.Name -notin @('MEMORY.md','_UNCERTAIN.md','README.md','_INDEX.md') }).Count
$idxFile  = if(Test-Path (Join-Path $MemDir '_INDEX.md')){ '_INDEX.md' } else { 'MEMORY.md' }   # _INDEX = full index when the hot/full split is in use
$idxCount = @(Get-Content (Join-Path $MemDir $idxFile) -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*-\s*\[' }).Count
Log ("facts={0}  index({1})={2}" -f $mdCount, $idxFile, $idxCount)
# MEMORY.md is the HOT injected index - guard its size (auto-memory cap ~25KB) so it never silently truncates.
$memFile = Join-Path $MemDir 'MEMORY.md'
if(Test-Path $memFile){ $memKB = [math]::Round((Get-Item $memFile).Length / 1KB, 1); Log ("hot MEMORY.md = ${memKB}KB"); if($memKB -gt 16){ Notify "adrenaline: MEMORY.md near cap" ("hot index ${memKB}KB (cap ~25KB) - split cold entries into _INDEX.md") } }
$unc = Join-Path $MemDir '_UNCERTAIN.md'
$uncEntries = @(Get-Content $unc -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*-\s*\[' }).Count
if($uncEntries -gt 0){ Log ("reminder: _UNCERTAIN.md has {0} awaiting triage" -f $uncEntries) }
if($uncEntries -ge 3){ Notify "adrenaline: uncertain backlog" ("{0} inferred facts to triage" -f $uncEntries) }

# 5. heartbeat
if(-not $DryRun){ (Get-Date -Format o) | Set-Content -LiteralPath $heart }
Log "=== watchdog done ==="
