$ErrorActionPreference = 'Stop'

Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host "Building Flutter web (base-href /app/)…"
flutter build web --release --base-href /app/

$dest = Join-Path $PWD "public\app"
$src = Join-Path $PWD "build\web"

Write-Host "Refreshing Hosting web folder: $dest"
if (Test-Path $dest) {
  Remove-Item -Recurse -Force $dest
}
New-Item -ItemType Directory -Path $dest | Out-Null

Write-Host "Copying build output…"
Copy-Item -Recurse -Force (Join-Path $src '*') $dest

Write-Host "Deploying Firebase Hosting + Firestore rules…"
firebase deploy --only "hosting,firestore:rules"

Write-Host "Done. Web app should be at https://simple-distributed-database.web.app/app/"
