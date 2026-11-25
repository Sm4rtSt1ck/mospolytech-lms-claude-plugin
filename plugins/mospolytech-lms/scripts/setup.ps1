# Windows entry point for setup.sh: shows what the plugin has installed and sets up the optional
# parts (Telegram, student portal). The logic lives in setup.sh and runs in Git Bash, which the
# plugin's hooks need anyway, so both entry points behave the same.
# usage: powershell -ExecutionPolicy Bypass -File setup.ps1 [status|lms|telegram|lk [--down]]
$ErrorActionPreference = 'Stop'

$bash = $null
foreach ($c in @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))) {
  if ($c -and (Test-Path $c)) { $bash = $c; break }
}
if (-not $bash) {
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    $c = Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe'
    if (Test-Path $c) { $bash = $c }
  }
}
if (-not $bash) {
  Write-Error 'Не найден Git Bash. Установите Git for Windows (https://git-scm.com/download/win) — он нужен плагину — и запустите скрипт снова.'
}

$script = (Join-Path $PSScriptRoot 'setup.sh') -replace '\\', '/'
& $bash $script @args
exit $LASTEXITCODE
