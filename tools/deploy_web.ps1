$ErrorActionPreference = 'Stop'

Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host "Building Flutter web (base-href /app/)…"
flutter build web --release --base-href /app/

$dest = Join-Path $PWD "public\app"
$src = Join-Path $PWD "build\web"

Write-Host "Refreshing Hosting web folder: $dest"
if (-not (Test-Path $dest)) {
  New-Item -ItemType Directory -Path $dest | Out-Null
}

Write-Host "Mirroring build output…"
robocopy $src $dest /MIR /NFL /NDL /NJH /NJS /NP | Out-Host
if ($LASTEXITCODE -ge 8) {
  throw "Robocopy failed with exit code $LASTEXITCODE"
}

Write-Host "Deploying Firebase Hosting…"
firebase deploy --only hosting

Write-Host "Done. Web app should be at https://simple-distributed-database.web.app/app/"
