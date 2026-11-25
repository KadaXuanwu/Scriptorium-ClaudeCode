# Scriptorium's provider for Claude Code (Scriptorium's docs/PLUGINS.md, A provider): starts a run with `claude -p`,
# reads its stream-json log, and knows a login's plan, its usage windows and the wordings of its refusals. Runs in
# Windows PowerShell 5.1 and in PowerShell 7. Only definitions; the last statement is the hooks. Checked by
# plugin.test.ps1.

# $IsMacOS is not there in Windows PowerShell 5.1.
$OnWindows = $env:OS -eq 'Windows_NT'
$OnMac = -not $OnWindows -and [bool]$IsMacOS

# The plan's weekly window of Fable alone, as the CLI's rate limit events name it (models.json, `windows`).
$FableWindow = 'seven_day_overage_included'

# Tools no run used in 631 logs; without them every turn reads 4,750 tokens less. Workflow: given in 89 of 698 logs,
# never called, 1,977 tokens. Skill and ToolSearch stay: without them the tools Claude Code holds back load in full.
# PowerShell (trial): 3,800 tokens, 749 calls against 40,868 of Bash; the run's one shell is Bash (PLAYBOOK.md, One
# shell). Glob: 275 tokens, 10 calls in 328 logs; a run finds files with Grep and Bash.
$UnusedTools = 'Task,CronCreate,CronDelete,CronList,DesignSync,EnterWorktree,ExitWorktree,ListAgents,NotebookEdit,' +
    'PushNotification,RemoteTrigger,ReportFindings,SendMessage,WebFetch,WebSearch,Workflow,PowerShell,Glob'

# The cheapest request an account answers: Haiku with no tools, settings, plugins or skills, and a one-line system
# prompt in place of Claude Code's own, about 900 tokens. The Probe hook sends it, in a folder with no CLAUDE.md. A
# probe of the whole harness read 46,097 tokens.
$BareRequestArgs = @('--model', 'haiku', '--tools=', '--system-prompt', 'Reply with one dot.', '--setting-sources=local',
    '--strict-mcp-config', '--disable-slash-commands', '--max-turns', '1')

# Claude Code compacts 33000 tokens before its window (CLAUDE_CODE_AUTO_COMPACT_WINDOW, from 100000 to 1000000;
# measured with Claude Code 2.1.323). So models.json's `compactRange` is 67000 to 967000.
$CompactLead = 33000

