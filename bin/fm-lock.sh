#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# On Windows/msys (Git Bash) the ancestry walk instead runs against the native
# Win32 process table via PowerShell (see the "Windows/msys" section below),
# because msys `ps` cannot report a usable ancestry chain there; the recorded
# PID is a native Windows PID in that case, not an msys one.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

# Windows/msys (Git Bash) support --------------------------------------------
# msys `ps`/`kill` only understand the msys PID namespace, which has no fixed
# relationship to real Windows PIDs, and msys `ps` cannot report `-o comm=`/
# `-o args=`/`-o ppid=` at all (its `ps --help` offers only -aefls, no custom
# `-o` format) - so the Unix ancestry walk below fails outright on the very
# first hop, every time, which is the "cannot locate harness process in
# ancestry" failure this section exists to fix. Even where a similar `-o`
# flag exists on other msys builds, the ppid it reports is not trustworthy:
# a process not spawned via msys fork/exec (e.g. the claude.exe harness
# itself) shows up as ppid=1 ("orphaned") to msys ps because msys never
# learns its real Win32 parent. The true parent chain only exists in the
# native Win32 process table, so on msys this walks THAT table via one
# PowerShell process, entirely in native Windows PIDs, and never mixes msys
# and native PID spaces within a single check.
fm_lock_is_msys() {
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_lock_win_ps_exe() {
  command -v powershell >/dev/null 2>&1 && { echo powershell; return 0; }
  command -v pwsh >/dev/null 2>&1 && { echo pwsh; return 0; }
  return 1
}

# fm_lock_win_native_pid: this bash's own real Windows PID. $$ is an msys PID
# with no fixed relationship to it; /proc/$$/winpid is msys2's own escape
# hatch to the native one. Read without a subshell - a `$(...)` command
# substitution forks, and /proc/self inside the fork would report the
# short-lived subshell's own winpid, not this process's.
fm_lock_win_native_pid() {
  local p
  read -r p < "/proc/$$/winpid" 2>/dev/null || return 1
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$p"
}

# fm_lock_win_lookup <start-native-pid> <max-hops>: walk the native Win32
# process tree starting at <start-native-pid>, up to <max-hops> generations
# (1 = check only the start pid itself, no climbing), matching each process's
# name - and, for a bare node/python interpreter, its command line - against
# $HARNESS_RE. The whole table is fetched once and the walk happens inside a
# single PowerShell process for speed; prints the matching native PID and
# returns 0 on a match. Returns non-zero on missing PowerShell, an
# unresolvable start pid, or no match within the hop budget - all fail
# closed, exactly like the Unix path above.
fm_lock_win_lookup() {
  local start=$1 hops=$2 ps_exe script winscript rc result
  ps_exe=$(fm_lock_win_ps_exe) || return 1
  script=$(mktemp "$STATE/fm-lock-win.XXXXXX.ps1") || return 1
  cat > "$script" <<'PS1'
$ErrorActionPreference = 'SilentlyContinue'
$re = $env:FM_LOCK_WIN_HARNESS_RE
$maxHops = [int]$env:FM_LOCK_WIN_MAX_HOPS
$procs = @{}
foreach ($p in (Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CommandLine)) {
  $procs[[int]$p.ProcessId] = $p
}
$targetPid = [int]$env:FM_LOCK_WIN_START_PID
$found = $null
for ($i = 0; $i -lt $maxHops; $i++) {
  if (-not $procs.ContainsKey($targetPid)) { break }
  $p = $procs[$targetPid]
  $name = [IO.Path]::GetFileNameWithoutExtension($p.Name)
  if ($name -imatch $re) { $found = $p.ProcessId; break }
  if ($name -imatch '^(node|python)$' -and $p.CommandLine -and ($p.CommandLine -imatch $re)) { $found = $p.ProcessId; break }
  if (-not $p.ParentProcessId -or [int]$p.ParentProcessId -eq 0) { break }
  $targetPid = [int]$p.ParentProcessId
}
if ($found) { Write-Output $found; exit 0 }
exit 1
PS1
  winscript=$(cygpath -w "$script" 2>/dev/null) || winscript=$script
  result=$(FM_LOCK_WIN_HARNESS_RE="$HARNESS_RE" FM_LOCK_WIN_MAX_HOPS="$hops" FM_LOCK_WIN_START_PID="$start" \
    "$ps_exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$winscript")
  rc=$?
  rm -f "$script"
  [ "$rc" -eq 0 ] && [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# fm_lock_win_harness_pid: msys entry point for harness_pid. Prefers a
# verified harness self-PID environment marker (currently: Claude Code's
# CLAUDE_PID) over the native ancestry walk, because the walk has a real race
# on this platform - msys's fork/exec emulation (and/or whatever spawns the
# leaf bash.exe for a given command) can leave a short-lived intermediate
# process in the real Win32 parent chain that has already exited by the time
# a PowerShell process can query it, even though it was genuinely this
# process's parent a moment earlier; msys `ps` shows the same process as
# ppid=1 ("orphaned") for the same reason, confirming it is not a query-speed
# problem to fix, but a real gap in what any post-hoc ancestry read can see.
# CLAUDE_PID sidesteps that entirely: the harness reports its own real
# Windows PID directly, no walk required. Other harnesses without a verified
# self-PID marker fall back to the walk and inherit that residual gap.
fm_lock_win_harness_pid() {
  if [ "${CLAUDECODE:-}" = "1" ]; then
    case "${CLAUDE_PID:-}" in
      ''|*[!0-9]*) : ;;
      *) printf '%s\n' "$CLAUDE_PID"; return 0 ;;
    esac
  fi
  local self
  self=$(fm_lock_win_native_pid) || return 1
  fm_lock_win_lookup "$self" 8
}

harness_pid() {
  if fm_lock_is_msys; then
    fm_lock_win_harness_pid
    return $?
  fi
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  if fm_lock_is_msys; then
    fm_lock_win_lookup "$pid" 1 >/dev/null
    return $?
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
