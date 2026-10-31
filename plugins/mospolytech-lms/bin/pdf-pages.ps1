# Renders PDF pages to PNG with the plugin's Typst (PowerShell tool on Windows), so Claude can look
# at a PDF (a finished report, a scanned assignment) without poppler.
# usage: pdf-pages.ps1 <file.pdf> <out-dir> [pages: 3 | 2-5 | all] [ppi, default 100]
# Writes <out-dir>\page-<N>.png and prints their paths.
$ErrorActionPreference = 'Stop'

if ($args.Count -lt 2) { [Console]::Error.WriteLine('usage: pdf-pages.ps1 <file.pdf> <out-dir> [3 | 2-5 | all] [ppi]'); exit 2 }
$pdf = $args[0]
$out = $args[1]
$range = if ($args.Count -gt 2) { [string]$args[2] } else { 'all' }
$ppi = if ($args.Count -gt 3) { [string]$args[3] } else { '100' }
if (-not (Test-Path -PathType Leaf $pdf)) { [Console]::Error.WriteLine("pdf-pages: file not found: $pdf"); exit 1 }

$Data = $env:CLAUDE_PLUGIN_DATA
if (-not $Data) {
  $Data = Get-ChildItem -Directory (Join-Path $env:USERPROFILE '.claude\plugins\data') -Filter 'mospolytech-lms*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'bin\typst.exe') } | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Data) { [Console]::Error.WriteLine('pdf-pages: Typst не установлен — перезапустите сессию Claude Code, чтобы плагин его скачал'); exit 1 }

if ($range -eq 'all') { $first = 1; $last = 0 }
elseif ($range -match '^(\d+)-(\d+)$') { $first = [int]$Matches[1]; $last = [int]$Matches[2] }
elseif ($range -match '^\d+$') { $first = [int]$range; $last = [int]$range }
else { [Console]::Error.WriteLine("pdf-pages: bad page range: $range"); exit 2 }
if ($first -lt 1) { [Console]::Error.WriteLine("pdf-pages: bad page range: $range"); exit 2 }

# Typst only reads files under --root, so the PDF goes into a scratch project next to the page source.
$work = Join-Path ([IO.Path]::GetTempPath()) ("pdf-pages-" + [guid]::NewGuid())
New-Item -ItemType Directory $work | Out-Null
New-Item -ItemType Directory -Force $out | Out-Null
$typst = Join-Path $Data 'bin\typst.exe'
try {
  Copy-Item $pdf (Join-Path $work 'in.pdf')
  $p = $first
  while ($true) {
    if ($last -ne 0 -and $p -gt $last) { break }
    # Windows PowerShell's Set-Content -Encoding UTF8 adds a BOM; write plain UTF-8 instead
    [IO.File]::WriteAllText((Join-Path $work 'page.typ'), "#set page(width: auto, height: auto, margin: 0pt)`n#image(`"in.pdf`", page: $p)", (New-Object Text.UTF8Encoding $false))
    $png = Join-Path $out "page-$p.png"
    $err = & $typst compile --root $work --ppi $ppi (Join-Path $work 'page.typ') $png 2>&1
    if ($LASTEXITCODE -ne 0) {
      # With "all" the first missing page ends the document; anything else is a real error.
      if ($last -eq 0 -and $p -gt 1) { break }
      [Console]::Error.WriteLine(($err | Out-String))
      exit 1
    }
    Write-Output $png
    $p++
    if ($last -eq 0 -and $p -gt 200) { [Console]::Error.WriteLine('pdf-pages: stopped after 200 pages'); break }
  }
}
finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