# The SHA-256 of a text, in lowercase hex.
function Get-TextHash([string] $text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

# The folder of a login: $login, or ~/.claude for '' (the command-line login).
function Get-LoginDir([string] $login) {
    if ($login) {
        return $login
    }
    return Join-Path $HOME '.claude'
}

# A login's credentials as Claude Code keeps them, as text: '' while it is signed out. Windows and Linux keep them in
# the folder's .credentials.json, macOS in the login keychain, under a name with a hash of the folder for any folder
# but the default one.
# shortcut: the keychain name (the first 8 hex digits of the SHA-256 of the folder's path) is what other tools found,
# not a documented contract; if a Mac shows every account signed out, compare with `security dump-keychain | grep Claude`.
function Get-CredentialsText([string] $login) {
    $file = Join-Path (Get-LoginDir $login) '.credentials.json'
    if (Test-Path $file) {
        return [string](Get-Content $file -Raw -Encoding UTF8)
    }
    if (-not $OnMac) {
        return ''
    }
    $service = 'Claude Code-credentials'
    if ($login) {
        $service += '-' + (Get-TextHash $login).Substring(0, 8)
    }
    $ErrorActionPreference = 'Continue'
    $text = & /usr/bin/security find-generic-password -s $service -w 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return ($text -join "`n")
}

# The credentials as an object, $null while signed out or unreadable.
function Read-Credentials([string] $login) {
    $text = Get-CredentialsText $login
    if (-not $text.Trim()) {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        return $null
    }
}

# What changes when the login changes (a sign-in, a refresh): the file's time, or a hash of the keychain's text.
function Get-CredentialsStamp([string] $login) {
    $file = Join-Path (Get-LoginDir $login) '.credentials.json'
    if (Test-Path $file) {
        return [string](Get-Item $file).LastWriteTimeUtc.Ticks
    }
    $text = Get-CredentialsText $login
    if (-not $text) {
        return '0'
    }
    return Get-TextHash $text
}

# The login's email, from its profile file; '' without one. The file of the command-line login is ~/.claude.json.
function Get-LoginEmail([string] $login) {
    $file = if ($login) { Join-Path $login '.claude.json' } else { Join-Path $HOME '.claude.json' }
    if (-not (Test-Path $file)) {
        return ''
    }
    # A regex, not ConvertFrom-Json: the file can hold keys differing only in case, which Windows PowerShell refuses.
    return [regex]::Match((Get-Content $file -Raw -Encoding UTF8), '"emailAddress"\s*:\s*"([^"]+)"').Groups[1].Value
}

# A plan's size relative to Pro, from the login's rate limit tier: a run costs a bigger plan a smaller share.
function Get-PlanSize([string] $tier) {
    if ($tier -match 'max_20x') {
        return 20.0
    }
    if ($tier -match 'max_5x') {
        return 5.0
    }
    return 1.0
}

# A login's plan as the page names it, from its credentials.
function Get-PlanName($credentials) {
    $oauth = if ($credentials) { $credentials.claudeAiOauth } else { $null }
    if (-not $oauth) {
        return ''
    }
    if ($oauth.rateLimitTier -match 'max_(\d+)x') {
        return "Max $($Matches[1])x"
    }
    $type = [string]$oauth.subscriptionType
    if ($type) {
        return $type.Substring(0, 1).ToUpperInvariant() + $type.Substring(1)
    }
    return ''
}

# The variable that names a login for the claude processes: its folder, and none for the command-line login.
function Get-LoginEnv([string] $login) {
    return @{ CLAUDE_CONFIG_DIR = $(if ($login) { $login } else { $null }) }
}

# Runs $block with these environment variables (one with no value is taken away) and, with $dir, in that folder; puts
# both back after it.
function Invoke-WithEnv([hashtable] $variables, [scriptblock] $block, [string] $dir = '') {
    $previous = @{}
    foreach ($name in @($variables.Keys)) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $(if ($null -ne $variables[$name]) { [string]$variables[$name] }))
    }
    if ($dir) {
        Push-Location $dir
    }
    try {
        return (& $block)
    } finally {
        if ($dir) {
            Pop-Location
        }
        foreach ($name in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
}

# Why a run that ended with an error is not its ticket's failure, from its result line ($result: `is_error`, the
# error's text in `result`, `total_cost_usd` and `subtype`): 'model', 'subscription', 'login', 'limit', 'start' (the
# base's kinds, Scriptorium's limits.ps1) or 'fable' (the Fable limit: the ReadRun hook names the window for it).
# 'start': the run did no work (no cost) and its first request failed, for a cause the text does not name. It catches
# a wording this list does not know. '': the run's own failure, its cap (`subtype` `error_max_budget_usd`), or no
# error. The texts are the CLI's own.
function Get-Refusal($result) {
    # Before the texts: the cap's wording is unknown, and a word like "limit" would hold the run for the account.
    if (-not $result -or -not $result.is_error -or $result.subtype -eq 'error_max_budget_usd') {
        return ''
    }
    $text = [string]$result.result
    $noWork = [double]$result.total_cost_usd -eq 0
    # First: one wording ends "limit reached", and its api_error is the same as a plan without the model's.
    if ($text -match 'Fable limit') {
        return 'fable'
    }
    if ($noWork -and $text -match 'requires usage credits|not available|no access|access to') {
        return 'model'
    }
    if ($text -match 'Claude subscription|past due|settings/billing|subscription access') {
        return 'subscription'
    }
    if ($text -match 'authenticat|OAuth|not logged in|/login') {
        return 'login'
    }
    if ($text -match 'usage limit|rate limit|limit reached|hit your limit') {
        return 'limit'
    }
    # A run that ended before its first request (a session to resume that is gone, a wrong argument) is its own
    # failure: its `subtype` is not 'success'.
    return $(if ($noWork -and $result.subtype -eq 'success') { 'start' } else { '' })
}

# The last result line of a log's text as an object, $null without one. A result line starts with another key in
# newer Claude Code ({"duration_api_ms"...), so it is found by its type.
function Read-Result([string] $text) {
    $line = ($text -split "`n") | Where-Object { $_ -like '*"type":"result"*' } | Select-Object -Last 1
    if (-not $line) {
        return $null
    }
    return $line | ConvertFrom-Json
}

# The plan's usage from a log's last (or first) rate_limit_event, as the base reads it (ReadUsage): each window's
# share used and reset, and the window whose limit refused the request ('account' when the event names none).
function Read-UsageEvent([string] $text, [bool] $first) {
    # Only events with the plan's windows: a model the plan lacks sends a rejection without them.
    $lines = @(($text -split "`n") | Where-Object { $_ -like '*"rate_limit_event"*' -and $_ -like '*"unifiedWindows"*' })
    if (-not $lines.Count) {
        return $null
    }
    $info = ($(if ($first) { $lines[0] } else { $lines[-1] }) | ConvertFrom-Json).rate_limit_info
    $read = @{ Windows = @{}; Refused = ''; RefusedResetsAt = [long]$info.resetsAt }
    if ($info.status -eq 'rejected') {
        $read.Refused = if ($info.rateLimitType) { [string]$info.rateLimitType } else { 'account' }
    }
    foreach ($window in $info.unifiedWindows.PSObject.Properties) {
        if ($window.Value) {
            $read.Windows[$window.Name] = @{ Used = [double]$window.Value.utilization; ResetsAt = [long]$window.Value.resetsAt }
        }
    }
    return $read
}

# The commands that one Bash call chains: its parts between `;`, `&&`, `||` and line ends, at least 1. A pipeline is one
# command. A here-document's body and what stands in quotes are left out first. `cd` and the words of a loop or an if
# are no command. A run batches its work this way, so tool calls for each request cannot show it (the base's
# PLAYBOOK.md, Turns).
# shortcut: no shell parser, so a quote in a comment or a `;` inside $( ) miscounts; parse when one run's count matters.
function Get-CommandCount([string] $command) {
    # One pass for both quotes: the one that opens first wins, so an apostrophe inside double quotes opens nothing.
    $bare = $command -replace '(?s)<<-?\s*[''"]?(\w+)[''"]?.*?\n\s*\1\b', '' `
        -replace '''[^'']*''|"(?:[^"\\]|\\.)*"', 'Q'
    $parts = @($bare -split '&&|\|\||;|\n' |
        Where-Object { $_.Trim() -and $_ -notmatch '^\s*(cd\s.*|do|done|then|else|fi|[{}])\s*$' })
    return [math]::Max(1, $parts.Count)
}

# The numbers of one run log's text. A request comes as several assistant lines, one for each content block, under one
# message id; its usage is on each, the last one's counts. A subagent's lines (parent_tool_use_id) are not the run's.
# The user lines are never parsed: they hold the tool results, the large part of a log. A result line starts with
# another key in newer Claude Code ({"duration_api_ms"...), so it is found by its type. advisorCost is the result's cost
# of each model other than the run's own (the init line's model): the whole session's, the part before a pause too.
# An advisor of the run's own model has no cost of its own in the result: advisorCost is then 0.
# A line Windows PowerShell cannot parse (keys that differ only in case) is left out. commands: the tool calls, a Bash
# call counted as the commands it chains (Get-CommandCount).
function Get-RunNumbers([string] $text) {
    $context = [ordered]@{}
    $read = @{}
    $write = @{}
    $toolCalls = 0
    $commands = 0
    $advisorCalls = 0
    $compactions = 0
    $model = ''
    $result = $null
    foreach ($line in $text -split "`n") {
        if ($line.StartsWith('{"type":"user"')) {
            continue
        }
        if ($line.StartsWith('{"type":"system"')) {
            if ($line -like '*"subtype":"compact_boundary"*') {
                $compactions++
            } elseif (-not $model -and $line -like '*"subtype":"init"*') {
                try { $model = [string]($line | ConvertFrom-Json).model } catch { }
            }
            continue
        }
        $isAssistant = $line.StartsWith('{"type":"assistant"')
        if (-not $isAssistant -and $line -notlike '*"type":"result"*') {
            continue
        }
        try {
            $parsed = $line | ConvertFrom-Json
        } catch {
            continue
        }
        if (-not $isAssistant) {
            if ($parsed.type -eq 'result') {
                $result = $parsed
            }
            continue
        }
        if ($parsed.parent_tool_use_id -or -not $parsed.message.id) {
            continue
        }
        $id = $parsed.message.id
        $usage = $parsed.message.usage
        $read[$id] = [long]$usage.cache_read_input_tokens
        $write[$id] = [long]$usage.cache_creation_input_tokens
        $context[$id] = [long]$usage.input_tokens + $read[$id] + $write[$id]
        foreach ($block in @($parsed.message.content)) {
            if ($block.type -eq 'tool_use' -or $block.type -eq 'server_tool_use') {
                $toolCalls++
                $commands += if ($block.name -eq 'Bash') { Get-CommandCount ([string]$block.input.command) } else { 1 }
                if ($block.name -eq 'advisor') {
                    $advisorCalls++
                }
            }
        }
    }
    $sizes = @($context.Values)
    $advisorCost = 0.0
    if ($result -and $model) {
        foreach ($entry in @($result.modelUsage.PSObject.Properties)) {
            if ($entry.Name -ne $model) {
                $advisorCost += [double]$entry.Value.costUSD
            }
        }
    }
    return [ordered]@{
        requests = $sizes.Count
        toolCalls = $toolCalls
        commands = $commands
        first = $(if ($sizes.Count) { $sizes[0] } else { 0 })
        ctxMean = $(if ($sizes.Count) { [long][math]::Round(($sizes | Measure-Object -Sum).Sum / $sizes.Count) } else { 0 })
        ctxMax = $(if ($sizes.Count) { [long]($sizes | Measure-Object -Maximum).Maximum } else { 0 })
        read = [long]($read.Values | Measure-Object -Sum).Sum
        write = [long]($write.Values | Measure-Object -Sum).Sum
        compactions = $compactions
        advisorCalls = $advisorCalls
        advisorCost = $advisorCost
    }
}

