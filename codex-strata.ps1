#Requires -Version 7.3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 aktsmm
# No param block: every argument belongs to Codex, including -c, -m, and --help.
$forwardedArgs = @($args)
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$mutex = $null
$ownsMutex = $false
$stdout = $null
$stderr = $null
$previousCodexHome = $env:CODEX_HOME

function Get-Setting([string]$Name, $Default) {
    $value = $settings.$Name
    if ($null -eq $value -or ($value -is [string] -and $value -eq '')) { return $Default }
    return $value
}

function Resolve-LocalPath([string]$Path, [string]$Base) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded, $Base)
}

function Get-StrataHealth {
    try { return Invoke-RestMethod -Uri $healthUrl -NoProxy -TimeoutSec 2 }
    catch { return $null }
}

function Assert-StrataHealth($Health) {
    if ($Health.service -ne 'strata' -or $Health.status -ne 'ok') {
        throw "Port $port is responding, but it is not a healthy Strata server. No process was replaced."
    }
    if ($Health.model -ne $expectedModel) {
        throw "Port $port serves '$($Health.model)', expected '$expectedModel'. No process was replaced."
    }
    if ($Health.api_key -and (-not $apiKeyEnv -or -not [Environment]::GetEnvironmentVariable($apiKeyEnv))) {
        throw 'Strata requires authentication. Set api_key_env and supply the matching key in that environment variable.'
    }
}

function Test-LocalPort {
    $client = [Net.Sockets.TcpClient]::new()
    try { return ($client.ConnectAsync('127.0.0.1', $port).Wait(500) -and $client.Connected) }
    catch { return $false }
    finally { $client.Dispose() }
}

