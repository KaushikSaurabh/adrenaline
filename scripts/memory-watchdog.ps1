# adrenaline memory watchdog (Windows). PURE git / filesystem / notify.
# Never runs `claude` (headless `claude -p` hangs on Windows Git-Bash). Consolidation
# is in-session (the /wrap command). This reconciles what's on disk:
#   secret-scan (incremental every run, full sweep <= weekly) -> commit -> push ->
#   consistency-check -> heartbeat -> notify-on-issue.
#
# Usage:  pwsh -NoProfile -File memory-watchdog.ps1 [-DryRun] [-ShowArm]
# Env:    ADRENALINE_HOME (default ~/.adrenaline), ADRENALINE_NTFY_TOPIC (optional)
#
# Exit codes (the scheduled task should surface anything non-zero):
#   0 clean   1 bad setup   2 secret detected (fail closed)
#   3 scan could not complete (fail closed)   4 ran but degraded (commit/push failed)

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$ShowArm,
  [string]$MemDir    = $(if($env:ADRENALINE_HOME){ $env:ADRENALINE_HOME } else { Join-Path $HOME '.adrenaline' }),
  [string]$NtfyTopic = $env:ADRENALINE_NTFY_TOPIC
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $MemDir '.watchdog.log'; $heart = Join-Path $MemDir '.watchdog.heartbeat'; $fullMarker = Join-Path $MemDir '.watchdog.lastfullscan'
$script:Status = 0   # 0 clean, 4 degraded

function Log($m){
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Output $line
  try { $line | Out-File -FilePath $log -Append -Encoding utf8 } catch { Write-Output "WARN log not writable ($log): $_" }
}
function Notify($t,$msg){
  if(-not $NtfyTopic){ Log "NOTIFY (no topic set): $t - $msg"; return }
  # curl.exe signals failure through its exit code, not a PowerShell exception.
  $out = & curl.exe -sS -H "Title: $t" -H "Priority: high" -d $msg "https://ntfy.sh/$NtfyTopic" 2>&1
  if($LASTEXITCODE -ne 0){ Log ("ntfy delivery FAILED ({0}): {1}" -f $t, (@($out) -join ' ')); $script:Status = 4 }
}
# Degrade: the run continues, but the exit code reports it.
function Degrade($m,$title){ Log $m; Notify "adrenaline: $title" $m; $script:Status = 4 }
# Abort: we cannot vouch for the store - never commit/push in that state.
function Abort($m,$title,$code){ Log $m; Notify "adrenaline: $title" $m; Log "=== abort ($title) ==="; exit $code }

# git is a native command: it never throws, so every call has to be exit-code checked.
# stderr goes to its own file so warnings (e.g. CRLF notices) never contaminate the
# parsed stdout, and so a failure's reason can be logged instead of discarded.
function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GitArgs)
  $errFile = [System.IO.Path]::GetTempFileName()
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $out = & git @GitArgs 2>$errFile
    $code = $LASTEXITCODE
    $err = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) -join ' '
  } finally { $ErrorActionPreference = $prev; Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
  $lines = @($out | ForEach-Object { [string]$_ })
  [pscustomobject]@{ Ok = ($code -eq 0); ExitCode = $code; Lines = $lines; Stderr = $err; Text = (("$err " + ($lines -join ' ')).Trim()) }
}

if($ShowArm){
@"
# Arm the watchdog (elevated pwsh, once):
`$a = New-ScheduledTaskAction -Execute 'pwsh' -Argument '-NoProfile -File "$PSCommandPath"'
`$t = New-ScheduledTaskTrigger -AtLogOn
`$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
Register-ScheduledTask -TaskName 'AdrenalineWatchdog' -Action `$a -Trigger `$t -Settings `$s
"@ | Write-Output
  exit 0
}

