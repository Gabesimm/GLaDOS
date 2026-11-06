$env:OPENCLAW_STATE_DIR = Join-Path $PSScriptRoot 'openclaw'
$env:OPENCLAW_CONFIG_PATH = Join-Path $env:OPENCLAW_STATE_DIR 'openclaw.json'
$env:OLLAMA_MODELS = Join-Path $PSScriptRoot 'ollama\models'
$env:OLLAMA_CONTEXT_LENGTH = '32768'
$env:PATH = (Join-Path $PSScriptRoot 'node') + ';' + (Join-Path $env:USERPROFILE '.local\bin') + ';' + (Join-Path $env:APPDATA 'npm') + ';' + $env:PATH
# Restrict this child process to subscription logins. Do not modify saved user environment.
foreach ($key in @('OPENAI_API_KEY','CODEX_API_KEY','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','OPENROUTER_API_KEY')) {
    [Environment]::SetEnvironmentVariable($key, $null, 'Process')
}
$tokenPath = Join-Path $env:OPENCLAW_STATE_DIR 'gateway.token'
if (Test-Path -LiteralPath $tokenPath) { $env:GLADOS_GATEWAY_TOKEN = [IO.File]::ReadAllText($tokenPath).Trim() }