function Ensure-Strata {
    $health = Get-StrataHealth
    if ($null -ne $health) {
        Assert-StrataHealth $health
        Write-Host '[codex-strata] Reusing the running Strata server.'
        return
    }
    $script:mutex = [Threading.Mutex]::new($false, "Local\CodexStrataAutoStart-$port")
    try { $script:ownsMutex = $mutex.WaitOne([TimeSpan]::FromSeconds($startupTimeout)) }
    catch [Threading.AbandonedMutexException] { $script:ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another launcher is still starting Strata. Try again shortly.' }
    try {
        $health = Get-StrataHealth
        if ($null -ne $health) { Assert-StrataHealth $health; return }
        if (Test-LocalPort) {
            throw "Port $port is occupied but /health is unavailable. No duplicate server was started."
        }
        $runnerPath = Join-Path $PSScriptRoot 'start-server.py'
        foreach ($path in @($pythonPath, $serverPath, $runnerPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required Strata file is missing: $path" }
        }
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        $stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID
        $script:stdout = Join-Path $logRoot "server-$stamp.stdout.log"
        $script:stderr = Join-Path $logRoot "server-$stamp.stderr.log"
        $serverArgs = @('-u', "`"$runnerPath`"", '--root', "`"$strataRoot`"", '--config', "`"$engineConfigPath`"", '--port', "$port", '--stdout', "`"$stdout`"", '--stderr', "`"$stderr`"")
        Write-Host "[codex-strata] Starting Strata on 127.0.0.1:$port..."
        # ShellExecute gives the hidden server its own handles. The Python runner
        # opens logs itself, so a caller capturing Codex output can still reach EOF.
        $server = Start-Process -FilePath $pythonPath -ArgumentList $serverArgs -WorkingDirectory $strataRoot -WindowStyle Hidden -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds($startupTimeout)
        while ([DateTime]::UtcNow -lt $deadline) {
            $health = Get-StrataHealth
            if ($null -ne $health) {
                Assert-StrataHealth $health
                Write-Host "[codex-strata] Ready (model loaded: $($health.loaded)). Logs: $logRoot"
                return
            }
            $server.Refresh()
            if ($server.HasExited) { throw "Strata exited before becoming ready (exit code $($server.ExitCode))." }
            Start-Sleep -Milliseconds 300
        }
        throw "Strata did not answer within $startupTimeout seconds. It was left running; inspect the logs before retrying."
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex(); $script:ownsMutex = $false }
    }
}

try {
    if (-not $IsWindows) { throw 'This launcher currently supports Windows only.' }
    $settingsPath = if ($env:CODEX_STRATA_CONFIG) { [IO.Path]::GetFullPath($env:CODEX_STRATA_CONFIG) } else { Join-Path $PSScriptRoot 'settings.json' }
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw 'Settings are missing. Run install.ps1 or copy settings.example.json to settings.json and set strata_root.'
    }
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $settingsBase = Split-Path -Parent $settingsPath
    if (-not $settings.strata_root) { throw 'strata_root must be set in settings.json.' }
    $strataRoot = Resolve-LocalPath $settings.strata_root $settingsBase
    $engineConfigPath = Resolve-LocalPath (Get-Setting 'engine_config' 'strata-iq2_xs.json') $strataRoot
    $engineConfig = Get-Content -LiteralPath $engineConfigPath -Raw | ConvertFrom-Json
    $expectedModel = $engineConfig.model_name
    if (-not $expectedModel) { throw 'The Strata engine config must specify model_name.' }
    $model = [string](Get-Setting 'model' $expectedModel)
    $port = [int](Get-Setting 'port' $(if ($engineConfig.port) { $engineConfig.port } else { 8080 }))
    $startupTimeout = [int](Get-Setting 'startup_timeout_seconds' 180)
    $streamTimeout = [int](Get-Setting 'stream_idle_timeout_ms' 600000)
    $contextWindow = 32768
    for ($i = 0; $i -lt $engineConfig.args.Count - 1; $i++) {
        if ($engineConfig.args[$i] -eq '--max-context') { $contextWindow = [int]$engineConfig.args[$i + 1] }
    }
    $contextWindow = [int](Get-Setting 'context_window' $contextWindow)
    $effort = [string](Get-Setting 'reasoning_effort' 'medium')
    if ($port -lt 1 -or $port -gt 65535) { throw 'port must be between 1 and 65535.' }
    if ($startupTimeout -lt 1 -or $startupTimeout -gt 600) { throw 'startup_timeout_seconds must be between 1 and 600.' }
    if ($contextWindow -lt 1 -or $streamTimeout -lt 1) { throw 'Context window and stream timeout must be positive.' }
    if ($effort -notin @('none', 'low', 'medium', 'high')) { throw 'Unsupported reasoning_effort.' }
    $apiKeyEnv = [string](Get-Setting 'api_key_env' '')
    if ($apiKeyEnv -and $apiKeyEnv -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'api_key_env must be an environment variable name.' }
    $stateRoot = Join-Path $env:LOCALAPPDATA 'codex-strata'
    $codexHome = Resolve-LocalPath (Get-Setting 'codex_home' (Join-Path $stateRoot 'codex-home')) $settingsBase
    $logRoot = Resolve-LocalPath (Get-Setting 'logs_dir' (Join-Path $stateRoot 'logs')) $settingsBase
    $pythonPath = Resolve-LocalPath (Get-Setting 'python_path' '.venv\Scripts\python.exe') $strataRoot
    $serverPath = Join-Path $strataRoot 'serve\server.py'
    $healthUrl = "http://127.0.0.1:$port/health"
    $codexCommand = [string](Get-Setting 'codex_command' 'codex')
    $codex = Get-Command $codexCommand -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $codex) { throw "Codex CLI was not found: $codexCommand. Install it or set codex_command to its executable path." }
    if ($null -ne $settings.codex_args_prefix -and $settings.codex_args_prefix -isnot [array]) {
        throw 'codex_args_prefix must be an array of strings.'
    }
    $codexPrefix = @(Get-Setting 'codex_args_prefix' @())
    foreach ($argument in $codexPrefix) {
        if ($argument -isnot [string]) { throw 'codex_args_prefix must be an array of strings.' }
    }
    if ([IO.Path]::GetExtension($codex.Source) -in @('.cmd', '.bat')) {
        # Bypass npm's batch shim: cmd.exe can interpret literal prompt text as
        # commands or expand %VARIABLES%, even with native argument quoting.
        $binDir = Split-Path -Parent $codex.Source
        $npmEntry = Join-Path $binDir 'node_modules\@openai\codex\bin\codex.js'
        if ([IO.Path]::GetFileName($codex.Source) -ne 'codex.cmd' -or -not (Test-Path -LiteralPath $npmEntry -PathType Leaf)) {
            throw 'Custom batch launchers cannot safely forward arbitrary prompts. Configure a native Codex executable, or node.exe with codex_args_prefix pointing to codex.js.'
        }
        $nodePath = Join-Path $binDir 'node.exe'
        $node = Get-Command $nodePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $node) { $node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if (-not $node) { throw 'Node.js was not found for the npm Codex installation.' }
        $codex = $node
        $codexPrefix = @($npmEntry) + $codexPrefix
    }
    $env:CODEX_HOME = $codexHome
    # Global help/version do not start Strata or generate state files.
    if ($forwardedArgs.Count -eq 1 -and $forwardedArgs[0] -in @('--help', '-h', '--version', '-V')) {
        & $codex.Source @codexPrefix @forwardedArgs
        exit $LASTEXITCODE
    }
    Ensure-Strata
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $catalogPath = Join-Path $codexHome 'codex-strata-models.json'
    $catalog = @{ models = @(@{
        slug = $model; display_name = "$model (Strata)"; description = 'Local model served by Strata.'
        default_reasoning_level = $effort; supported_reasoning_levels = @('none', 'low', 'medium', 'high') | ForEach-Object { @{ effort = $_; description = $_ } }
        shell_type = 'shell_command'; visibility = 'list'; supported_in_api = $true; priority = 1; upgrade = $null
        include_skills_usage_instructions = $false; include_plugin_usage_instructions = $false; include_apps_usage_instructions = $false
        default_reasoning_summary = 'none'; support_verbosity = $false; apply_patch_tool_type = 'freeform'
        truncation_policy = @{ mode = 'tokens'; limit = 10000 }; supports_parallel_tool_calls = $true
        supports_image_detail_original = $false; context_window = $contextWindow; max_context_window = $contextWindow
        effective_context_window_percent = 90; experimental_supported_tools = @(); input_modalities = @('text')
        supports_search_tool = $false; use_responses_lite = $false
        base_instructions = 'You are a local coding agent. Inspect relevant files before editing, follow applicable instructions, keep changes focused, validate your work, and report results.'
    }) }
    $catalogJson = $catalog | ConvertTo-Json -Depth 8
    # Atomic replacement prevents concurrent launchers from reading partial JSON.
    $tempCatalog = "$catalogPath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempCatalog, $catalogJson, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tempCatalog, $catalogPath, $true)
    } finally {
        if (Test-Path -LiteralPath $tempCatalog) { Remove-Item -LiteralPath $tempCatalog }
    }
    $codexArgs = @('-m', $model, '-c', 'model_provider=strata', '-c', 'model_providers.strata.name=Strata', '-c', "model_providers.strata.base_url=http://127.0.0.1:$port/v1", '-c', 'model_providers.strata.wire_api=responses', '-c', "model_providers.strata.stream_idle_timeout_ms=$streamTimeout", '-c', "model_context_window=$contextWindow", '-c', "model_reasoning_effort=$effort", '-c', "model_catalog_json=$catalogPath")
    if ($apiKeyEnv) { $codexArgs += @('-c', "model_providers.strata.env_key=$apiKeyEnv") }
    & $codex.Source @codexPrefix @codexArgs @forwardedArgs
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("[codex-strata] $($_.Exception.Message)")
    foreach ($log in @($stderr, $stdout)) {
        if ($log) { [Console]::Error.WriteLine("Startup log: $log") }
    }
    exit 1
} finally {
    $env:CODEX_HOME = $previousCodexHome
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