if(-not (Test-Path (Join-Path $MemDir '.git'))){ Write-Error "adrenaline: no git repo at $MemDir  (run: git -C `"$MemDir`" init)" -ErrorAction Continue; exit 1 }
try { Set-Location $MemDir } catch { Write-Error "adrenaline: cannot enter $MemDir : $_" -ErrorAction Continue; exit 1 }
Log "=== watchdog start (DryRun=$DryRun) ==="

$secretPatterns = @('github_pat_[A-Za-z0-9_]{20,}','gh[pousr]_[A-Za-z0-9]{20,}','glpat-[A-Za-z0-9_-]{20,}','sk-[A-Za-z0-9_-]{20,}','sk_(live|test)_[0-9A-Za-z]{16,}','AKIA[0-9A-Z]{16}','AIza[0-9A-Za-z_-]{35}','GOCSPX-[0-9A-Za-z_-]{20,}','xox[baprse]-[A-Za-z0-9-]{10,}','xapp-[0-9]-[A-Za-z0-9-]{10,}','eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}','-----BEGIN [A-Z ]*PRIVATE KEY-----')

# 1. secret scan: incremental (changed/new) every run; full sweep at most weekly.
# A scan that cannot enumerate or read its files is not a clean scan: it aborts
# (exit 3) instead of letting an unverified store reach a commit or a push.
$fullDue = $true
if(Test-Path $fullMarker){ try { $fullDue = ((Get-Date) - [datetime](Get-Content $fullMarker -Raw)).TotalDays -ge 7 } catch { Log "full-scan marker unreadable ($_) - forcing a full sweep"; $fullDue = $true } }
if($fullDue){
  $gciErr = $null
  $scanFiles = @(Get-ChildItem -Recurse -File -Path $MemDir -ErrorAction SilentlyContinue -ErrorVariable gciErr |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -notlike '.watchdog.*' -and $_.Name -ne 'memory-watchdog.ps1' } |
    ForEach-Object { $_.FullName })
  if($gciErr){ Abort ("secret scan INCOMPLETE - cannot enumerate the store: " + (@($gciErr | ForEach-Object { $_.ToString() }) -join '; ')) "scan failed" 3 }
  $scanMode = "full sweep, $($scanFiles.Count) files"
} else {
  $st = Invoke-Git @('status','--porcelain')
  if(-not $st.Ok){ Abort ("secret scan INCOMPLETE - git status failed: " + $st.Text) "scan failed" 3 }
  $scanFiles = @()
  foreach($line in $st.Lines){
    if($line.Length -lt 4){ continue }
    if($line.Substring(0,2) -match 'D'){ continue }
    $rel = $line.Substring(3).Trim('"'); if($rel -match ' -> '){ $rel = ($rel -split ' -> ')[-1].Trim('"') }
    $abs = Join-Path $MemDir $rel; $leaf = Split-Path $abs -Leaf
    if((Test-Path -LiteralPath $abs) -and $abs -notmatch '\\\.git\\' -and $leaf -notlike '.watchdog.*' -and $leaf -ne 'memory-watchdog.ps1'){ $scanFiles += $abs }
  }
  $scanMode = "incremental, $($scanFiles.Count) changed"
}
$hits = @(); $unreadable = @()
foreach($f in $scanFiles){
  try { $c = Get-Content -Raw -LiteralPath $f } catch { $unreadable += ("{0} ({1})" -f $f, $_.Exception.Message); continue }
  if($null -eq $c){ continue }   # empty file
  foreach($p in $secretPatterns){ if($c -match $p){ $hits += ("{0}: {1}" -f (Split-Path $f -Leaf), $p) } }
}
if($hits.Count -gt 0){ Abort ("SECRET SCAN FAILED - refusing to commit/push: " + ($hits -join '; ')) "SECRET DETECTED" 2 }
if($unreadable.Count -gt 0){ Abort ("secret scan INCOMPLETE - unreadable files, refusing to commit/push: " + ($unreadable -join '; ')) "scan failed" 3 }
Log ("secret scan clean ($scanMode)")
if($fullDue -and -not $DryRun){
  try { (Get-Date -Format o) | Set-Content -LiteralPath $fullMarker } catch { Degrade "cannot write full-scan marker $fullMarker : $_" "watchdog write failed" }
}

# 2. commit (one serialized committer)
$committed = $true
$st = Invoke-Git @('status','--porcelain')
if(-not $st.Ok){ Degrade ("git status FAILED: " + $st.Text) "commit failed"; $committed = $false }
elseif($st.Lines.Count -eq 0){ Log "nothing to commit" }
elseif($DryRun){ Log "DRYRUN would commit" }
else {
  $add = Invoke-Git @('add','-A')
  if(-not $add.Ok){ Degrade ("git add FAILED: " + $add.Text) "commit failed"; $committed = $false }
  else {
    $msg = "watchdog: memory commit {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $ci = Invoke-Git @('-c','user.name=watchdog','-c','user.email=watchdog@local','commit','-q','-m',$msg)
    if($ci.Ok){ Log "committed working changes" } else { Degrade ("git commit FAILED: " + $ci.Text) "commit failed"; $committed = $false }
  }
}

# 3. push (fast-forward, never --force) if a remote exists
$rem = Invoke-Git @('remote')
if(-not $rem.Ok){ Degrade ("git remote FAILED: " + $rem.Text) "push failed" }
elseif($rem.Lines.Count -eq 0){ Log "no remote configured - local only" }
elseif($DryRun){ Log "DRYRUN would push" }
elseif(-not $committed){ Log "skipping push - the commit step failed, HEAD is not the store's current state" }
else {
  $push = Invoke-Git @('push','origin','HEAD','-q')
  if($push.Ok){ Log "pushed -> origin" } else { Degrade ("push FAILED: " + $push.Text) "push failed" }
}

# 4. consistency + backlog (reminder, not blocking)
function Get-IndexEntryCount($path){
  if(-not (Test-Path -LiteralPath $path)){ return $null }
  try { return @(Get-Content -LiteralPath $path | Where-Object { $_ -match '^\s*-\s*\[' }).Count }
  catch { Degrade "cannot read $path : $_" "consistency check failed"; return $null }
}
try {
  $mdCount = (Get-ChildItem -Path $MemDir -Filter *.md -File | Where-Object { $_.Name -notin @('MEMORY.md','_UNCERTAIN.md','README.md','_INDEX.md') }).Count
  $idxFile = if(Test-Path (Join-Path $MemDir '_INDEX.md')){ '_INDEX.md' } else { 'MEMORY.md' }   # _INDEX = full index when the hot/full split is in use
  $idxPath = Join-Path $MemDir $idxFile
  $idxCount = Get-IndexEntryCount $idxPath
  if($null -eq $idxCount){ Log ("facts={0}  index({1})=MISSING/UNREADABLE" -f $mdCount, $idxFile) }
  else { Log ("facts={0}  index({1})={2}" -f $mdCount, $idxFile, $idxCount) }
} catch { Degrade "consistency check FAILED: $_" "consistency check failed" }
# MEMORY.md is the HOT injected index - guard its size (auto-memory cap ~25KB) so it never silently truncates.
$memFile = Join-Path $MemDir 'MEMORY.md'
if(Test-Path $memFile){
  try {
    $memKB = [math]::Round((Get-Item $memFile).Length / 1KB, 1); Log ("hot MEMORY.md = ${memKB}KB")
    if($memKB -gt 16){ Notify "adrenaline: MEMORY.md near cap" ("hot index ${memKB}KB (cap ~25KB) - split cold entries into _INDEX.md") }
  } catch { Degrade "cannot size MEMORY.md: $_" "consistency check failed" }
}
$uncEntries = Get-IndexEntryCount (Join-Path $MemDir '_UNCERTAIN.md')
if($null -ne $uncEntries){
  if($uncEntries -gt 0){ Log ("reminder: _UNCERTAIN.md has {0} awaiting triage" -f $uncEntries) }
  if($uncEntries -ge 3){ Notify "adrenaline: uncertain backlog" ("{0} inferred facts to triage" -f $uncEntries) }
}

# 5. heartbeat (records the run's verdict, so a degraded run isn't read as healthy)
if(-not $DryRun){
  $verdict = if($script:Status -eq 0){ 'ok' } else { 'degraded' }
  try { ("{0} status={1}" -f (Get-Date -Format o), $verdict) | Set-Content -LiteralPath $heart }
  catch { Log "cannot write heartbeat $heart : $_"; $script:Status = 4 }
}
Log "=== watchdog done (status=$($script:Status)) ==="
exit $script:Status
