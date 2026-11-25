# The tools that the runs of a worker's logs were given and how often they called each (the last n logs with -Last):
#   powershell -NoProfile -File tools.ps1 -Logs <a worker's .queue\logs> [-Last <n>]
# Run it after a Claude Code update, so the block list ($UnusedTools in plugin.ps1) stays right.
param(
    [Parameter(Mandatory = $true)] [string] $Logs,
    [int] $Last = 0
)
$ErrorActionPreference = 'Stop'

$files = @(Get-ChildItem $Logs -File | Where-Object { $_.Extension -eq '.jsonl' } | Sort-Object Name)
if ($Last -gt 0) {
    $files = @($files | Select-Object -Last $Last)
}
$given = @{}
$called = @{}
foreach ($file in $files) {
    $tools = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
        if ($line.StartsWith('{"type":"system","subtype":"init"')) {
            foreach ($name in [regex]::Match($line, '"tools":\[([^\]]*)\]').Groups[1].Value -split ',') {
                $tools[$name.Trim('"')] = $true
            }
        } elseif ($line.StartsWith('{"type":"assistant"')) {
            foreach ($match in [regex]::Matches($line, '"type":"(?:server_)?tool_use","id":"[^"]*","name":"([^"]+)"')) {
                $called[$match.Groups[1].Value] += 1
            }
        }
    }
    foreach ($name in $tools.Keys | Where-Object { $_ }) {
        $given[$name] += 1
    }
}
Write-Output "$($files.Count) logs in $Logs"
@($given.Keys) + @($called.Keys) | Sort-Object -Unique | ForEach-Object {
    [pscustomobject]@{ Tool = $_; Given = [int]$given[$_]; Calls = [int]$called[$_] }
} | Sort-Object @{ Expression = 'Calls'; Descending = $true }, Tool | Format-Table -AutoSize | Out-String -Width 200
