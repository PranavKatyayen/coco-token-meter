# coco-token-meter UserPromptSubmit hook (Windows PowerShell 5.1+).
#
# On the first message of a new CoCo CLI chat, asks CoCo to show one line with
# the token usage of the previous chat and an estimate of what it cost. It
# reads only local files that CoCo CLI writes under ~/.snowflake/cortex and
# never connects to Snowflake. It keeps one small marker file per chat in
# ~/.snowflake/cortex/coco-token-meter so the line is shown once per chat.
#
# Credits are an ESTIMATE: tokens x the rates in rates.json. The billed
# figure is in COCO_TOKEN_METER.USAGE.MY_CHATS (run /tokens).

$ErrorActionPreference = 'Stop'
try {
    $cortexDir = Join-Path $env:USERPROFILE '.snowflake\cortex'
    $statsPath = Join-Path $cortexDir 'stats\usage.json'
    if (-not (Test-Path -LiteralPath $statsPath)) { exit 0 }

    # The hook receives JSON on stdin; session_id is the chat that is starting.
    $currentId = ''
    try {
        $raw = [Console]::In.ReadToEnd()
        if ($raw) { $currentId = [string]($raw | ConvertFrom-Json).session_id }
    } catch { }

    # Only on the first message of a chat.
    if ($currentId -notmatch '^[A-Za-z0-9-]{8,64}$') { exit 0 }
    $stateDir = Join-Path $cortexDir 'coco-token-meter'
    $marker = Join-Path $stateDir ($currentId + '.seen')
    if (Test-Path -LiteralPath $marker) { exit 0 }
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    Set-Content -LiteralPath $marker -Value '' -Encoding ASCII
    Get-ChildItem -LiteralPath $stateDir -Filter '*.seen' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $stats = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
    if (-not $stats.sessions) { exit 0 }

    $previous = $stats.sessions.PSObject.Properties |
        Where-Object { $_.Name -ne $currentId -and $_.Value.startTime -and $_.Value.models } |
        Sort-Object { [datetime]$_.Value.startTime } -Descending |
        Select-Object -First 1
    if (-not $previous) { exit 0 }

    $ratesPath = Join-Path $PSScriptRoot 'rates.json'
    $rates = $null
    if (Test-Path -LiteralPath $ratesPath) {
        $rates = (Get-Content -LiteralPath $ratesPath -Raw | ConvertFrom-Json).credits_per_million_tokens
    }

    [long]$fresh = 0; [long]$read = 0; [long]$write = 0; [long]$out = 0
    [double]$credits = 0; $allPriced = $true
    foreach ($m in $previous.Value.models.PSObject.Properties) {
        [long]$mRead  = $m.Value.cacheReadTokens
        [long]$mWrite = $m.Value.cacheWriteTokens
        [long]$mOut   = $m.Value.outputTokens
        # inputTokens in usage.json already includes the cached tokens.
        [long]$mFresh = [Math]::Max(0, [long]$m.Value.inputTokens - $mRead - $mWrite)
        $fresh += $mFresh; $read += $mRead; $write += $mWrite; $out += $mOut
        $r = $null
        if ($rates) { $r = $rates.PSObject.Properties[$m.Name] }
        if ($r) {
            $credits += ($mFresh * $r.Value.input + $mRead * $r.Value.cache_read_input +
                         $mWrite * $r.Value.cache_write_input + $mOut * $r.Value.output) / 1000000
        } else {
            $allPriced = $false
        }
    }
    $total = $fresh + $read + $write + $out
    if ($total -le 0) { exit 0 }

    $title = ''; $thread = ''
    $sessionPath = Join-Path $cortexDir ("conversations\" + $previous.Name + ".json")
    if (Test-Path -LiteralPath $sessionPath) {
        try {
            $s = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
            $title = [string]$s.title
            $thread = [string]$s.thread.threadId
        } catch { }
    }

    $label = 'Previous chat'
    if ($title)  { $label += " `"$title`"" }
    if ($thread) { $label += " (thread $thread)" }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $msg = [string]::Format($inv, "{0}: {1:N0} tokens (cache write {2:N0}, cache read {3:N0}, fresh input {4:N0}, output {5:N0})",
        $label, $total, $write, $read, $fresh, $out)
    if ($allPriced -and $rates) {
        $msg += [string]::Format($inv, ", about {0:N4} credits (estimate). Run /tokens for billed figures.", $credits)
    } else {
        $msg += ". Run /tokens for credits."
    }

    $context = "Note from the coco-token-meter plugin, not part of the user's request. " +
        "Start your reply with the following line exactly as written, on its own line, " +
        "then answer the user's message as usual. Do not comment on the line.`n" +
        "[coco-token-meter] $msg"
    @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $context } } |
        ConvertTo-Json -Compress -Depth 4
    exit 0
} catch {
    # Never block or break a chat because of this hook.
    exit 0
}
