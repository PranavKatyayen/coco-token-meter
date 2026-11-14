# Turns on the coco-token-meter "previous chat" line for CoCo CLI on Windows.
#
#   powershell -ExecutionPolicy Bypass -File hooks\enable-windows.ps1
#   powershell -ExecutionPolicy Bypass -File hooks\enable-windows.ps1 -Disable
#
# It copies previous-chat.ps1 and rates.json to
# %USERPROFILE%\.snowflake\cortex\coco-token-meter and registers a
# UserPromptSubmit hook in %USERPROFILE%\.snowflake\cortex\hooks.json.
# Other hooks in that file are kept. Run it again after updating the plugin.

param([switch]$Disable)

$ErrorActionPreference = 'Stop'
$cortexDir = Join-Path $env:USERPROFILE '.snowflake\cortex'
$targetDir = Join-Path $cortexDir 'coco-token-meter'
$hooksFile = Join-Path $cortexDir 'hooks.json'
$script    = Join-Path $targetDir 'previous-chat.ps1'
$marker    = 'coco-token-meter\previous-chat.ps1'
$command   = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`""

if (-not (Test-Path -LiteralPath $cortexDir)) {
    throw "CoCo CLI folder not found: $cortexDir. Start CoCo CLI once, then run this again."
}

# Load the existing hooks file, if any, without losing what is in it.
$config = $null
if (Test-Path -LiteralPath $hooksFile) {
    $text = Get-Content -LiteralPath $hooksFile -Raw
    if ($text -and $text.Trim()) { $config = $text | ConvertFrom-Json }
}
if (-not $config) { $config = New-Object psobject }
if (-not $config.PSObject.Properties['hooks']) {
    $config | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object psobject)
}

# Keep every UserPromptSubmit entry that is not ours.
$entries = @()
if ($config.hooks.PSObject.Properties['UserPromptSubmit']) {
    foreach ($entry in @($config.hooks.UserPromptSubmit)) {
        $isOurs = $false
        foreach ($h in @($entry.hooks)) {
            if ($h.command -and $h.command.Contains($marker)) { $isOurs = $true }
        }
        if (-not $isOurs) { $entries += $entry }
    }
}

if ($Disable) {
    $message = 'Previous-chat line turned off.'
} else {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'previous-chat.ps1') -Destination $targetDir -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'rates.json') -Destination $targetDir -Force
    $entries += [pscustomobject]@{
        hooks = @([pscustomobject]@{ type = 'command'; command = $command; timeout = 15 })
    }
    $message = 'Previous-chat line turned on. It appears on the first message of each new CoCo CLI chat.'
}

if ($entries.Count -gt 0) {
    if ($config.hooks.PSObject.Properties['UserPromptSubmit']) {
        $config.hooks.UserPromptSubmit = @($entries)
    } else {
        $config.hooks | Add-Member -NotePropertyName UserPromptSubmit -NotePropertyValue @($entries)
    }
} elseif ($config.hooks.PSObject.Properties['UserPromptSubmit']) {
    $config.hooks.PSObject.Properties.Remove('UserPromptSubmit')
}

$json = $config | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($hooksFile, $json, (New-Object Text.UTF8Encoding $false))
Write-Output $message
Write-Output "Hooks file: $hooksFile"
