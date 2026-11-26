# Checks plugin.ps1 with made-up logs and logins and a stand-in for the claude command: no Claude Code, no network.
#   powershell -NoProfile -ExecutionPolicy Bypass -File plugin.test.ps1 (prints ok or throws).
$ErrorActionPreference = 'Stop'

function Assert-Equal($actual, $expected, [string] $what) {
    if ("$actual" -ne "$expected") {
        throw "${what}: expected '$expected', got '$actual'"
    }
}

# Loaded as the base loads a plugin (Scriptorium's docs/PLUGINS.md): in a module of its own.
$module = New-Module -ArgumentList (Join-Path $PSScriptRoot 'plugin.ps1') -ScriptBlock {
    param($file)
    $Hooks = . $file
    Export-ModuleMember -Variable Hooks
}
$hooks = & $module { $Hooks }
# One of the plugin's own functions, by name.
function Call([string] $name) {
    return & $module { param($name, $list) & $name @list } $name $args
}
function Result([string] $json) {
    return $json | ConvertFrom-Json
}

$said = New-Object System.Collections.ArrayList
$root = Join-Path ([IO.Path]::GetTempPath()) "scriptorium-claude-test-$PID"
$queue = Join-Path $root 'queue'
New-Item -ItemType Directory -Force $queue | Out-Null
function New-Context($fields = @{}) {
    $ctx = @{ Api = 1; Project = $root; Copy = $root; Worker = 1; QueueDir = $queue; Settings = @{}
        Report = { param($text) [void]$said.Add($text) }; Log = { param($text) [void]$said.Add($text) } }
    foreach ($key in $fields.Keys) {
        $ctx[$key] = $fields[$key]
    }
    return $ctx
}

