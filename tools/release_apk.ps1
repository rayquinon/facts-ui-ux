$ErrorActionPreference = 'Stop'

Set-Location (Split-Path $PSScriptRoot -Parent)

$downloads = Join-Path $PWD "public\downloads"
$latest = Join-Path $downloads "app-latest.apk"
$prev1 = Join-Path $downloads "app-prev1.apk"
$prev2 = Join-Path $downloads "app-prev2.apk"

Write-Host "Building Flutter Android release APK…"
flutter build apk --release

$srcApk = Join-Path $PWD "build\app\outputs\flutter-apk\app-release.apk"
if (!(Test-Path $srcApk)) {
  throw "Build output not found: $srcApk"
}

Write-Host "Ensuring downloads folder exists: $downloads"
if (!(Test-Path $downloads)) {
  New-Item -ItemType Directory -Path $downloads | Out-Null
}

Write-Host "Rotating hosted APKs (keep latest + 2 previous)…"
if (Test-Path $prev1) {
  Copy-Item -Force $prev1 $prev2
}
if (Test-Path $latest) {
  Copy-Item -Force $latest $prev1
}

Write-Host "Publishing new latest APK…"
Copy-Item -Force $srcApk $latest

Write-Host "Deploying Firebase Hosting…"
firebase deploy --only hosting

Write-Host "Done. Latest APK: https://simple-distributed-database.web.app/downloads/app-latest.apk"