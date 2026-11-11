# =============================================================
# Archeck — integrity control & archive tool (v2.0)
# -------------------------------------------------------------
# Что изменено по сравнению с v1:
#  - Исправлен краш при неверном пути (проверка до Convert-Path)
#  - OriginalHashes.csv теперь хранится вместе с архивом (симметрия),
#    но при распаковке ищется и по-старому (в корне) — совместимость
#  - Распаковка умеет сама находить архив в _archive_backup_*
#    (без ручного копирования томов в корень)
#  - CSV: добавлены необязательные колонки Size/LastWriteTime для
#    быстрой проверки (без пересчёта SHA256). Старые CSV работают.
#  - Безопасное удаление старых архивов (точные шаблоны + подтверждение)
#  - Единые функции вместо копи-паста, try/catch, валидация ввода
# =============================================================

$ErrorActionPreference = 'Stop'

# --- Базовые пути ---
$scriptFullPath = $MyInvocation.MyCommand.Path
$batchFullPath = Join-Path (Split-Path $scriptFullPath -Parent) 'Start.bat'
$scriptName = Split-Path $scriptFullPath -Leaf

# --- Вспомогательные функции ---

function Get-RelativePath {
    param([string]$FullPath, [string]$Base)
    return $FullPath.Substring($Base.Length).TrimStart('\','/')
}

# Чтение и проверка целочисленного выбора с значением по умолчанию
function Read-IntChoice {
    param([string]$Prompt, [int]$Min, [int]$Max, [int]$Default)
    $raw = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $val = 0
    if ([int]::TryParse($raw, [ref]$val) -and $val -ge $Min -and $val -le $Max) { return $val }
    Write-Host 'Invalid input. Using default value.' -ForegroundColor Yellow
    return $Default
}

# SHA256 + метаданные (размер, дата) для набора файлов
function Get-FileHashes {
    param([object[]]$Files, [string]$Activity, [string]$Base)
    $total = $Files.Count
    $current = 0
    $result = @()
    foreach ($file in $Files) {
        $current++
        $percent = [Math]::Round(($current / $total) * 100)
        Write-Progress -Activity $Activity -Status ('File {0} of {1} ({2}%)' -f $current, $total, $percent) -CurrentOperation $file.Name -PercentComplete $percent
        $hashObj = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        $result += [PSCustomObject]@{
            FilePath      = Get-RelativePath -FullPath $file.FullName -Base $Base
            Hash          = $hashObj.Hash
            Size          = $file.Length
            LastWriteTime = $file.LastWriteTime.ToString('o')
        }
    }
    Write-Progress -Activity $Activity -Completed
    return ,$result
}

# Проверка файлов по базе хешей; возвращает собранные ошибки (при -CollectErrors)
function Test-FileHashes {
    param(
        [Parameter(Mandatory)] [object[]]$Rows,
        [Parameter(Mandatory)] [string]$TargetDir,
        [bool]$Recurse = $false,
        [switch]$CollectErrors
    )
    $logErrors = @()
    if ($CollectErrors) {
        $logErrors += '=== ERROR AND MISSING FILES REPORT ==='
        $logErrors += 'Folder: ' + $TargetDir
        $logErrors += 'Date: ' + (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')
        $logErrors += '======================================='
    }

    $total = $Rows.Count
    $current = 0
    foreach ($row in $Rows) {
        $current++
        $relativePath = if ($row.FilePath) { $row.FilePath } else { $row.Path }
        if (-not $Recurse -and ($relativePath -like '*\*' -or $relativePath -like '*/*')) { continue }
        $fullPath = Join-Path -Path $TargetDir -ChildPath $relativePath
        if ($fullPath -eq $scriptFullPath -or $fullPath -eq $batchFullPath -or `
            $relativePath -eq 'FileHashes.csv' -or $relativePath -eq 'OriginalHashes.csv' -or $relativePath -eq 'ErrorLog.txt') { continue }

        $percent = [Math]::Round(($current / $total) * 100)
        Write-Progress -Activity 'Verifying Integrity' -Status ('File {0} of {1} ({2}%)' -f $current, $total, $percent) -CurrentOperation $relativePath -PercentComplete $percent

        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            # Быстрая предпроверка по размеру + дате (если метаданные есть в CSV)
            $fastOk = $false
            if ($row.Size -and $row.LastWriteTime) {
                try {
                    $info = Get-Item -LiteralPath $fullPath
                    $expectedTime = [datetime]::Parse($row.LastWriteTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                    if ($info.Length -eq [long]$row.Size -and $info.LastWriteTime.ToUniversalTime() -eq $expectedTime.ToUniversalTime()) { $fastOk = $true }
                } catch { $fastOk = $false }
            }

            if ($fastOk) {
                Write-Host ("OK (fast): {0}" -f $relativePath) -ForegroundColor Green
            } else {
                $currentHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
                if ($currentHash -eq $row.Hash) {
                    Write-Host ("OK: {0}" -f $relativePath) -ForegroundColor Green
                } else {
                    Write-Host ("CORRUPTED: {0}" -f $relativePath) -ForegroundColor Red
                    if ($CollectErrors) { $logErrors += '[CORRUPTED] ' + $relativePath }
                }
            }
        } else {
            Write-Host ("MISSING: {0}" -f $relativePath) -ForegroundColor Yellow
            if ($CollectErrors) { $logErrors += '[MISSING] ' + $relativePath }
        }
    }
    Write-Progress -Activity 'Verifying Integrity' -Completed
    return ,$logErrors
}

# Поиск 7-Zip
function Find-7Zip {
    $p64 = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
    $p32 = Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'
    if (Test-Path -LiteralPath $p64) { return $p64 }
    if (Test-Path -LiteralPath $p32) { return $p32 }
    return $null
}

# Уплощение структуры: если осталась одна бэкап-папка и корень пуст
function Optimize-BackupFolderStructure {
    param([string]$TargetDir)
    $backups = Get-ChildItem -LiteralPath $TargetDir -Directory | Where-Object { $_.Name.StartsWith('_archive_backup') }
    $rootFiles = Get-ChildItem -LiteralPath $TargetDir -File | Where-Object { $_.FullName -ne $scriptFullPath -and $_.FullName -ne $batchFullPath -and $_.Name -ne 'OriginalHashes.csv' }
    $rootDirs = Get-ChildItem -LiteralPath $TargetDir -Directory | Where-Object { -not $_.Name.StartsWith('_archive_backup') }
    if ($backups.Count -eq 1 -and $rootFiles.Count -eq 0 -and $rootDirs.Count -eq 0) {
        Write-Host 'Only one backup folder remains. Flattening directory structure...' -ForegroundColor Cyan
        $singleBackupPath = $backups.FullName
        foreach ($item in (Get-ChildItem -LiteralPath $singleBackupPath)) {
            Move-Item -LiteralPath $item.FullName -Destination $TargetDir -Force
        }
        Remove-Item -LiteralPath $singleBackupPath -Force -Recurse
        Write-Host 'Structure optimization complete. Files moved to root folder.' -ForegroundColor Green
    }
}

# =============================================================
# Старт
# =============================================================

Clear-Host
Write-Host '=== INTEGRITY CONTROL & ARCHIVE TOOL ===' -ForegroundColor Cyan
Write-Host 'Leave empty and press ENTER to select CURRENT folder'
$targetDir = Read-Host 'Enter full path to target folder'
if ([string]::IsNullOrWhiteSpace($targetDir)) { $targetDir = $PSScriptRoot }

# Проверка ДО Resolve-Path (иначе неверный путь уронит скрипт)
if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
    Write-Host 'ERROR: Folder does not exist!' -ForegroundColor Red
    Write-Host ''
    Read-Host 'Press ENTER to exit'
    exit
}
$targetDir = (Resolve-Path -LiteralPath $targetDir).Path

Write-Host ''
$fastMode = Read-Host 'Enable FAST MODE? (Skip subfolder configuration, scan ALL) (Y/N, default: N)'
if ($fastMode -like 'y*') {
    $isRecurse = $true
} else {
    Write-Host ''
    Write-Host 'Select folder scanning mode:'
    Write-Host '1. Only files in the root folder (No subfolders)'
    Write-Host '2. Include all subfolders (Recursive)'
    $recurseChoice = Read-Host 'Your choice (1 or 2)'
    $isRecurse = $recurseChoice -eq '2'
}

Set-Location -LiteralPath $targetDir

$currentFolderName = Split-Path $targetDir -Leaf
if ([string]::IsNullOrWhiteSpace($currentFolderName) -or $currentFolderName -eq '\' -or $currentFolderName -eq '/') {
    $currentFolderName = 'Archive_out'
}

$filterScript = {
    $_.FullName -ne $scriptFullPath -and
    $_.FullName -ne $batchFullPath -and
    $_.Name -ne 'FileHashes.csv' -and
    $_.Name -ne 'OriginalHashes.csv' -and
    $_.Name -ne 'ErrorLog.txt' -and
    -not $_.Name.StartsWith($currentFolderName) -and
    -not $_.Name.StartsWith('_archive_backup')
}

while ($true) {
    Clear-Host
    Write-Host ("Working directory: {0}" -f $targetDir) -ForegroundColor Magenta
    if ($isRecurse) { Write-Host 'Mode: WITH SUBFOLDERS' -ForegroundColor Magenta } else { Write-Host 'Mode: ROOT FOLDER ONLY' -ForegroundColor Magenta }
    Write-Host '--------------------------------------------------' -ForegroundColor Magenta
    Write-Host '1. Create hash database (FileHashes.csv)'
    Write-Host '2. Verify files with FileHashes.csv (Screen output)'
    Write-Host '3. Verify files + Save error report (ErrorLog.txt)'
    Write-Host ("4. Pack files to 7-Zip archive ({0}.zip/.7z) + Move to unique folder" -f $currentFolderName)
    Write-Host '5. Unpack 7-Zip archive with verification'
    Write-Host '6. Exit program'
    Write-Host ''
    $choice = Read-Host 'Select action (1, 2, 3, 4, 5 or 6)'

    if ($choice -eq '6') { break }

    try {
        if ($choice -eq '1') {
            # --- Создание базы хешей ---
            Write-Host 'Scanning folder...' -ForegroundColor Yellow
            $param = @{ LiteralPath = $targetDir; File = $true }
            if ($isRecurse) { $param.Recurse = $true }
            $files = Get-ChildItem @param | Where-Object $filterScript
            if ($files.Count -eq 0) { Write-Host 'No files found!' -ForegroundColor Red; Read-Host 'Press ENTER to return to menu'; continue }
            $result = Get-FileHashes -Files $files -Activity 'Calculating Hashes' -Base $targetDir
            $result | Export-Csv -LiteralPath '.\FileHashes.csv' -NoTypeInformation -Encoding UTF8
            Write-Host 'Success! FileHashes.csv created.' -ForegroundColor Green
            Read-Host 'Press ENTER to return to menu'
        }
        elseif ($choice -eq '2' -or $choice -eq '3') {
            # --- Проверка по базе ---
            $csvPath = Join-Path $targetDir 'FileHashes.csv'
            if (-not (Test-Path -LiteralPath $csvPath)) {
                Write-Host 'ERROR: FileHashes.csv database not found!' -ForegroundColor Red
                Read-Host 'Press ENTER to return to menu'; continue
            }
            $csvHashes = @(Import-Csv -LiteralPath $csvPath)
            $logErrors = Test-FileHashes -Rows $csvHashes -TargetDir $targetDir -Recurse $isRecurse -CollectErrors:($choice -eq '3')

            if ($choice -eq '3') {
                if ($logErrors.Count -gt 4) {
                    $logErrors | Out-File -LiteralPath '.\ErrorLog.txt' -Encoding UTF8
                    Write-Host 'Problems detected! Report saved to ErrorLog.txt' -ForegroundColor Red
                } else {
                    if (Test-Path -LiteralPath '.\ErrorLog.txt') { Remove-Item -LiteralPath '.\ErrorLog.txt' -Force }
                    Write-Host 'All files are intact! No report file created.' -ForegroundColor Green
                }
            } else {
                Write-Host 'Verification complete.' -ForegroundColor Cyan
            }
            Read-Host 'Press ENTER to return to menu'
        }
        elseif ($choice -eq '4') {
            # --- Архивация ---
            $exe7z = Find-7Zip
            if (-not $exe7z) {
                Write-Host 'ERROR: 7-Zip archiver not found in Program Files!' -ForegroundColor Red
                Read-Host 'Press ENTER to return to main menu'; continue
            }

            $existingBackups = Get-ChildItem -LiteralPath $targetDir -Directory | Where-Object { $_.Name.StartsWith('_archive_backup') }
            if ($existingBackups) {
                Write-Host ''
                Write-Host 'WARNING: Existing archive backup folder(s) found in this directory!' -ForegroundColor Yellow
                $overwriteChoice = Read-Host 'Do you want to proceed and create a NEW archive folder? (Y/N, default: Y)'
                if ($overwriteChoice -like 'n*') {
                    Write-Host 'Action canceled by user.' -ForegroundColor Cyan
                    Read-Host 'Press ENTER to return to menu'; continue
                }
            }

            Write-Host ''; Write-Host '--- 7-ZIP ARCHIVE SETTINGS ---' -ForegroundColor Cyan
            $compLevel = Read-IntChoice -Prompt 'Compression level (0-None, 1-Fast, 5-Normal, 9-Ultra, default: 5)' -Min 0 -Max 9 -Default 5
            $password = Read-Host 'Enter password for archive (Leave empty for none)'
            $splitSize = Read-Host 'Split into volumes? (e.g. 100M, 2G. Leave empty for none)'
            $deleteAfter = Read-Host 'Delete original files AND empty folders after successful archive? (Y/N, default: N)'

            Write-Host 'Analyzing files...' -ForegroundColor Yellow
            $param = @{ LiteralPath = $targetDir; File = $true }
            if ($isRecurse) { $param.Recurse = $true }
            $files = Get-ChildItem @param | Where-Object $filterScript
            if ($files.Count -eq 0) { Write-Host 'No files to archive!' -ForegroundColor Red; Read-Host 'Press ENTER to return'; continue }

            # ШАГ 1: контрольная база исходников
            Write-Host 'Creating hash database for original files (OriginalHashes.csv)...' -ForegroundColor Yellow
            $origResult = Get-FileHashes -Files $files -Activity 'Snapshotting Originals' -Base $targetDir
            $origResult | Export-Csv -LiteralPath '.\OriginalHashes.csv' -NoTypeInformation -Encoding UTF8

            $hasPassword = -not [string]::IsNullOrWhiteSpace($password)
            $ext = if ($hasPassword) { '7z' } else { 'zip' }
            $archiveBaseName = "$currentFolderName.$ext"
            $archiveFullPath = Join-Path $targetDir $archiveBaseName

            # Безопасное удаление предыдущих архивов (точные шаблоны + подтверждение)
            $oldArchives = Get-ChildItem -LiteralPath $targetDir -File | Where-Object { $_.Name -like "$currentFolderName.zip*" -or $_.Name -like "$currentFolderName.7z*" }
            if ($oldArchives) {
                Write-Host 'Previous archive file(s) found:' -ForegroundColor Yellow
                $oldArchives | ForEach-Object { Write-Host ('  - {0}' -f $_.Name) }
                $delOld = Read-Host 'Remove them before creating a new archive? (Y/N, default: Y)'
                if ($delOld -like 'n*') {
                    Write-Host 'Action canceled. Please remove old archives manually or confirm deletion.' -ForegroundColor Yellow
                    Read-Host 'Press ENTER to return to menu'; continue
                }
                $oldArchives | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
            }

            $args7z = @('a', $archiveFullPath, "-mx=$compLevel")
            $args7z += "-x!$scriptName"; $args7z += '-x!Start.bat'; $args7z += '-x!FileHashes.csv'; $args7z += '-x!OriginalHashes.csv'; $args7z += '-x!ErrorLog.txt'; $args7z += "-x!$currentFolderName.zip*"; $args7z += "-x!$currentFolderName.7z*"; $args7z += '-x!_archive_backup*'
            if (-not $isRecurse) { $args7z += '-r-' }

            if ($hasPassword) {
                $args7z += '-t7z'
                $args7z += "-p$password"
                $args7z += '-mhe=on'
            }
            if (-not [string]::IsNullOrWhiteSpace($splitSize)) { $args7z += "-v$splitSize" }
            $args7z += '*'

            Write-Host 'Running 7-Zip compression...' -ForegroundColor Yellow
            & $exe7z $args7z
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                Write-Host ('Error occurred during archiving (Code: {0}). Original files preserved.' -f $exitCode) -ForegroundColor Red
                if (Test-Path -LiteralPath '.\OriginalHashes.csv') { Remove-Item -LiteralPath '.\OriginalHashes.csv' -Force }
                Read-Host 'Press ENTER to return to menu'; continue
            }

            if ($deleteAfter -like 'y*') {
                Write-Host 'Cleaning up original files...' -ForegroundColor Yellow
                foreach ($f in $files) { if (Test-Path -LiteralPath $f.FullName) { Remove-Item -LiteralPath $f.FullName -Force } }

                Write-Host 'Cleaning up empty subfolders...' -ForegroundColor Yellow
                $subDirs = Get-ChildItem -LiteralPath $targetDir -Directory -Recurse | Sort-Object FullName -Descending
                foreach ($dir in $subDirs) {
                    if (Test-Path -LiteralPath $dir.FullName) {
                        if ($scriptFullPath.StartsWith($dir.FullName) -or $batchFullPath.StartsWith($dir.FullName)) { continue }
                        if ((Get-ChildItem -LiteralPath $dir.FullName -Force).Count -eq 0) { Remove-Item -LiteralPath $dir.FullName -Force }
                    }
                }
                if ($existingBackups) {
                    Write-Host 'Deleting old backup folders...' -ForegroundColor Yellow
                    foreach ($eb in $existingBackups) { Remove-Item -LiteralPath $eb.FullName -Force -Recurse }
                }
            }

            # ШАГ 2: контрольная база томов архива
            Write-Host 'Creating hash database for the new archive volumes...' -ForegroundColor Yellow
            $archFiles = Get-ChildItem -LiteralPath $targetDir -File | Where-Object { $_.Name.StartsWith("$currentFolderName.") }
            $archResult = Get-FileHashes -Files $archFiles -Activity 'Hashing archive volumes' -Base $targetDir
            $archResult | Export-Csv -LiteralPath '.\FileHashes.csv' -NoTypeInformation -Encoding UTF8

            $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
            $newBackupFolder = Join-Path $targetDir "_archive_backup_$timestamp"
            New-Item -Path $newBackupFolder -ItemType Directory | Out-Null

            Write-Host ("Moving new archive files and database to unique folder: {0}..." -f (Split-Path $newBackupFolder -Leaf)) -ForegroundColor Yellow
            $archFilesToMove = Get-ChildItem -LiteralPath $targetDir -File | Where-Object { $_.Name.StartsWith("$currentFolderName.") }
            foreach ($af in $archFilesToMove) { Move-Item -LiteralPath $af.FullName -Destination $newBackupFolder -Force }
            # Симметрия: OriginalHashes.csv переносится вместе с архивом
            foreach ($aux in 'FileHashes.csv','OriginalHashes.csv') {
                $auxFull = Join-Path $targetDir $aux
                if (Test-Path -LiteralPath $auxFull) { Move-Item -LiteralPath $auxFull -Destination $newBackupFolder -Force }
            }

            Write-Host ("Success! Archive safely saved in unique directory: {0}" -f (Split-Path $newBackupFolder -Leaf)) -ForegroundColor Green

            Optimize-BackupFolderStructure -TargetDir $targetDir
            Read-Host 'Press ENTER to return to menu'
        }
        elseif ($choice -eq '5') {
            # --- Распаковка с проверкой ---
            $exe7z = Find-7Zip
            if (-not $exe7z) {
                Write-Host 'ERROR: 7-Zip archiver not found in Program Files!' -ForegroundColor Red
                Read-Host 'Press ENTER to return to main menu'; continue
            }

            # Определяем папку-источник (корень или _archive_backup_*)
            $sourceDir = $targetDir
            $sourceIsBackup = $false
            $csvPath = Join-Path $sourceDir 'FileHashes.csv'

            if (-not (Test-Path -LiteralPath $csvPath)) {
                $backups = @(Get-ChildItem -LiteralPath $targetDir -Directory | Where-Object { $_.Name.StartsWith('_archive_backup') } | Sort-Object LastWriteTime -Descending)
                if ($backups.Count -gt 0) {
                    Write-Host 'FileHashes.csv not found in the root. Found backup folder(s):' -ForegroundColor Yellow
                    for ($i = 0; $i -lt $backups.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $backups[$i].Name) }
                    $srcChoice = Read-Host ("Choose a source folder (1..{0}), or press ENTER to enter a path manually:" -f $backups.Count)
                    if ($srcChoice -match '^\d+$' -and [int]$srcChoice -ge 1 -and [int]$srcChoice -le $backups.Count) {
                        $sourceDir = $backups[[int]$srcChoice - 1].FullName
                        $sourceIsBackup = $true
                    } else {
                        $manualSrc = Read-Host 'Enter full path to folder with archive + FileHashes.csv'
                        if (-not [string]::IsNullOrWhiteSpace($manualSrc) -and (Test-Path -LiteralPath $manualSrc -PathType Container)) {
                            $sourceDir = (Resolve-Path -LiteralPath $manualSrc).Path
                            $sourceIsBackup = (Split-Path $sourceDir -Leaf) -like '_archive_backup*'
                        }
                    }
                } else {
                    $manualSrc = Read-Host 'Enter full path to folder with archive + FileHashes.csv'
                    if (-not [string]::IsNullOrWhiteSpace($manualSrc) -and (Test-Path -LiteralPath $manualSrc -PathType Container)) {
                        $sourceDir = (Resolve-Path -LiteralPath $manualSrc).Path
                        $sourceIsBackup = (Split-Path $sourceDir -Leaf) -like '_archive_backup*'
                    }
                }
                $csvPath = Join-Path $sourceDir 'FileHashes.csv'
            }

            if (-not (Test-Path -LiteralPath $csvPath)) {
                Write-Host 'ERROR: FileHashes.csv not found in the selected source.' -ForegroundColor Red
                Read-Host 'Press ENTER to return to menu'; continue
            }

            # Фаза 1: проверка целостности томов
            Write-Host 'Phase 1: Verifying archive volume integrity...' -ForegroundColor Yellow
            $csvHashes = @(Import-Csv -LiteralPath $csvPath)
            $archiveValid = $true
            foreach ($row in $csvHashes) {
                if (-not ($row.FilePath.StartsWith("$currentFolderName.zip") -or $row.FilePath.StartsWith("$currentFolderName.7z"))) { continue }
                $volFull = Join-Path $sourceDir $row.FilePath
                if (Test-Path -LiteralPath $volFull) {
                    $calc = (Get-FileHash -LiteralPath $volFull -Algorithm SHA256).Hash
                    if ($calc -ne $row.Hash) { $archiveValid = $false; Write-Host "BAD HASH: $($row.FilePath)" -ForegroundColor Red }
                    else { Write-Host "INTEGRITY OK: $($row.FilePath)" -ForegroundColor Green }
                } else { $archiveValid = $false; Write-Host "MISSING VOLUME: $($row.FilePath)" -ForegroundColor Red }
            }

            if (-not $archiveValid) {
                Write-Host 'ERROR: Archive is corrupted or incomplete! Unpacking aborted.' -ForegroundColor Red
                Read-Host 'Press ENTER to return to menu'; continue
            }

            $firstVolume = Get-ChildItem -LiteralPath $sourceDir -File | Where-Object {
                $_.Name -eq "$currentFolderName.zip" -or $_.Name -eq "$currentFolderName.7z" -or
                $_.Name -eq "$currentFolderName.zip.001" -or $_.Name -eq "$currentFolderName.7z.001"
            } | Select-Object -First 1

            if (-not $firstVolume) {
                Write-Host 'ERROR: No matching archive file found to unpack!' -ForegroundColor Red
                Read-Host 'Press ENTER to return to menu'; continue
            }

            # Папка назначения (по умолчанию — целевая папка)
            Write-Host ''
            $destInput = Read-Host ("Extract to folder (default: {0}):" -f $targetDir)
            if (-not [string]::IsNullOrWhiteSpace($destInput)) {
                $destDir = $destInput.Trim('"')
                if (-not (Test-Path -LiteralPath $destDir -PathType Container)) { New-Item -Path $destDir -ItemType Directory | Out-Null }
                $destDir = (Resolve-Path -LiteralPath $destDir).Path
            } else { $destDir = $targetDir }

            Write-Host 'Phase 2: Unpacking archive via 7-Zip...' -ForegroundColor Yellow
            $args7z = @('x', $firstVolume.FullName, "-o$destDir", '-y')
            & $exe7z $args7z
            if ($LASTEXITCODE -ne 0) {
                Write-Host ("ERROR: 7-Zip failed during extraction (Code: {0})." -f $LASTEXITCODE) -ForegroundColor Red
                Read-Host 'Press ENTER to return to menu'; continue
            }
            Write-Host 'Extraction successful!' -ForegroundColor Green

            # Фаза 3: сверка распакованного с оригиналами (ищем CSV рядом с архивом или в корне)
            $origCsvPath = Join-Path $sourceDir 'OriginalHashes.csv'
            if (-not (Test-Path -LiteralPath $origCsvPath)) { $origCsvPath = Join-Path $targetDir 'OriginalHashes.csv' }

            if (Test-Path -LiteralPath $origCsvPath) {
                Write-Host ''
                Write-Host 'Phase 3: Verifying extracted files against original hashes...' -ForegroundColor Yellow
                $origHashes = @(Import-Csv -LiteralPath $origCsvPath)
                $extractionValid = $true
                foreach ($row in $origHashes) {
                    $rel = $row.FilePath
                    $full = Join-Path $destDir $rel
                    if (Test-Path -LiteralPath $full) {
                        $calc = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
                        if ($calc -ne $row.Hash) { $extractionValid = $false; Write-Host "EXTRACTION CORRUPTED: $rel" -ForegroundColor Red }
                        else { Write-Host "EXTRACTION OK: $rel" -ForegroundColor Green }
                    } else {
                        $extractionValid = $false
                        Write-Host "EXTRACTION MISSING FILE: $rel" -ForegroundColor Red
                    }
                }
                if ($extractionValid) { Write-Host 'PERFECT! All extracted files match the original hashes exactly.' -ForegroundColor Green }
                else { Write-Host 'WARNING: Errors detected during extraction check! Some files do not match originals.' -ForegroundColor Red }
            } else {
                Write-Host 'OriginalHashes.csv not found, skipping extraction integrity check.' -ForegroundColor Yellow
            }

            Write-Host ''
            $deleteArchive = Read-Host 'Delete archive volumes and database file? (Y - Delete / N - Move to timestamped backup folder, default: N)'
            $archFilesToProcess = Get-ChildItem -LiteralPath $sourceDir -File | Where-Object { $_.Name.StartsWith("$currentFolderName.") }

            if ($deleteArchive -like 'y*') {
                Write-Host 'Deleting archive files...' -ForegroundColor Yellow
                foreach ($af in $archFilesToProcess) { Remove-Item -LiteralPath $af.FullName -Force }
                if (Test-Path -LiteralPath $csvPath) { Remove-Item -LiteralPath $csvPath -Force }
                Write-Host 'Archive cleanup complete.' -ForegroundColor Green
            } elseif ($sourceIsBackup) {
                # Источник уже внутри бэкап-папки — доп-перенос не нужен
                Write-Host 'Archive kept in place (already inside a backup folder).' -ForegroundColor Green
            } else {
                $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
                $backupFolder = Join-Path $sourceDir "_archive_backup_$timestamp"
                if (-not (Test-Path -LiteralPath $backupFolder)) { New-Item -Path $backupFolder -ItemType Directory | Out-Null }
                Write-Host ("Moving archive files to {0}..." -f (Split-Path $backupFolder -Leaf)) -ForegroundColor Yellow
                foreach ($af in $archFilesToProcess) { Move-Item -LiteralPath $af.FullName -Destination $backupFolder -Force }
                if (Test-Path -LiteralPath $csvPath) { Move-Item -LiteralPath $csvPath -Destination $backupFolder -Force }
                Write-Host ("Archive safely stored in unique directory: {0}" -f (Split-Path $backupFolder -Leaf)) -ForegroundColor Green
            }

            Optimize-BackupFolderStructure -TargetDir $targetDir
            Read-Host 'Press ENTER to return to menu'
        }
        else {
            Write-Host 'Invalid choice.' -ForegroundColor Yellow
            Read-Host 'Press ENTER to return to menu'
        }
    } catch {
        Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Read-Host 'Press ENTER to return to menu'
    }
}
