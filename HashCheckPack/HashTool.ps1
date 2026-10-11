$scriptFullPath = $MyInvocation.MyCommand.Path
# Автоматически вычисляем путь к Start.bat, который лежит рядом со скриптом
$batchFullPath = Join-Path (Split-Path $scriptFullPath -Parent) 'Start.bat'

Clear-Host
Write-Host '=== INTEGRITY CONTROL & ARCHIVE TOOL ===' -ForegroundColor Cyan
Write-Host 'Leave empty and press ENTER to select CURRENT folder'
$targetDir = Read-Host 'Enter full path to target folder'
if ([string]::IsNullOrWhiteSpace($targetDir)) { $targetDir = $PSScriptRoot }
if (-not $targetDir) { $targetDir = '.\' }
$targetDir = Convert-Path $targetDir
if (-not (Test-Path $targetDir -PathType Container)) {
    Write-Host 'ERROR: Folder does not exist!' -ForegroundColor Red
    Write-Host ''
    Read-Host 'Press ENTER to exit'
    exit
}

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

Set-Location -Path $targetDir

# Автоматически получаем чистое имя текущей папки для названия архива
$currentFolderName = Split-Path $targetDir -Leaf
if ([string]::IsNullOrWhiteSpace($currentFolderName) -or $currentFolderName -eq '\' -or $currentFolderName -eq '/') {
    $currentFolderName = 'Archive_out'
}

# Функция автоматического выравнивания папок (убирает лишнюю вложенность, если остался 1 бэкап)
function Optimize-BackupFolderStructure {
    $backups = Get-ChildItem -Path $targetDir -Directory | Where-Object { $_.Name.StartsWith('_archive_backup') }
    $rootFiles = Get-ChildItem -Path $targetDir -File | Where-Object { $_.FullName -ne $scriptFullPath -and $_.FullName -ne $batchFullPath -and $_.Name -ne 'OriginalHashes.csv' }
    $rootDirs = Get-ChildItem -Path $targetDir -Directory | Where-Object { -not $_.Name.StartsWith('_archive_backup') }
    
    if ($backups.Count -eq 1 -and $rootFiles.Count -eq 0 -and $rootDirs.Count -eq 0) {
        Write-Host 'Only one backup folder remains. Flattening directory structure...' -ForegroundColor Cyan
        $singleBackupPath = $backups.FullName
        $nestedItems = Get-ChildItem -Path $singleBackupPath
        foreach ($item in $nestedItems) {
            Move-Item $item.FullName -Destination $targetDir -Force
        }
        Remove-Item $singleBackupPath -Force -Recurse
        Write-Host 'Structure optimization complete. Files moved to root folder.' -ForegroundColor Green
    }
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
    
    $filterScript = {
        $_.FullName -ne $scriptFullPath -and 
        $_.FullName -ne $batchFullPath -and
        $_.Name -ne 'FileHashes.csv' -and 
        $_.Name -ne 'OriginalHashes.csv' -and 
        $_.Name -ne 'ErrorLog.txt' -and 
        -not $_.Name.StartsWith($currentFolderName) -and
        -not $_.Name.StartsWith('_archive_backup')
    }
    
    if ($choice -eq '1') {
        Write-Host 'Scanning folder...' -ForegroundColor Yellow
        $param = @{ Path = $targetDir; File = $true }
        if ($isRecurse) { $param.Recurse = $true }
        $files = Get-ChildItem @param | Where-Object $filterScript
        $total = $files.Count
        if ($total -eq 0) { Write-Host 'No files found!' -ForegroundColor Red; Read-Host 'Press ENTER to return to menu'; continue }
        $current = 0; $result = @()
        foreach ($file in $files) {
            $current++; $percent = [Math]::Round(($current / $total) * 100)
            Write-Progress -Activity 'Calculating Hashes' -Status ('File {0} of {1} ({2}%)' -f $current, $total, $percent) -CurrentOperation $file.Name -PercentComplete $percent
            $hashObj = Get-FileHash -Path $file.FullName -Algorithm SHA256
            $relativePath = $file.FullName.Replace($targetDir, '').TrimStart('\').TrimStart('/')
            $result += [PSCustomObject]@{ FilePath = $relativePath; Hash = $hashObj.Hash }
        }
        $result | Export-Csv -Path '.\FileHashes.csv' -NoTypeInformation -Encoding UTF8
        Write-Progress -Activity 'Calculating Hashes' -Completed
        Write-Host 'Success! FileHashes.csv created.' -ForegroundColor Green
        Read-Host 'Press ENTER to return to menu'
    }
    elseif ($choice -eq '2' -or $choice -eq '3') {
        $csvPath = '.\FileHashes.csv'
        if (-not (Test-Path $csvPath)) {
            Write-Host 'ERROR: FileHashes.csv database not found!' -ForegroundColor Red
            Read-Host 'Press ENTER to return to menu'; continue
        }
        $csvHashes = @(Import-Csv -Path $csvPath)
        $total = $csvHashes.Count; $current = 0; $logErrors = @()
        if ($choice -eq '3') { 
            $logErrors += '=== ERROR AND MISSING FILES REPORT ==='
            $logErrors += 'Folder: ' + $targetDir
            $logErrors += 'Date: ' + (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')
            $logErrors += '======================================='
        }
        foreach ($row in $csvHashes) {
            $current++; $relativePath = if ($row.FilePath) { $row.FilePath } else { $row.Path }
            if (-not $isRecurse -and ($relativePath -like '*\*' -or $relativePath -like '*/*')) { continue }
            $fullPath = Join-Path -Path $targetDir -ChildPath $relativePath
            if ($fullPath -eq $scriptFullPath -or $fullPath -eq $batchFullPath -or $relativePath -eq 'FileHashes.csv' -or $relativePath -eq 'OriginalHashes.csv' -or $relativePath -eq 'ErrorLog.txt') { continue }
            $percent = [Math]::Round(($current / $total) * 100)
            Write-Progress -Activity 'Verifying Integrity' -Status ('File {0} of {1} ({2}%)' -f $current, $total, $percent) -CurrentOperation $relativePath -PercentComplete $percent
            if (Test-Path $fullPath) {
                $currentHash = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash
                if ($currentHash -eq $row.Hash) {
                    Write-Host 'OK: ' $relativePath -ForegroundColor Green
                } else {
                    Write-Host 'CORRUPTED: ' $relativePath -ForegroundColor Red
                    if ($choice -eq '3') { $logErrors += '[CORRUPTED] ' + $relativePath }
                }
            } else {
                Write-Host 'MISSING: ' $relativePath -ForegroundColor Yellow
                if ($choice -eq '3') { $logErrors += '[MISSING] ' + $relativePath }
            }
        }
        Write-Progress -Activity 'Verifying Integrity' -Completed
        if ($choice -eq '3' -and $logErrors.Count -gt 4) {
            $logErrors | Out-File -FilePath '.\ErrorLog.txt' -Encoding UTF8
            Write-Host 'Problems detected! Report saved to ErrorLog.txt' -ForegroundColor Red
        } elseif ($choice -eq '3') {
            if (Test-Path '.\ErrorLog.txt') { Remove-Item '.\ErrorLog.txt' }
            Write-Host 'All files are intact! No report file created.' -ForegroundColor Green
        } else { Write-Host 'Verification complete.' -ForegroundColor Cyan }
        Read-Host 'Press ENTER to return to menu'
    }
    elseif ($choice -eq '4') {
        $p64 = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
        $p32 = Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'
        $exe7z = if (Test-Path $p64) { $p64 } else { $p32 }
        if (-not (Test-Path $exe7z)) {
            Write-Host 'ERROR: 7-Zip archiver not found in Program Files!' -ForegroundColor Red
            Read-Host 'Press ENTER to return to main menu'; continue
        }
        
        $existingBackups = Get-ChildItem -Path $targetDir -Directory | Where-Object { $_.Name.StartsWith('_archive_backup') }
        if ($existingBackups) {
            Write-Host ''
            Write-Host 'WARNING: Existing archive backup folder(s) found in this directory!' -ForegroundColor Yellow
            $overwriteChoice = Read-Host 'Do you want to proceed and create a NEW archive folder? (Y/N, default: Y)'
            if ($overwriteChoice -eq 'n' -or $overwriteChoice -like 'n*') {
                Write-Host 'Action canceled by user.' -ForegroundColor Cyan
                Read-Host 'Press ENTER to return to menu'; continue
            }
        }
        
        Write-Host ''; Write-Host '--- 7-ZIP ARCHIVE SETTINGS ---' -ForegroundColor Cyan
        $compLevel = Read-Host 'Compression level (0-None, 1-Fast, 5-Normal, 9-Ultra, default: 5)'
        if ([string]::IsNullOrWhiteSpace($compLevel)) { $compLevel = '5' }
        $password = Read-Host 'Enter password for archive (Leave empty for none)'
        $splitSize = Read-Host 'Split into volumes? (e.g. 100M, 2G. Leave empty for none)'
        $deleteAfter = Read-Host 'Delete original files AND empty folders after successful archive? (Y/N, default: N)'
        
        Write-Host 'Analyzing files...' -ForegroundColor Yellow
        $param = @{ Path = $targetDir; File = $true }
        if ($isRecurse) { $param.Recurse = $true }
        $files = Get-ChildItem @param | Where-Object $filterScript
        if ($files.Count -eq 0) { Write-Host 'No files to archive!' -ForegroundColor Red; Read-Host 'Press ENTER to return'; continue }
        
        # ШАГ 1: Создание контрольной базы ДЛЯ ИСХОДНЫХ ФАЙЛОВ перед упаковкой
        Write-Host 'Creating hash database for original files (OriginalHashes.csv)...' -ForegroundColor Yellow
        $origResult = @()
        $currentOrig = 0
        foreach ($file in $files) {
            $currentOrig++
            $percentOrig = [Math]::Round(($currentOrig / $files.Count) * 100)
            Write-Progress -Activity 'Snapshotting Originals' -Status ('File {0} of {1} ({2}%)' -f $currentOrig, $files.Count, $percentOrig) -CurrentOperation $file.Name -PercentComplete $percentOrig
            $hashObj = Get-FileHash -Path $file.FullName -Algorithm SHA256
            $relativePath = $file.FullName.Replace($targetDir, '').TrimStart('\').TrimStart('/')
            $origResult += [PSCustomObject]@{ FilePath = $relativePath; Hash = $hashObj.Hash }
        }
        $origResult | Export-Csv -Path '.\OriginalHashes.csv' -NoTypeInformation -Encoding UTF8
        Write-Progress -Activity 'Snapshotting Originals' -Completed
        
        # Настройка формата архива (.7z или .zip)
        $hasPassword = -not [string]::IsNullOrWhiteSpace($password)
        $ext = if ($hasPassword) { '7z' } else { 'zip' }
        $archiveBaseName = "$currentFolderName.$ext"
        $archiveFullPath = Join-Path $targetDir $archiveBaseName
        if (Test-Path ($archiveFullPath + '*')) { Remove-Item ($archiveFullPath + '*') -Force }
        
        $scriptName = Split-Path $scriptFullPath -Leaf
        $args7z = @('a', $archiveFullPath, "-mx=$compLevel")
        $args7z += "-x!$scriptName"; $args7z += "-x!Start.bat"; $args7z += "-x!FileHashes.csv"; $args7z += "-x!OriginalHashes.csv"; $args7z += "-x!ErrorLog.txt"; $args7z += "-x!$currentFolderName.zip*"; $args7z += "-x!$currentFolderName.7z*"; $args7z += "-x!_archive_backup*"
        if (-not $isRecurse) { $args7z += '-r-' }
        
        if ($hasPassword) { 
            $args7z += "-t7z"
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
            if (Test-Path '.\OriginalHashes.csv') { Remove-Item '.\OriginalHashes.csv' -Force }
            Read-Host 'Press ENTER to return to menu'; continue
        }
        
        if ($deleteAfter -like 'y*') {
            Write-Host 'Cleaning up original files...' -ForegroundColor Yellow
            foreach ($f in $files) { if (Test-Path $f.FullName) { Remove-Item $f.FullName -Force } }
            
            Write-Host 'Cleaning up empty subfolders...' -ForegroundColor Yellow
            $subDirs = Get-ChildItem -Path $targetDir -Directory -Recurse | Sort-Object -Property FullName -Descending
            foreach ($dir in $subDirs) {
                if (Test-Path $dir.FullName) {
                    if ($scriptFullPath.StartsWith($dir.FullName) -or $batchFullPath.StartsWith($dir.FullName)) { continue }
                    if ((Get-ChildItem -Path $dir.FullName -Force).Count -eq 0) { Remove-Item -Path $dir.FullName -Force }
                }
            }
            if ($existingBackups) {
                Write-Host 'Deleting old backup folders...' -ForegroundColor Yellow
                foreach ($eb in $existingBackups) { Remove-Item $eb.FullName -Force -Recurse }
            }
        }
        
        Write-Host 'Creating hash database for the new archive volumes...' -ForegroundColor Yellow
        $archFiles = Get-ChildItem -Path $targetDir -File | Where-Object { $_.Name.StartsWith("$currentFolderName.") }
        $archResult = @()
        foreach ($af in $archFiles) {
            $hashObj = Get-FileHash -Path $af.FullName -Algorithm SHA256
            $archResult += [PSCustomObject]@{ FilePath = $af.Name; Hash = $hashObj.Hash }
        }
        $archResult | Export-Csv -Path '.\FileHashes.csv' -NoTypeInformation -Encoding UTF8
        
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $newBackupFolder = Join-Path $targetDir "_archive_backup_$timestamp"
        New-Item -Path $newBackupFolder -ItemType Directory | Out-Null
        
        Write-Host ("Moving new archive files and database to unique folder: {0}..." -f (Split-Path $newBackupFolder -Leaf)) -ForegroundColor Yellow
        $archFilesToMove = Get-ChildItem -Path $targetDir -File | Where-Object { $_.Name.StartsWith("$currentFolderName.") }
        foreach ($af in $archFilesToMove) {
            Move-Item $af.FullName -Destination $newBackupFolder -Force
        }
        if (Test-Path '.\FileHashes.csv') {
            Move-Item '.\FileHashes.csv' -Destination $newBackupFolder -Force
        }
        
        Write-Host ("Success! Archive safely saved in unique directory: {0}" -f (Split-Path $newBackupFolder -Leaf)) -ForegroundColor Green
        
        Optimize-BackupFolderStructure
        Read-Host 'Press ENTER to return to menu'
    }
    elseif ($choice -eq '5') {
        $p64 = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
        $p32 = Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'
        $exe7z = if (Test-Path $p64) { $p64 } else { $p32 }
        if (-not (Test-Path $exe7z)) {
            Write-Host 'ERROR: 7-Zip archiver not found in Program Files!' -ForegroundColor Red
            Read-Host 'Press ENTER to return to main menu'; continue
        }

        $csvPath = '.\FileHashes.csv'
        if (-not (Test-Path $csvPath)) {
            Write-Host 'ERROR: FileHashes.csv not found in the root directory!' -ForegroundColor Red
            Write-Host 'If your archive is inside a backup folder, please move the archive volumes and FileHashes.csv out to the root before unpacking.' -ForegroundColor Yellow
            Read-Host 'Press ENTER to return to menu'; continue
        }

        Write-Host 'Phase 1: Verifying archive volume integrity...' -ForegroundColor Yellow
        $csvHashes = @(Import-Csv -Path $csvPath)
        $archiveValid = $true
        foreach ($row in $csvHashes) {
            if (-not ($row.FilePath.StartsWith("$currentFolderName.zip") -or $row.FilePath.StartsWith("$currentFolderName.7z"))) { continue }
            if (Test-Path ".\$($row.FilePath)") {
                $calc = (Get-FileHash -Path ".\$($row.FilePath)" -Algorithm SHA256).Hash
                if ($calc -ne $row.Hash) { $archiveValid = $false; Write-Host "BAD HASH: $($row.FilePath)" -ForegroundColor Red }
                else { Write-Host "INTEGRITY OK: $($row.FilePath)" -ForegroundColor Green }
            } else { $archiveValid = $false; Write-Host "MISSING VOLUME: $($row.FilePath)" -ForegroundColor Red }
        }

        if (-not $archiveValid) {
            Write-Host 'ERROR: Archive is corrupted or incomplete! Unpacking aborted.' -ForegroundColor Red
            Read-Host 'Press ENTER to return to menu'; continue
        }

        $firstVolume = Get-ChildItem -Path $targetDir -File | Where-Object { 
            $_.Name -eq "$currentFolderName.zip" -or 
            $_.Name -eq "$currentFolderName.7z" -or 
            $_.Name -eq "$currentFolderName.zip.001" -or 
            $_.Name -eq "$currentFolderName.7z.001"
        } | Select-Object -First 1

        if (-not $firstVolume) {
            Write-Host 'ERROR: No matching archive file found to unpack!' -ForegroundColor Red
            Read-Host 'Press ENTER to return to menu'; continue
        }

        Write-Host 'Phase 2: Unpacking archive via 7-Zip...' -ForegroundColor Yellow
        $args7z = @('x', $firstVolume.FullName, "-o$targetDir", '-y')
        & $exe7z $args7z
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Host "ERROR: 7-Zip failed during extraction (Code: $exitCode)." -ForegroundColor Red
            Read-Host 'Press ENTER to return to menu'; continue
        }

        Write-Host 'Extraction successful!' -ForegroundColor Green
        
        # ШАГ 2: Автоматическая сверка распакованных файлов по базе оригинальных хешей
        $origCsvPath = '.\OriginalHashes.csv'
        if (Test-Path $origCsvPath) {
            Write-Host ''
            Write-Host 'Phase 3: Verifying extracted files against original hashes...' -ForegroundColor Yellow
            $origHashes = @(Import-Csv -Path $origCsvPath)
            $extractionValid = $true
            foreach ($row in $origHashes) {
                if (Test-Path ".\$($row.FilePath)") {
                    $calc = (Get-FileHash -Path ".\$($row.FilePath)" -Algorithm SHA256).Hash
                    if ($calc -ne $row.Hash) {
                        $extractionValid = $false
                        Write-Host "EXTRACTION CORRUPTED: $($row.FilePath)" -ForegroundColor Red
                    } else {
                        Write-Host "EXTRACTION OK: $($row.FilePath)" -ForegroundColor Green
                    }
                } else {
                    $extractionValid = $false
                    Write-Host "EXTRACTION MISSING FILE: $($row.FilePath)" -ForegroundColor Red
                }
            }
            if ($extractionValid) {
                Write-Host 'PERFECT! All extracted files match the original hashes exactly.' -ForegroundColor Green
            } else {
                Write-Host 'WARNING: Errors detected during extraction check! Some files do not match originals.' -ForegroundColor Red
            }
        } else {
            Write-Host 'OriginalHashes.csv not found, skipping extraction integrity check.' -ForegroundColor Yellow
        }

        Write-Host ''
        $deleteArchive = Read-Host 'Delete archive volumes and database file? (Y - Delete / N - Move to timestamped backup folder, default: N)'
        
        $archFilesToProcess = Get-ChildItem -Path $targetDir -File | Where-Object { $_.Name.StartsWith("$currentFolderName.") }
        
        if ($deleteArchive -like 'y*') {
            Write-Host 'Deleting archive files...' -ForegroundColor Yellow
            foreach ($af in $archFilesToProcess) { Remove-Item $af.FullName -Force }
            if (Test-Path '.\FileHashes.csv') { Remove-Item '.\FileHashes.csv' -Force }
            Write-Host 'Archive cleanup complete.' -ForegroundColor Green
        } else {
            $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
            $backupFolder = Join-Path $targetDir "_archive_backup_$timestamp"
            
            if (-not (Test-Path $backupFolder)) { New-Item -Path $backupFolder -ItemType Directory | Out-Null }
            Write-Host ("Moving archive files to {0}..." -f (Split-Path $backupFolder -Leaf)) -ForegroundColor Yellow
            
            foreach ($af in $archFilesToProcess) {
                Move-Item $af.FullName -Destination $backupFolder -Force
            }
            if (Test-Path '.\FileHashes.csv') {
                Move-Item '.\FileHashes.csv' -Destination $backupFolder -Force
            }
            Write-Host ("Archive safely stored in unique directory: {0}" -f (Split-Path $backupFolder -Leaf)) -ForegroundColor Green
        }
        
        Optimize-BackupFolderStructure
        Read-Host 'Press ENTER to return to menu'
    }
}
