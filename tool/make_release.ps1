# Собирает готовые версии и кладёт их в releases/ (в git не попадает).
# В releases/ всегда только последняя версия: старые файлы удаляются.
#
# Запуск из корня проекта:
#   powershell -ExecutionPolicy Bypass -File tool\make_release.ps1
#   ... -SameVersion   — пересобрать с тем же versionCode (по умолчанию запрещено)
#
# Android APK подписываются release-ключом из android\key.properties
# (CLAUDE.md, раздел «Подпись»). Без него сборка останавливается.
# versionCode = число после «+» в version из pubspec.yaml; перед каждым
# релизом его нужно увеличить, иначе обновление поверх не встанет.
# Windows-сборка не подписывается (SmartScreen покажет предупреждение).
#
# Результат:
#   releases\DanceAI-<версия>-android.apk         — полный APK (любой телефон)
#   releases\DanceAI-<версия>-android-arm64.apk   — для большинства телефонов
#   releases\DanceAI-<версия>-windows.zip         — папка Windows целиком
#   releases\VERSION.txt                          — версия, коммит, дата

param([switch]$SameVersion)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# Версия: из pubspec.yaml + короткий хеш коммита.
$pubVersion = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$name = ($pubVersion -split '\+')[0]
$versionCode = [int](($pubVersion -split '\+')[1])
if ($versionCode -le 0) { throw 'В pubspec.yaml нет versionCode: нужен формат version: 1.2.3+N' }

# versionCode должен расти: сравниваем с прошлой сборкой из releases\VERSION.txt.
$prevInfo = Join-Path $root 'releases\VERSION.txt'
if (Test-Path $prevInfo) {
    $m = Select-String -Path $prevInfo -Pattern 'versionCode:\s*(\d+)'
    if ($m) {
        $prevCode = [int]$m.Matches[0].Groups[1].Value
        if ($versionCode -lt $prevCode -or ($versionCode -eq $prevCode -and -not $SameVersion)) {
            throw "versionCode $versionCode не больше прошлого ($prevCode). Увеличьте число после «+» в pubspec.yaml (или -SameVersion для пересборки той же версии)."
        }
    }
}

# Подпись: ключ должен быть до долгой сборки.
if (-not (Test-Path android\key.properties)) {
    throw 'Нет android\key.properties — APK нечем подписать (образец: android\key.properties.example).'
}
$sdkDir = ((Select-String -Path android\local.properties -Pattern '^sdk\.dir=(.+)$').Matches[0].Groups[1].Value) -replace '\\\\', '\' -replace '\\:', ':'
$buildTools = Get-ChildItem (Join-Path $sdkDir 'build-tools') -Directory |
    Sort-Object { [version]($_.Name -replace '[^\d.].*$', '') } | Select-Object -Last 1
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
if (-not (Test-Path $apksigner)) { throw "Не найден apksigner: $apksigner" }
if (-not $env:JAVA_HOME) {
    $jbr = 'C:\Program Files\Android\Android Studio\jbr'
    if (Test-Path $jbr) { $env:JAVA_HOME = $jbr }
}

# Проверяет подпись APK и возвращает SHA-256 отпечаток сертификата.
function Get-ApkCertSha256([string]$apk) {
    $text = (& $apksigner verify --print-certs $apk 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "apksigner verify не прошёл для ${apk}:`n$text" }
    if ($text -match 'CN=Android Debug') { throw "$apk подписан debug-ключом" }
    $m = [regex]::Match($text, 'certificate SHA-256 digest:\s*([0-9a-fA-F]+)')
    if (-not $m.Success) { throw "Нет SHA-256 отпечатка в выводе apksigner для $apk" }
    return $m.Groups[1].Value.ToLower()
}
$commit = (git rev-parse --short HEAD).Trim()
$dirty = (git status --porcelain --untracked-files=no)
if ($dirty) {
    Write-Warning 'Есть незакоммиченные изменения — версия будет помечена как -dirty.'
    $commit = "$commit-dirty"
}
$version = "$name-$commit"
Write-Host "Версия: $version (versionCode $versionCode)"

Write-Host 'Сборка Windows...'
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Сборка Windows не удалась' }

Write-Host 'Сборка Android (полный APK)...'
flutter build apk --release
if ($LASTEXITCODE -ne 0) { throw 'Сборка APK не удалась' }
$fullApk = Join-Path $env:TEMP "danceai-full-$commit.apk"
Copy-Item build\app\outputs\flutter-apk\app-release.apk $fullApk -Force

Write-Host 'Сборка Android (по архитектурам)...'
# Без «+1000×ABI» к versionCode: полный APK и arm64 одной версии взаимозаменяемы.
flutter build apk --release --split-per-abi -P force-version-code-ignoring-abi=true
if ($LASTEXITCODE -ne 0) { throw 'Сборка APK по архитектурам не удалась' }

$arm64Apk = 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
Write-Host 'Проверка подписи (apksigner verify)...'
$certFull = Get-ApkCertSha256 $fullApk
$certArm64 = Get-ApkCertSha256 $arm64Apk
if ($certFull -ne $certArm64) { throw 'APK подписаны разными сертификатами' }
Write-Host "Подпись в порядке. SHA-256 сертификата: $certFull"

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
versionCode: $versionCode
Коммит: $commit
Собрано: $date
Сертификат Android (SHA-256): $certFull

DanceAI-$version-android.apk        — Android, любой телефон (все архитектуры)
DanceAI-$version-android-arm64.apk  — Android, большинство современных телефонов (меньше размер)
DanceAI-$version-windows.zip        — Windows 10/11 x64: распаковать папку целиком, запустить dance_ai.exe
  (не подписано: при первом запуске SmartScreen — «Подробнее» → «Выполнить в любом случае»)
"@ | Out-File (Join-Path $out 'VERSION.txt') -Encoding utf8

Write-Host "Готово: $out"
Get-ChildItem $out | Format-Table Name, @{n='МБ'; e={[math]::Round($_.Length / 1MB, 1)}}
