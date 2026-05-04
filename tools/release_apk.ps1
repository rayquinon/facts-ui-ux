$ErrorActionPreference = 'Stop'

Set-Location (Split-Path $PSScriptRoot -Parent)

$downloads = Join-Path $PWD "public\downloads"
$latest = Join-Path $downloads "app-latest.apk"
$latestArm64 = Join-Path $downloads "app-latest-arm64.apk"
$latestArmeabi = Join-Path $downloads "app-latest-armeabi-v7a.apk"
$latestX64 = Join-Path $downloads "app-latest-x86_64.apk"
$prev1 = Join-Path $downloads "app-prev1.apk"
$prev2 = Join-Path $downloads "app-prev2.apk"

$webOut = Join-Path $PWD "public\app"

$versionLine = Select-String -Path (Join-Path $PWD 'pubspec.yaml') -Pattern '^version:\s*(.+)$' | Select-Object -First 1
$versionRaw = if ($versionLine) { $versionLine.Matches[0].Groups[1].Value.Trim() } else { 'unknown' }
$versionSafe = ($versionRaw -replace '[^0-9A-Za-z\.-]+','-')
$latestVersioned = Join-Path $downloads "app-latest-$versionSafe.apk"
$latestArm64Versioned = Join-Path $downloads "app-latest-arm64-$versionSafe.apk"
$latestArmeabiVersioned = Join-Path $downloads "app-latest-armeabi-v7a-$versionSafe.apk"
$latestX64Versioned = Join-Path $downloads "app-latest-x86_64-$versionSafe.apk"

$manifestPath = Join-Path $downloads "version.json"

$versionName = $versionRaw
$buildNumber = 0
if ($versionRaw -match '^(.+?)\+(\d+)$') {
  $versionName = $Matches[1]
  $buildNumber = [int]$Matches[2]
}

Write-Host "Building Flutter Android release APKs (split-per-ABI)…"
flutter build apk --release --split-per-abi --build-name $versionName --build-number $buildNumber

$apkDir = Join-Path $PWD "build\app\outputs\flutter-apk"
$srcArm64 = Join-Path $apkDir "app-arm64-v8a-release.apk"
$srcArmeabi = Join-Path $apkDir "app-armeabi-v7a-release.apk"
$srcX64 = Join-Path $apkDir "app-x86_64-release.apk"

if (!(Test-Path $srcArm64)) { throw "Build output not found: $srcArm64" }
if (!(Test-Path $srcArmeabi)) { throw "Build output not found: $srcArmeabi" }
if (!(Test-Path $srcX64)) { throw "Build output not found: $srcX64" }

Write-Host "Building universal APK (fallback)…"
flutter build apk --release --build-name $versionName --build-number $buildNumber
$srcUniversal = Join-Path $apkDir "app-release.apk"
if (!(Test-Path $srcUniversal)) {
  throw "Build output not found: $srcUniversal"
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
Copy-Item -Force $srcUniversal $latest
Copy-Item -Force $srcArm64 $latestArm64
Copy-Item -Force $srcArmeabi $latestArmeabi
Copy-Item -Force $srcX64 $latestX64

Write-Host "Publishing version-stamped APKs ($versionRaw)…"
Copy-Item -Force $srcUniversal $latestVersioned
Copy-Item -Force $srcArm64 $latestArm64Versioned
Copy-Item -Force $srcArmeabi $latestArmeabiVersioned
Copy-Item -Force $srcX64 $latestX64Versioned

$cacheBust = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')

Write-Host "Writing update manifest: $manifestPath"
$manifest = @{
  latestBuildNumber = $buildNumber
  latestVersionName = $versionName
  # Use version-stamped URLs to avoid client/CDN caching returning an older APK.
  apkUrl = "https://facts.shiro.codes/downloads/app-latest-$versionSafe.apk?v=$cacheBust"
  arm64Url = "https://facts.shiro.codes/downloads/app-latest-arm64-$versionSafe.apk?v=$cacheBust"
  armeabiUrl = "https://facts.shiro.codes/downloads/app-latest-armeabi-v7a-$versionSafe.apk?v=$cacheBust"
  x64Url = "https://facts.shiro.codes/downloads/app-latest-x86_64-$versionSafe.apk?v=$cacheBust"
  androidPageUrl = 'https://facts.shiro.codes/android/'

  # Fallback URLs (same hosting site, alternate domain).
  apkUrlAlt = "https://simple-distributed-database.web.app/downloads/app-latest-$versionSafe.apk?v=$cacheBust"
  arm64UrlAlt = "https://simple-distributed-database.web.app/downloads/app-latest-arm64-$versionSafe.apk?v=$cacheBust"
  armeabiUrlAlt = "https://simple-distributed-database.web.app/downloads/app-latest-armeabi-v7a-$versionSafe.apk?v=$cacheBust"
  x64UrlAlt = "https://simple-distributed-database.web.app/downloads/app-latest-x86_64-$versionSafe.apk?v=$cacheBust"
  androidPageUrlAlt = 'https://simple-distributed-database.web.app/android/'

  updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
}

$manifestJson = $manifest | ConvertTo-Json -Depth 4
# PowerShell 5.1 writes UTF-8 with BOM by default, which can break strict JSON
# decoders (e.g., Dart's jsonDecode). Write UTF-8 *without* BOM.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)

Write-Host "Building Flutter web release…"
flutter build web --release --base-href /app/

Write-Host "Publishing web build to: $webOut"
if (!(Test-Path $webOut)) {
  New-Item -ItemType Directory -Path $webOut | Out-Null
}

# Clear previous web output but keep folder.
Get-ChildItem -Path $webOut -Force | Remove-Item -Recurse -Force

$srcWeb = Join-Path $PWD "build\web\*"
Copy-Item -Recurse -Force $srcWeb $webOut

Write-Host "Deploying Firebase Hosting + Firestore rules…"
firebase deploy --only "hosting,firestore:rules"

Write-Host "Done. Latest APK: https://facts.shiro.codes/downloads/app-latest.apk"
Write-Host "Done. Versioned APK: https://facts.shiro.codes/downloads/app-latest-$versionSafe.apk"