# What a run did at one line of its log: its last words or the tool it last called. $null for a line that is no step.
function Get-StepText([string] $line) {
    try {
        $entry = $line | ConvertFrom-Json
    } catch {
        return $null
    }
    # A result line ends a turn, not the run: a run that waits on a background job gets one and goes on later.
    if ($entry.type -ne 'assistant' -or -not $entry.message.content) {
        return $null
    }
    $item = @($entry.message.content)[-1]
    if ($item.type -eq 'text' -and $item.text) {
        return [string]$item.text
    }
    if ($item.type -eq 'tool_use') {
        $toolInput = $item.input
        $detail = @($toolInput.description, $toolInput.command, $toolInput.file_path, $toolInput.pattern, $toolInput.action) |
            Where-Object { $_ } | Select-Object -First 1
        # An MCP tool's name `mcp__<Server>__<tool>` reads `<Server> <tool>`.
        return "$($item.name -replace '^mcp__(.+?)__', '$1 ')$(if ($detail) { ': ' + $detail })"
    }
    return $null
}

# A command start of the base (`git`, `unity command`) as a Claude Code tool rule: `Bash(git:*)`.
function ConvertTo-ToolRule([string] $start) {
    return "Bash($($start.Trim()):*)"
}

# The tool rules of a run: its commands as rules, then the rules that the project and its plugins give in Claude
# Code's own syntax, then every tool of each MCP server a plugin gives.
function Get-ToolRules($run) {
    $rules = @($run.Commands | Where-Object { $_ } | ForEach-Object { ConvertTo-ToolRule $_ }) + @($run.Tools | Where-Object { $_ })
    if ($run.McpServers) {
        $rules += @($run.McpServers.Keys | ForEach-Object { "mcp__$_" })
    }
    return @($rules | Select-Object -Unique)
}

