# Gets an LMS web-service token (asks for login and password in the terminal) and saves it to the
# plugin's secure settings. Run it yourself in PowerShell: Claude's tools have no TTY to prompt.
# usage: powershell -ExecutionPolicy Bypass -File login.ps1 [lms-url]
$ErrorActionPreference = 'Stop'

$Url = if ($args.Count -gt 0) { $args[0] } elseif ($env:CLAUDE_PLUGIN_OPTION_MOODLE_URL) { $env:CLAUDE_PLUGIN_OPTION_MOODLE_URL } else { 'https://online.mospolytech.ru' }
$Url = $Url.TrimEnd('/')

$Data = $env:CLAUDE_PLUGIN_DATA
if (-not $Data) {
  $Data = Get-ChildItem -Directory (Join-Path $env:USERPROFILE '.claude\plugins\data') -Filter 'mospolytech-lms*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'bin\moodle-mcp.exe') } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Data) {
  Write-Error 'moodle-mcp не установлен. Откройте Claude Code с включённым плагином mospolytech-lms — он скачает инструменты при старте — и запустите скрипт снова.'
}

Write-Host "Вход в LMS ${Url}: введите логин и пароль (пароль нигде не сохраняется)."
$out = & (Join-Path $Data 'bin\moodle-mcp.exe') auth --url $Url --output env
$m = $out | Select-String '^(export )?MOODLE_TOKEN=(.+)$' | Select-Object -First 1
if (-not $m) { Write-Error 'Не удалось получить токен.' }
$token = $m.Matches[0].Groups[2].Value.Trim('"', "'")

$values = @{ moodle_token = $token; moodle_url = $Url } | ConvertTo-Json -Compress
if (Get-Command claude -ErrorAction SilentlyContinue) {
  foreach ($id in 'mospolytech-lms@mospolytech', 'mospolytech-lms') {
    $values | claude plugin configure $id --values-stdin *> $null
    if ($LASTEXITCODE -eq 0) { Write-Host 'Токен сохранён в настройки плагина. Перезапустите сессию Claude Code.'; exit 0 }
  }
}

Write-Host ''
Write-Host 'Не получилось сохранить токен автоматически. Вставьте его вручную:'
Write-Host '/plugin → Installed → mospolytech-lms → Configure → «Токен LMS»'
Write-Host ''
Write-Host $token
