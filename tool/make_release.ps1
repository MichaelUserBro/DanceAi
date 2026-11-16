# Собирает готовые версии и кладёт их в releases/ (в git не попадает).
# В releases/ всегда только последняя версия: старые файлы удаляются.
#
# Запуск из корня проекта:
#   powershell -ExecutionPolicy Bypass -File tool\make_release.ps1
#
# Результат:
#   releases\DanceAI-<версия>-android.apk         — полный APK (любой телефон)
#   releases\DanceAI-<версия>-android-arm64.apk   — для большинства телефонов
#   releases\DanceAI-<версия>-windows.zip         — папка Windows целиком
#   releases\VERSION.txt                          — версия, коммит, дата

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Версия: из pubspec.yaml + короткий хеш коммита.
$pubVersion = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$name = ($pubVersion -split '\+')[0]
$commit = (git rev-parse --short HEAD).Trim()
$dirty = (git status --porcelain --untracked-files=no)
if ($dirty) {
    Write-Warning 'Есть незакоммиченные изменения — версия будет помечена как -dirty.'
    $commit = "$commit-dirty"
}
$version = "$name-$commit"
Write-Host "Версия: $version"

Write-Host 'Сборка Windows...'
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Сборка Windows не удалась' }

Write-Host 'Сборка Android (полный APK)...'
flutter build apk --release
if ($LASTEXITCODE -ne 0) { throw 'Сборка APK не удалась' }
$fullApk = Join-Path $env:TEMP "danceai-full-$commit.apk"
Copy-Item build\app\outputs\flutter-apk\app-release.apk $fullApk -Force

Write-Host 'Сборка Android (по архитектурам)...'
flutter build apk --release --split-per-abi
if ($LASTEXITCODE -ne 0) { throw 'Сборка APK по архитектурам не удалась' }

# Только теперь, когда всё собралось, заменяем старые версии.
$out = Join-Path $root 'releases'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory $out | Out-Null

Move-Item $fullApk (Join-Path $out "DanceAI-$version-android.apk")
Copy-Item build\app\outputs\flutter-apk\app-arm64-v8a-release.apk (Join-Path $out "DanceAI-$version-android-arm64.apk")
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath (Join-Path $out "DanceAI-$version-windows.zip")

$date = Get-Date -Format 'yyyy-MM-dd HH:mm'
@"
DanceAI $version
Коммит: $commit
Собрано: $date

DanceAI-$version-android.apk        — Android, любой телефон (все архитектуры)
DanceAI-$version-android-arm64.apk  — Android, большинство современных телефонов (меньше размер)
DanceAI-$version-windows.zip        — Windows 10/11 x64: распаковать папку целиком, запустить dance_ai.exe
"@ | Out-File (Join-Path $out 'VERSION.txt') -Encoding utf8

Write-Host "Готово: $out"
Get-ChildItem $out | Format-Table Name, @{n='МБ'; e={[math]::Round($_.Length / 1MB, 1)}}