# The command of a run, or with -Compact of the compaction of its session: @{ FilePath; Arguments; Env }. It writes
# the run's two files into the worker's queue folder: mcp.json (the plugins' MCP servers; always one, so only they
# load) and run-settings.json.
# - Claude Code's own commit and PR attribution off: a project's rules allow none. Claude Code's own skills and the
#   claude.ai account's off: 6,077 tokens less on every turn; the project's and the plugins' skills stay.
# - The tool rules as a list in the settings: a rule may hold a space (`Bash(unity command:*)`), and a comma-joined
#   --allowedTools value is not sure to keep such a rule whole.
# - The advisor on with the run's (the settings name its model), else off, also where the login's own settings name
#   one: a run of the queue gets only the queue's advisor. Each advisor call reads the whole session again, uncached.
# - The same arguments for the run and for its compaction: the cache holds only for the same model, tools and settings.
#   The cap (--max-budget-usd) and the compact window are the run's alone.
function Get-RunCommand($ctx, [switch] $Compact) {
    $run = $ctx.Run
    $mcpConfig = Join-Path $ctx.QueueDir 'mcp.json'
    $servers = if ($run.McpServers) { $run.McpServers } else { @{} }
    [System.IO.File]::WriteAllText($mcpConfig, (@{ mcpServers = $servers } | ConvertTo-Json -Depth 8 -Compress))
    $runSettings = Join-Path $ctx.QueueDir 'run-settings.json'
    $advisorSetting = if ($run.Advisor) { ",`"advisorModel`":`"$($run.Advisor)`"" } else { '' }
    $allow = ConvertTo-Json -InputObject @(Get-ToolRules $run) -Compress
    [System.IO.File]::WriteAllText($runSettings, '{"includeCoAuthoredBy":false,"attribution":{"commit":"","pr":""},' +
        '"disableBundledSkills":true,"syncClaudeAiSkills":false,' +
        '"permissions":{"allow":' + $allow + '}' + $advisorSetting + '}')
    $sessionArgs = @('--permission-mode', 'auto', '--mcp-config', "`"$mcpConfig`"",
        '--strict-mcp-config', '--settings', "`"$runSettings`"",
        '--disallowedTools', "`"$UnusedTools`"", '--output-format', 'stream-json', '--verbose',
        '--model', $run.Model)
    if ($run.Effort) {
        $sessionArgs += @('--effort', $run.Effort)
    }
    foreach ($dir in @($run.AddDirs | Where-Object { $_ })) {
        $sessionArgs += @('--add-dir', "`"$dir`"")
    }
    $variables = Get-LoginEnv ([string]$run.Login)
    $variables['CLAUDE_CODE_DISABLE_ADVISOR_TOOL'] = $(if ($run.Advisor) { $null } else { '1' })
    if ($Compact) {
        $arguments = @('-p', '/compact', '--resume', $run.Session) + $sessionArgs
    } else {
        $arguments = @('-p', "`"$($run.Prompt)`"") + $(if ($run.Session) { @('--resume', $run.Session) } else { @() }) + $sessionArgs
        if ($run.Cap) {
            $arguments += @('--max-budget-usd', [string]$run.Cap)
        }
        if ($run.CompactAt) {
            $variables['CLAUDE_CODE_AUTO_COMPACT_WINDOW'] = [string]([int]$run.CompactAt + $CompactLead)
        }
    }
    return @{ FilePath = (Get-Command claude).Source; Arguments = $arguments; Env = $variables }
}

@{
    # The login of a folder ('' for the command-line login), from its files: no process is started.
    GetLogin = {
        param($ctx)
        $login = [string]$ctx.Login
        $credentials = Read-Credentials $login
        $oauth = if ($credentials) { $credentials.claudeAiOauth } else { $null }
        return @{
            SignedIn = [bool]($oauth -and $oauth.refreshToken)
            Email = Get-LoginEmail $login
            Plan = Get-PlanName $credentials
            PlanSize = Get-PlanSize ([string]$(if ($oauth) { $oauth.rateLimitTier }))
            Stamp = Get-CredentialsStamp $login
        }
    }
    # `claude auth login` for the folder. It prints a sign-in link and waits for the code on its input; on a PC with a
    # browser it may finish alone.
    SignIn = {
        param($ctx)
        $emailArg = if ($ctx.Email) { " --email `"$($ctx.Email)`"" } else { '' }
        return @{ Command = "claude auth login$emailArg"; Env = (Get-LoginEnv ([string]$ctx.Login)) }
    }
    ReadSignIn = {
        param($ctx)
        $last = @([string]$ctx.Text -split "`n" | ForEach-Object { ($_ -replace '^.*prompted >', '').Trim() } | Where-Object { $_ })
        return @{ Url = [regex]::Match([string]$ctx.Text, 'https://\S*oauth/authorize\S*').Value; Message = $(if ($last) { $last[-1] } else { '' }) }
    }
    # Only a folder of its own: the command-line login is the owner's.
    SignOut = {
        param($ctx)
        if ($ctx.Login) {
            Invoke-WithEnv (Get-LoginEnv ([string]$ctx.Login)) { & claude auth logout | Out-Null }
        }
    }
    # One word from Haiku ($BareRequestArgs): it shows the account's usage (its rate_limit_event) and whether the
    # account takes requests. A refused one costs nothing.
    Probe = {
        param($ctx)
        $ErrorActionPreference = 'Continue'
        $text = Invoke-WithEnv (Get-LoginEnv ([string]$ctx.Login)) {
            (& claude -p 'Reply: ok' @BareRequestArgs --output-format stream-json --verbose 2>$null) -join "`n"
        } ([string]$ctx.Dir)
        $result = Read-Result ([string]$text)
        $kind = Get-Refusal $result
        return @{
            Usage = Read-UsageEvent ([string]$text) $false; Answered = [bool]$result
            # The Fable limit never refuses Haiku; a kind the base does not know would put the account out.
            Kind = $(if ($kind -eq 'fable') { 'limit' } else { $kind }); Text = [string]$(if ($result) { $result.result })
        }
    }
    GetCommand = {
        param($ctx)
        return Get-RunCommand $ctx
    }
    # `/compact` on the held session, with the run's own arguments. It returns a line for the worker's log.
    Compact = {
        param($ctx)
        $command = Get-RunCommand $ctx -Compact
        $log = [string]$ctx.Log
        return Invoke-WithEnv $command.Env {
            $process = Start-Process $command.FilePath -ArgumentList $command.Arguments -WorkingDirectory $ctx.Run.Dir -NoNewWindow `
                -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
            if (-not $process.WaitForExit(600000)) {
                $process.Kill()
                return 'no end after 10 minutes, stopped; the session resumes whole.'
            }
            $text = if (Test-Path $log) { [System.IO.File]::ReadAllText($log) } else { '' }
            $tokens = [regex]::Match($text, '"pre_tokens":(\d+),"post_tokens":(\d+)')
            if (-not $tokens.Success) {
                return 'failed; the session resumes whole.'
            }
            $cached = [regex]::Match($text, '"cacheReadInputTokens":(\d+)').Groups[1].Value
            return "the session went from $($tokens.Groups[1].Value) to $($tokens.Groups[2].Value) tokens, $cached read from the cache."
        }
    }
    ReadUsage = {
        param($ctx)
        return Read-UsageEvent ([string]$ctx.Text) ([bool]$ctx.First)
    }
    # The end of a run from its log: the session to resume, the result (its error, its refusal, its cost) and the
    # run's numbers for the history. A log the numbers cannot be read from loses only them.
    ReadRun = {
        param($ctx)
        $text = [string]$ctx.Text
        $result = Read-Result $text
        $run = @{
            Session = [regex]::Match($text, '"session_id":"([^"]+)"').Groups[1].Value; Ended = [bool]$result; Error = $false
            Kind = ''; Window = ''; Capped = $false; Text = ''; Worked = $false; Cost = 0.0; Numbers = $null
        }
        try {
            $run.Numbers = Get-RunNumbers $text
        } catch {
            & $ctx.Log "run numbers error: $_"
        }
        if ($result) {
            $run.Error = [bool]$result.is_error
            $run.Cost = [double]$result.total_cost_usd
            # A run refused at its first turn has no cost.
            $run.Worked = $run.Cost -ne 0
            $run.Capped = $result.subtype -eq 'error_max_budget_usd'
            $run.Text = [string]$result.result
            $kind = Get-Refusal $result
            if ($kind -eq 'fable') {
                $run.Kind = 'window'
                $run.Window = $FableWindow
            } else {
                $run.Kind = $kind
            }
        }
        return $run
    }
    ReadStep = {
        param($ctx)
        return Get-StepText ([string]$ctx.Line)
    }
    # Why a run ended, from the end of its log: an error with the subtype 'success' is a refused request, not a failed
    # step, so it has no detail.
    ReadEnd = {
        param($ctx)
        try {
            $result = Read-Result ([string]$ctx.Text)
        } catch {
            return $null
        }
        if (-not $result) {
            return $null
        }
        $detail = if ($result.subtype -and $result.subtype -ne 'success') { [string]$result.subtype } else { '' }
        return @{ Error = [bool]($result.is_error -or $detail); Detail = $detail; Text = [string]$result.result }
    }
}