try {
    # The manifest and the model list: a provider, with the windows the usage events name.
    $manifest = Get-Content (Join-Path $PSScriptRoot 'plugin.json') -Raw | ConvertFrom-Json
    Assert-Equal "$($manifest.name) $($manifest.api) $($manifest.provider) $($manifest.skills)" 'claude 1 True .claude/skills' 'the manifest'
    Assert-Equal (Test-Path (Join-Path $PSScriptRoot $manifest.card) -PathType Leaf) $true 'the picture behind the account cards'
    $models = Get-Content (Join-Path $PSScriptRoot 'models.json') -Raw | ConvertFrom-Json
    Assert-Equal (($models.windows.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') 'five_hour,seven_day,seven_day_overage_included' 'the windows'
    Assert-Equal "$($models.windows.seven_day_overage_included.models) $($models.windows.seven_day.keep)" '*fable* True' 'the Fable week holds Fable alone, and the week keeps'
    $named = @($models.complexities.PSObject.Properties | ForEach-Object { $_.Value.models }) + @($models.windows.seven_day_overage_included.after) + @($models.advisor.model) |
        ForEach-Object { ($_ -split '@')[0] }
    Assert-Equal @($named | Where-Object { -not $models.models.$_ }).Count 0 'every model that the list names is in it'

    # The run's numbers. A run on Opus with the Fable advisor: request 1 on two lines (the last one's usage counts), a
    # subagent's request, request 2 with the advisor and a read, a compaction, request 3 with text only, and two
    # results, the last the session's whole, in the shape of Claude Code 2.1.323 (the result line does not start with
    # its type).
    $log = @(
        '{"type":"system","subtype":"init","model":"claude-opus-5-5","tools":["Bash","Read"],"session_id":"s-7"}'
        '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m1","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"parent_tool_use_id":null}'
        '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cd src && grep -n ''a; b'' x.cs | head; cat <<''EOF'' > f\nx; y\nEOF\nls"}}],"usage":{"input_tokens":2,"cache_creation_input_tokens":30000,"cache_read_input_tokens":0}},"parent_tool_use_id":null}'
        '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"{\"type\":\"result\"}"}]},"parent_tool_use_id":null}'
        '{"type":"assistant","message":{"model":"claude-haiku-5-5","id":"s1","content":[{"type":"tool_use","id":"t9","name":"Grep","input":{}}],"usage":{"input_tokens":9,"cache_creation_input_tokens":9000,"cache_read_input_tokens":0}},"parent_tool_use_id":"t0"}'
        '{"type":"rate_limit_event","rate_limit_info":{}}'
        '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m2","content":[{"type":"server_tool_use","id":"a1","name":"advisor","input":{}}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"parent_tool_use_id":null}'
        '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m2","content":[{"type":"advisor_tool_result","tool_use_id":"a1"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"parent_tool_use_id":null}'
        '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m2","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2000,"cache_read_input_tokens":30000}},"parent_tool_use_id":null}'
        '{"duration_api_ms":1,"type":"result","subtype":"success","total_cost_usd":1.0,"modelUsage":{"claude-opus-5-5":{"costUSD":1.0}}}'
        '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto"}}'
        '{"type":"assistant","message":{"model":"claude-opus-5-5","id":"m3","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":10000,"cache_read_input_tokens":5000}},"parent_tool_use_id":null}'
        '{"duration_api_ms":2,"type":"result","subtype":"success","is_error":false,"total_cost_usd":3.75,"result":"done","modelUsage":{"claude-opus-5-5":{"costUSD":2.5},"claude-fable-5-2":{"costUSD":1.25}}}'
    ) -join "`n"
    $end = & $hooks.ReadRun (New-Context @{ Text = $log })
    $numbers = $end.Numbers
    Assert-Equal "$($end.Session) $($end.Ended) $($end.Error) '$($end.Kind)' $($end.Capped) $($end.Worked) $($end.Cost) $($end.Text)" "s-7 True False '' False True 3.75 done" 'the end of a run that finished'
    Assert-Equal $numbers.requests 3 'requests: distinct message ids of the main session'
    Assert-Equal $numbers.toolCalls 3 'tool calls: the advisor counts, a subagent call does not'
    Assert-Equal $numbers.commands 5 'commands: the Bash call chains 3 (cd, the quoted ; and the here-document are none)'
    Assert-Equal (Call Get-CommandCount 'cd src') 1 'a call counts as 1 command at least'
    Assert-Equal (Call Get-CommandCount "for f in a b; do`n  wc -l `$f || true`ndone; ls | head") 4 'the words of a loop are no command'
    Assert-Equal (Call Get-CommandCount 'echo "it''s a"; ls; echo "b''s"') 3 'an apostrophe inside double quotes opens no quote'
    Assert-Equal $numbers.first 30002 'first request: the last line of its id'
    Assert-Equal $numbers.ctxMean 25669 'mean context of 30002, 32001 and 15003'
    Assert-Equal $numbers.ctxMax 32001 'largest context'
    Assert-Equal $numbers.read 35000 'cache reads'
    Assert-Equal $numbers.write 42000 'cache writes'
    Assert-Equal $numbers.compactions 1 'compactions'
    Assert-Equal $numbers.advisorCalls 1 'advisor calls'
    Assert-Equal $numbers.advisorCost 1.25 "the last result's cost of the models other than the run's own"
    # The init line names the run's own model as modelUsage does, a 1M context one too; without it no advisor cost.
    $own = '{"type":"system","subtype":"init","model":"claude-opus-5-5[1m]"}' + "`n" +
        '{"type":"result","total_cost_usd":3.0,"modelUsage":{"claude-opus-5-5[1m]":{"costUSD":3.0}}}'
    Assert-Equal (Call Get-RunNumbers $own).advisorCost 0 'a 1M context model is the run own'
    Assert-Equal (Call Get-RunNumbers ($log -replace '"subtype":"init"', '"subtype":"other"')).advisorCost 0 'no init line'
    Assert-Equal (Call Get-RunNumbers '').requests 0 'an empty log'
    $none = & $hooks.ReadRun (New-Context @{ Text = '{"type":"system","subtype":"init","session_id":"s-8"}' })
    Assert-Equal "$($none.Session) $($none.Ended) $($none.Worked)" 's-8 False False' 'a log with no result: the process died'

    # Get-Refusal: why a run that ended with an error is not its ticket's failure, from its result line. The first
    # three lines are real, cut to the fields the function reads: a subscription that ended at a run's first turn, the
    # same after hours of work, and a session to resume that is gone.
    $past = 'Claude Code can''t use your Claude subscription, usually because a payment is past due - Pay or renew at https://claude.ai/settings/billing (if you just paid, try again shortly), or use an Anthropic API key instead'
    Assert-Equal (Call Get-Refusal (Result ('{"type":"result","subtype":"success","is_error":true,"total_cost_usd":0,"terminal_reason":"api_error","result":"' + $past + '"}'))) 'subscription' 'a refused subscription at the first turn'
    Assert-Equal (Call Get-Refusal (Result ('{"type":"result","subtype":"success","is_error":true,"total_cost_usd":25.587907799999993,"result":"' + $past + '"}'))) 'subscription' 'a refused subscription that cuts a run off'
    Assert-Equal (Call Get-Refusal (Result '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"total_cost_usd":0}')) '' 'a session to resume that is gone is the failure of the run'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":0,"result":"Not logged in - Please run /login"}')) 'login' 'a folder with no login'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"OAuth token has expired"}')) 'login' 'a login lost while the run works'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":0,"result":"Fable 5.1 requires usage credits"}')) 'model' 'a model the plan does not include'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"You have hit your limit"}')) 'limit' 'the usage limit of the plan'
    # The Fable limit: the first line is real, with the same api_error as a plan without the model.
    $fable = 'You''ve reached your Fable limit. Switch to another model, or manage usage credits at https://claude.ai/settings/usage?from=cc_cli_limit_message, to continue.'
    Assert-Equal (Call Get-Refusal (Result ('{"subtype":"success","is_error":true,"total_cost_usd":15.48,"api_error":"model_requires_usage_credits","result":"' + $fable + '"}'))) 'fable' 'the Fable limit cuts a run off'
    Assert-Equal (Call Get-Refusal (Result ('{"subtype":"success","is_error":true,"total_cost_usd":0,"api_error":"model_requires_usage_credits","result":"' + $fable + '"}'))) 'fable' 'the Fable limit at the first turn'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"You''ve hit your Fable limit - resets 7pm"}')) 'fable' 'the other wording of the Fable limit'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"Fable limit reached - continuing on Opus 5.5 uses usage credits"}')) 'fable' 'the wording that ends limit reached'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":0,"result":"API Error: 529 Overloaded"}')) 'start' 'a run that did no work, for a cause the list does not know'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":true,"total_cost_usd":3.1,"result":"API Error: 529 Overloaded"}')) '' 'the same error after work is the failure of the run'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"error_max_turns","is_error":true,"total_cost_usd":3.1,"result":"Reached the turn limit."}')) '' 'a failure of the run itself'
    # The cap of one run (models.json, runCap) is never an account's refusal, whatever its text says.
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":60.4,"result":"Budget limit reached"}')) '' 'a run that reached its cap'
    Assert-Equal (Call Get-Refusal (Result '{"subtype":"success","is_error":false,"total_cost_usd":0,"result":"ok"}')) '' 'a probe that the account answered'
    Assert-Equal (Call Get-Refusal $null) '' 'no result line'
    # ReadRun gives the base its own kinds: the Fable limit is the limit of the Fable week, and a cap is no refusal.
    $end = & $hooks.ReadRun (New-Context @{ Text = '{"type":"result","subtype":"success","is_error":true,"total_cost_usd":15.48,"result":"' + $fable + '","session_id":"s-1"}' })
    Assert-Equal "$($end.Kind) $($end.Window) $($end.Error) $($end.Worked)" 'window seven_day_overage_included True True' 'the Fable limit as the base reads it'
    $end = & $hooks.ReadRun (New-Context @{ Text = '{"type":"result","subtype":"success","is_error":true,"total_cost_usd":0,"result":"Not logged in - Please run /login"}' })
    Assert-Equal "$($end.Kind) $($end.Worked) $($end.Text)" 'login False Not logged in - Please run /login' 'a refusal at the first turn did no work'
    $end = & $hooks.ReadRun (New-Context @{ Text = '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":60.4,"result":"Budget limit reached"}' })
    Assert-Equal "'$($end.Kind)' $($end.Capped) $($end.Cost)" "'' True 60.4" 'a run that reached its cap'

    # The usage from the rate limit events: the last one, or the first; only an event with the plan's windows. A
    # rejection names the window that refused.
    $events = @(
        '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":0,"unifiedWindows":{"five_hour":{"utilization":0.25,"resetsAt":1000},"seven_day":{"utilization":0.5,"resetsAt":9000}}}}'
        '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day_overage_included"}}'
        '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":1000,"unifiedWindows":{"five_hour":{"utilization":1.01,"resetsAt":1000},"seven_day":{"utilization":0.6,"resetsAt":9000},"seven_day_overage_included":{"utilization":0.3,"resetsAt":9500}}}}'
        '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}'
    ) -join "`n"
    $first = & $hooks.ReadUsage (New-Context @{ Text = $events; First = $true })
    $last = & $hooks.ReadUsage (New-Context @{ Text = $events })
    Assert-Equal "$($first.Windows.five_hour.Used) $($first.Windows.seven_day.ResetsAt) '$($first.Refused)' $($first.Windows.Count)" "0.25 9000 '' 2" 'the first reading'
    Assert-Equal "$($last.Windows.five_hour.Used) $($last.Windows.seven_day_overage_included.Used) $($last.Refused) $($last.RefusedResetsAt)" '1.01 0.3 five_hour 1000' 'the last reading with the plan''s windows, refused'
    Assert-Equal ($null -eq (& $hooks.ReadUsage (New-Context @{ Text = '{"type":"rate_limit_event","rate_limit_info":{}}' }))) $true 'no event with windows: no reading'
    $typeless = '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1,"resetsAt":5}}}}'
    Assert-Equal (& $hooks.ReadUsage (New-Context @{ Text = $typeless })).Refused 'account' 'a rejection that names no window is the account''s'

    # Steps: a tool call names the tool and what it does; words are as said (the base puts them in one line).
    $step = { param($line) & $hooks.ReadStep (New-Context @{ Line = $line }) }
    Assert-Equal (& $step '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git push","description":"Push the branch"}}]}}') 'Bash: Push the branch' 'tool step'
    Assert-Equal (& $step '{"type":"assistant","message":{"content":[{"type":"text","text":"Rungs pass."}]}}') 'Rungs pass.' 'text step'
    Assert-Equal (& $step '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__UnityMCP__manage_scene","input":{"action":"save"}}]}}') 'UnityMCP manage_scene: save' 'an MCP tool step'
    Assert-Equal (& $step '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"mcp__my_db__run_query","input":{}}]}}') 'my_db run_query' 'a server name with an underscore'
    Assert-Equal (& $step '{"type":"user"}') '' 'not a step'
    Assert-Equal (& $step '{"type":"result","stop_reason":"end_turn"}') '' 'a turn end is not a step'
    Assert-Equal (& $step 'not json') '' 'a line that is no JSON'
    # Why a run ended: its error with the subtype, a refused request without one, its last words; nothing with no result.
    $ended = { param($text) $end = & $hooks.ReadEnd (New-Context @{ Text = $text }); if ($end) { "$($end.Error)|$($end.Detail)|$($end.Text)" } }
    Assert-Equal (& $ended '{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Reached the turn limit."}') 'True|error_max_turns|Reached the turn limit.' 'a failed run'
    Assert-Equal (& $ended '{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}') 'True||Not logged in' 'a refused request'
    Assert-Equal (& $ended '{"type":"result","subtype":"success","is_error":false,"result":"I stop #7 here."}') 'False||I stop #7 here.' 'a run that ended by itself'
    Assert-Equal (& $ended '{"type":"assistant","message":{"content":[]}}') '' 'no result'

    # A login from its folder: signed in while it holds a refresh token, its plan from the tier, its email from the
    # profile file. The stamp changes with the credentials file.
    Assert-Equal (Call Get-PlanName (Result '{"claudeAiOauth":{"subscriptionType":"pro","rateLimitTier":"default_claude_ai"}}')) 'Pro' 'plan pro'
    Assert-Equal (Call Get-PlanName (Result '{"claudeAiOauth":{"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}')) 'Max 20x' 'plan max 20x'
    Assert-Equal "$(Call Get-PlanSize 'default_claude_ai') $(Call Get-PlanSize 'default_claude_max_5x') $(Call Get-PlanSize 'default_claude_max_20x')" '1 5 20' 'the size of Pro, Max 5x and Max 20x'
    $folder = Join-Path $root 'login'
    New-Item -ItemType Directory -Force $folder | Out-Null
    $login = & $hooks.GetLogin (New-Context @{ Login = $folder })
    Assert-Equal "$($login.SignedIn) '$($login.Email)' '$($login.Plan)' $($login.PlanSize) $($login.Stamp)" "False '' '' 1 0" 'a folder with no login'
    Set-Content (Join-Path $folder '.credentials.json') '{"claudeAiOauth":{"refreshToken":"made-up","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}' -Encoding utf8
    Set-Content (Join-Path $folder '.claude.json') '{"oauthAccount":{"emailAddress":"owner@example.com"},"OAuthAccount":1}' -Encoding utf8
    $login = & $hooks.GetLogin (New-Context @{ Login = $folder })
    Assert-Equal "$($login.SignedIn) $($login.Email) $($login.Plan) $($login.PlanSize) $($login.Stamp -ne '0')" 'True owner@example.com Max 5x 5 True' 'a signed-in folder'
    Set-Content (Join-Path $folder '.credentials.json') '{"claudeAiOauth":{}}' -Encoding utf8
    Assert-Equal (& $hooks.GetLogin (New-Context @{ Login = $folder })).SignedIn $false 'credentials with no refresh token are signed out'

    # The sign-in: the command for the folder, and what its output says.
    $start = & $hooks.SignIn (New-Context @{ Login = $folder; Email = 'owner@example.com' })
    Assert-Equal "$($start.Command) | $($start.Env.CLAUDE_CONFIG_DIR -eq $folder)" 'claude auth login --email "owner@example.com" | True' 'the sign-in of a folder'
    $start = & $hooks.SignIn (New-Context @{ Login = ''; Email = '' })
    Assert-Equal "$($start.Command) | $($start.Env.ContainsKey('CLAUDE_CONFIG_DIR')) $($null -eq $start.Env.CLAUDE_CONFIG_DIR)" 'claude auth login | True True' 'the command-line login takes the variable away'
    $read = & $hooks.ReadSignIn (New-Context @{ Text = "Open this link:`nhttps://claude.ai/oauth/authorize?code=1&x=2 `nPaste code here if prompted > `n" })
    Assert-Equal "$($read.Url) | $($read.Message)" 'https://claude.ai/oauth/authorize?code=1&x=2 | https://claude.ai/oauth/authorize?code=1&x=2' 'the sign-in link'
    Assert-Equal (& $hooks.ReadSignIn (New-Context @{ Text = "Paste code here if prompted > Login failed: bad code`n" })).Message 'Login failed: bad code' 'the last line without the prompt'

    # A stand-in for the claude command, first on the PATH: the hooks name its path and never start it.
    $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force $bin | Out-Null
    if ($env:OS -eq 'Windows_NT') {
        Set-Content (Join-Path $bin 'claude.cmd') '@echo off' -Encoding ascii
        $env:PATH = "$bin;$env:PATH"
    } else {
        Set-Content (Join-Path $bin 'claude') '#!/bin/sh' -Encoding ascii
        & chmod +x (Join-Path $bin 'claude')
        $env:PATH = "${bin}:$env:PATH"
    }

    # The command of a run: the prompt, the session to resume, the run's two files, the model, the effort, the other
    # folder, the cap; the login, the advisor switch and the compact window as variables.
    $run = @{
        Prompt = 'Do ticket #5.'; Session = ''; Model = 'claude-opus-5-5'; Effort = 'high'; Advisor = 'claude-fable-5-2'; CompactAt = 250000; Cap = 60
        Login = $folder; Commands = @('git', 'gh', 'unity command'); Tools = @('Bash(dotnet:*)', 'mcp__Docs'); Dir = $root; AddDirs = @('D:/Work/App-w1')
        McpServers = [ordered]@{ Docs = @{ type = 'stdio'; command = 'docs' } }
    }
    # The plugin's own entry in scriptorium.json holds rules in Claude Code's syntax; one repeats a command's rule.
    $own = @{ allowedTools = ('{"allowedTools":["Bash(npm test:*)","Bash(git:*)"]}' | ConvertFrom-Json).allowedTools }
    $command = & $hooks.GetCommand (New-Context @{ Run = $run; Settings = $own })
    $mcp = Join-Path $queue 'mcp.json'
    $settingsFile = Join-Path $queue 'run-settings.json'
    Assert-Equal ((Split-Path $command.FilePath -Leaf) -replace '\.cmd$', '') 'claude' 'the claude command on the PATH'
    $expected = @('-p', '"Do ticket #5."', '--permission-mode', 'auto', '--mcp-config', "`"$mcp`"", '--strict-mcp-config', '--settings', "`"$settingsFile`"",
        '--disallowedTools', "`"$(& $module { $UnusedTools })`"", '--output-format', 'stream-json', '--verbose', '--model', 'claude-opus-5-5',
        '--effort', 'high', '--add-dir', '"D:/Work/App-w1"', '--max-budget-usd', '60') -join ' '
    Assert-Equal ($command.Arguments -join ' ') $expected 'the arguments of a run'
    Assert-Equal "$($command.Env.CLAUDE_CONFIG_DIR -eq $folder) $($null -eq $command.Env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL) $($command.Env.CLAUDE_CODE_AUTO_COMPACT_WINDOW)" 'True True 283000' 'the login, the advisor on and the compact window'
    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json
    Assert-Equal ($settings.permissions.allow -join ',') 'Bash(git:*),Bash(gh:*),Bash(unity command:*),Bash(npm test:*),Bash(dotnet:*),mcp__Docs' 'the commands as tool rules, the plugin''s own rules, the older form''s rules, each MCP server once'
    Assert-Equal "$($settings.advisorModel) $($settings.includeCoAuthoredBy) $($settings.disableBundledSkills) $($settings.syncClaudeAiSkills) '$($settings.attribution.commit)'" "claude-fable-5-2 False True False ''" 'the run''s settings'
    $servers = (Get-Content $mcp -Raw | ConvertFrom-Json).mcpServers
    Assert-Equal "$(@($servers.PSObject.Properties).Count) $($servers.Docs.command) $($servers.Docs.type)" '1 docs stdio' 'the MCP config'
    # A resumed run with no advisor, no effort, no cap and no compact size, on the command-line login.
    $bareRun = @{ Prompt = 'Go on.'; Session = 's-1'; Model = 'claude-opus-5-5'; Effort = ''; Advisor = ''; CompactAt = 0; Cap = 0; Login = ''
        Commands = @('git'); Tools = @(); Dir = $root; AddDirs = @(); McpServers = @{} }
    $command = & $hooks.GetCommand (New-Context @{ Run = $bareRun })
    Assert-Equal (($command.Arguments -join ' ') -replace [regex]::Escape($queue), 'Q' -replace '--disallowedTools "[^"]+"', '--disallowedTools T') ('-p "Go on." --resume s-1 --permission-mode auto --mcp-config "Q' + [IO.Path]::DirectorySeparatorChar + 'mcp.json" --strict-mcp-config --settings "Q' + [IO.Path]::DirectorySeparatorChar + 'run-settings.json" --disallowedTools T --output-format stream-json --verbose --model claude-opus-5-5') 'the arguments of a resumed run'
    Assert-Equal "$($null -eq $command.Env.CLAUDE_CONFIG_DIR) $($command.Env.CLAUDE_CODE_DISABLE_ADVISOR_TOOL) $($command.Env.ContainsKey('CLAUDE_CODE_AUTO_COMPACT_WINDOW'))" 'True 1 False' 'no login folder, the advisor off, no compact window'
    Assert-Equal (Get-Content $mcp -Raw) '{"mcpServers":{}}' 'an MCP config with no server'
    Assert-Equal ((Get-Content $settingsFile -Raw | ConvertFrom-Json).PSObject.Properties.Name -contains 'advisorModel') $false 'no advisor in the settings'

    # A probe: the base runs the command, and ReadProbe reads what it printed. The Fable limit counts as the plan's.
    $probe = & $hooks.GetProbe (New-Context @{ Login = $folder; Dir = $root })
    Assert-Equal "$((Split-Path $probe.FilePath -Leaf) -replace '\.cmd$', '') $($probe.Env.CLAUDE_CONFIG_DIR -eq $folder)" 'claude True' 'the probe command and its login'
    Assert-Equal ($probe.Arguments -join ' ') '-p "Reply: ok" --model haiku --tools= --system-prompt "Reply with one dot." --setting-sources=local --strict-mcp-config --disable-slash-commands --max-turns 1 --output-format stream-json --verbose' 'the arguments of a probe, with the quotes of each that holds a space'
    $probe = & $hooks.GetProbe (New-Context @{ Login = ''; Dir = $root })
    Assert-Equal "$($probe.Env.ContainsKey('CLAUDE_CONFIG_DIR')) $($null -eq $probe.Env.CLAUDE_CONFIG_DIR)" 'True True' 'a probe of the command-line login takes the variable away'
    $printed = @(
        '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":0,"unifiedWindows":{"five_hour":{"utilization":0.25,"resetsAt":1000},"seven_day":{"utilization":0.5,"resetsAt":9000}}}}'
        '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.001,"result":"ok","session_id":"s-1"}'
    ) -join "`n"
    $probe = & $hooks.ReadProbe (New-Context @{ Text = $printed })
    Assert-Equal "$($probe.Answered) '$($probe.Kind)' $($probe.Text) $($probe.Usage.Windows.five_hour.Used) $($probe.Usage.Windows.seven_day.ResetsAt)" "True '' ok 0.25 9000" 'a probe that the account answered'
    $probe = & $hooks.ReadProbe (New-Context @{ Text = '{"type":"result","subtype":"success","is_error":true,"total_cost_usd":0,"result":"' + $fable + '"}' })
    Assert-Equal "$($probe.Answered) $($probe.Kind) $($null -eq $probe.Usage)" 'True limit True' 'the Fable limit refuses a probe as the plan''s limit'
    $probe = & $hooks.ReadProbe (New-Context @{ Text = '' })
    Assert-Equal "$($probe.Answered) '$($probe.Kind)'" "False ''" 'a probe that printed nothing'

    # A compaction: the run's own arguments with /compact on the held session, and the line from what it printed.
    $held = @{} + $bareRun
    $held.Login = $folder
    $command = & $hooks.GetCompact (New-Context @{ Run = $held })
    Assert-Equal (($command.Arguments | Select-Object -First 4) -join ' ') '-p /compact --resume s-1' 'the compaction of the held session'
    Assert-Equal "$($command.Env.CLAUDE_CONFIG_DIR -eq $folder) $($command.Env.ContainsKey('CLAUDE_CODE_AUTO_COMPACT_WINDOW')) $(@($command.Arguments) -contains '--max-budget-usd')" 'True False False' 'no cap and no compact window for a compaction'
    $printed = '{"type":"system","subtype":"compact_boundary","compact_metadata":{"pre_tokens":900,"post_tokens":300},"usage":{"cacheReadInputTokens":800}}'
    Assert-Equal (& $hooks.ReadCompact (New-Context @{ Text = $printed })) 'the session went from 900 to 300 tokens, 800 read from the cache.' 'a compaction'
    Assert-Equal ($null -eq (& $hooks.ReadCompact (New-Context @{ Text = '{"type":"result","is_error":true}' }))) $true 'a compaction that failed gives no line'
    Assert-Equal "$($hooks.ContainsKey('Probe')) $($hooks.ContainsKey('Compact'))" 'False False' 'the base starts the probe and the compaction'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'ok'
