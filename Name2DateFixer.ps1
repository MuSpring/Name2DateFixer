<#
.SYNOPSIS
    Name2DateFixer - 智能还原照片与视频的拍摄时间。
.DESCRIPTION
    使用 ExifTool 批量处理图片和视频文件，智能处理 EXIF 日期信息
    1. 优先检查文件是否已包含有效的 EXIF 日期标签，有则直接复制到输出目录
    2. 无有效日期则尝试从文件名提取日期时间或 Unix 时间戳并写入
    3. 处理成功保留在输出目录，失败移动到复核目录
.NOTES
    Developed with ❤️ and AI Collaboration.
    This work is licensed under GPL v3.
#>

# =============================================================================
# 基于脚本所在目录生成配置
# =============================================================================
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptRoot) { $ScriptRoot = Get-Location }

$WorkDir    = Join-Path $ScriptRoot "Input"
$OutputDir  = Join-Path $ScriptRoot "Output"
$ReviewDir  = Join-Path $ScriptRoot "Review"
$LogDir     = Join-Path $ScriptRoot "Logs"

# 支持的文件扩展名
$ImageExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tiff", ".tif", ".heic", ".webp")
$VideoExtensions = @(".mp4", ".mov", ".avi", ".mkv", ".m4v", ".3gp", ".wmv", ".flv")
$AllExtensions   = $ImageExtensions + $VideoExtensions

# ExifTool 可执行文件路径
$ExifToolPath = "D:\Software\Exiftool\exiftool-13.54_64\exiftool.exe"

# =============================================================================
# 初始化
# =============================================================================
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
$ProgressPreference = 'SilentlyContinue'

# 创建必要目录
foreach ($dir in @($WorkDir, $OutputDir, $ReviewDir, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "已创建目录: $dir" -ForegroundColor Yellow
    }
}

# 日志
$LogTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDir "ExifTool_Process_$LogTimestamp.log"

$script:SuccessCount = 0
$script:FailCount = 0

# =============================================================================
# 日志函数
# =============================================================================
function Write-Log {
    param([string]$Level, [string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    
    Write-Host $logEntry -ForegroundColor $color
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
}

function Test-ExifTool {
    try {
        $null = & $ExifToolPath -ver 2>$null
        return $true
    } catch {
        return $false
    }
}

# =============================================================================
# 检查已有有效日期
# =============================================================================
function Test-ExistingAnyDate {
    param([string]$FilePath)
    
    # 1. 创建临时参数文件，用于规避中文路径乱码
    $tmpArgs = [System.IO.Path]::GetTempFileName()
    
    try {
        $argsList = @(
            "-charset", "filename=utf8",
            "-n",
            "-s3",
            "-DateTimeOriginal",
            "-CreateDate",
            "-ModifyDate",
            "-MediaCreateDate",
            "-TrackCreateDate",
            $FilePath
        )

        # 2. 将参数以 UTF-8 (无 BOM) 格式写入临时文件
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllLines($tmpArgs, $argsList, $utf8NoBom)

        # 3. 调用 ExifTool，使用 -@ 参数读取临时文件
        $output = & $ExifToolPath -@ $tmpArgs 2>$null
        
        if ($output) {
            foreach ($line in $output) {
                $line = $line.Trim()
                if (-not $line) { continue }
                
                $isValid = $false
                $year = $month = $day = $hour = $minute = $second = 0
                
                # 匹配多种可能的日期格式
                if ($line -match '^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})') {
                    $year = [int]$Matches[1]; $month = [int]$Matches[2]; $day = [int]$Matches[3]
                    $hour = [int]$Matches[4]; $minute = [int]$Matches[5]; $second = [int]$Matches[6]
                    $isValid = $true
                }
                elseif ($line -match '^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})') {
                    $year = [int]$Matches[1]; $month = [int]$Matches[2]; $day = [int]$Matches[3]
                    $hour = [int]$Matches[4]; $minute = [int]$Matches[5]; $second = [int]$Matches[6]
                    $isValid = $true
                }
                elseif ($line -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})') {
                    $year = [int]$Matches[1]; $month = [int]$Matches[2]; $day = [int]$Matches[3]
                    $hour = [int]$Matches[4]; $minute = [int]$Matches[5]; $second = [int]$Matches[6]
                    $isValid = $true
                }
                
                # 验证提取到的日期数值是否合理
                if ($isValid) {
                    # 排除全 0 的无效日期（如 0000:00:00）
                    if ($year -eq 0 -and $month -eq 0 -and $day -eq 0) { continue }
                    
                    # 限制年份范围，通常 1980 年以前的照片很少见，可能是占位符
                    $currentYear = (Get-Date).Year
                    if ($year -gt 1980 -and $year -le ($currentYear + 1)) {
                        if ($month -ge 1 -and $month -le 12 -and $day -ge 1 -and $day -le 31) {
                            try {
                                # 尝试解析为 PowerShell 日期对象进行最后的合法性校验
                                $dummyDate = Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $minute -Second $second -ErrorAction Stop
                                Write-Log "INFO" "  文件已有有效日期: $($dummyDate.ToString('yyyy-MM-dd HH:mm:ss'))"
                                return $true
                            } catch { }
                        }
                    }
                }
            }
        }
        return $false
    } catch {
        Write-Log "ERROR" "  读取 EXIF 失败: $($_.Exception.Message)"
        return $false
    } finally {
        # 4. 无论成功失败，必须清理临时文件
        if (Test-Path $tmpArgs) { Remove-Item $tmpArgs -Force -ErrorAction SilentlyContinue }
    }
}

# =============================================================================
# 尝试从文件名提取日期
# =============================================================================
function Get-DateFromFileName {
    param([string]$FileName)
    
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)

    # 原有完整时间模式
    $patterns = @(
        @{ Pattern = '(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})' },
        @{ Pattern = '(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})' },
        @{ Pattern = '(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})' },
        @{ Pattern = '(\d{4})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})' },
@{ Pattern = '(\d{4})[-_](\d{2})[-_](\d{2})[-_](\d{2})[-_](\d{2})[-_](\d{2})' },
        @{ Pattern = '(\d{4})-(\d{2})-(\d{2})[ \.]+(\d{2})\.(\d{2})\.(\d{2})' }
    )

    # 先尝试完整时间
    foreach ($p in $patterns) {
        if ($baseName -match $p.Pattern) {
            try {
                $year   = [int]$Matches[1]
                $month  = [int]$Matches[2]
                $day    = [int]$Matches[3]
                $hour   = [int]$Matches[4]
                $minute = [int]$Matches[5]
                $second = [int]$Matches[6]
                
                if ($month -lt 1 -or $month -gt 12) { continue }
                if ($day -lt 1 -or $day -gt 31) { continue }
                if ($hour -gt 23 -or $minute -gt 59 -or $second -gt 59) { continue }
                
                return Get-Date -Year $year -Month $month -Day $day -Hour $hour -Minute $minute -Second $second -ErrorAction Stop
            } catch { continue }
        }
    }

    $dateOnlyPatterns = @(
        @{ Pattern = '(\d{4})(\d{2})(\d{2})' },
        @{ Pattern = '(\d{4})-(\d{2})-(\d{2})' },
        @{ Pattern = '(\d{4})_(\d{2})_(\d{2})' }
    )

    foreach ($p in $dateOnlyPatterns) {
        if ($baseName -match $p.Pattern) {
            try {
                $year  = [int]$Matches[1]
                $month = [int]$Matches[2]
                $day   = [int]$Matches[3]
                
                if ($year -le 1980 -or $year -gt (Get-Date).Year + 1) { continue }
                if ($month -lt 1 -or $month -gt 12) { continue }
                if ($day -lt 1 -or $day -gt 31) { continue }

                return Get-Date -Year $year -Month $month -Day $day -Hour 0 -Minute 0 -Second 0 -ErrorAction Stop
            } catch { continue }
        }
    }

    return $null
}

# =============================================================================
# 尝试从Unix 13位时间戳提取日期
# =============================================================================
function Get-DateFromUnixTimestamp {
    param([string]$FileName)
    
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    
    if ($baseName -match '(\d{13})') {
        $timestamp = [long]$Matches[1]
        if ($timestamp -gt 946684800000 -and $timestamp -lt 4102444800000) {
            try {
                $unixEpoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, 0, [System.DateTimeKind]::Utc)
                $utcTime = $unixEpoch.AddMilliseconds($timestamp)
                return $utcTime.ToLocalTime()
            } catch { return $null }
        }
    }
    return $null
}

# =============================================================================
# ExifTool 写入
# =============================================================================
function Write-DateWithExifTool {
    param([string]$FilePath, [DateTime]$DateTime)
    
    $tmpArgs = [System.IO.Path]::GetTempFileName()
    try {
        $exifDateStr = $DateTime.ToString("yyyy:MM:dd HH:mm:ss")
        $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
        $isVideo = $VideoExtensions -contains $ext
        
        # 构建参数列表
        $argsList = @("-charset", "filename=utf8")
        if ($isVideo) {
            $timeZoneOffset = [System.DateTimeOffset]::Now.Offset.ToString('hh\:mm')
            $offsetSign = if ([System.DateTimeOffset]::Now.Offset.Ticks -ge 0) { "+" } else { "-" }
            $finalOffset = "$offsetSign$timeZoneOffset"
            $argsList += @("-api", "QuickTimeUTC=1", "-AllDates=$exifDateStr$finalOffset", "-TrackCreateDate=$exifDateStr$finalOffset", "-MediaCreateDate=$exifDateStr$finalOffset")
        } else {
            $argsList += @("-DateTimeOriginal=$exifDateStr", "-CreateDate=$exifDateStr", "-ModifyDate=$exifDateStr")
            if ($ext -in @(".gif", ".png", ".bmp", ".webp")) {
                $argsList += @("-FileModifyDate=$exifDateStr", "-FileCreateDate=$exifDateStr")
            }
        }
        $argsList += @("-overwrite_original", $FilePath)

        # 将所有参数（包括含中文的路径）以 UTF8 (无BOM) 写入临时文件
        [System.IO.File]::WriteAllLines($tmpArgs, $argsList, (New-Object System.Text.UTF8Encoding $false))

        # 调用 ExifTool，通过 -@ 读入参数文件
        $result = & $ExifToolPath -@ $tmpArgs 2>&1
        
        if ($LASTEXITCODE -eq 0 -and ($result -match "updated|image files")) {
            return $true
        } else {
            Write-Log "WARN" "  ExifTool 写入失败: $result"
            return $false
        }
    } catch {
        Write-Log "ERROR" "  ExifTool 异常: $($_.Exception.Message)"
        return $false
    } finally {
        if (Test-Path $tmpArgs) { Remove-Item $tmpArgs -ErrorAction SilentlyContinue }
    }
}

# =============================================================================
# 错误重试
# =============================================================================
function Copy-FileWithRetry {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$RetryCount = 3
    )
    
    for ($i = 1; $i -le $RetryCount; $i++) {
        try {
            Copy-Item -Path $Source -Destination $Destination -Force -ErrorAction Stop
            $srcSize = (Get-Item $Source -Force).Length
            $destSize = (Get-Item $Destination -Force).Length
            if ($srcSize -eq $destSize) { return $true }
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

# =============================================================================
# 处理文件
# =============================================================================
function Process-File {
    param(
        [System.IO.FileInfo]$File,
        [string]$RelativePath
    )
    
    $fileName = $File.Name
    $ext = $File.Extension.ToLower()
    
    Write-Log "INFO" "处理文件: $(if ($RelativePath) { "$RelativePath\$fileName" } else { $fileName })"
    
    $targetSubDir = Join-Path $OutputDir $RelativePath
    if (-not (Test-Path $targetSubDir)) { New-Item -ItemType Directory $targetSubDir -Force | Out-Null }
    $targetFilePath = Join-Path $targetSubDir $fileName
    
    if (-not (Copy-FileWithRetry -Source $File.FullName -Destination $targetFilePath)) {
        Write-Log "ERROR" "  复制失败（文件占用/损坏）"
        $script:FailCount++
        return
    }
    Write-Log "INFO" "  已复制到: $targetFilePath"
    
    if (Test-ExistingAnyDate -FilePath $targetFilePath) {
        Write-Log "SUCCESS" "  ✓ 文件已包含有效日期信息，无需写入"
        $script:SuccessCount++
        Write-Log "INFO" "----------------------------------------"
        return
    }
    
    $extractedDate = $null
    $dateFromName = Get-DateFromFileName -FileName $fileName
    if ($dateFromName) {
        $extractedDate = $dateFromName
        Write-Log "INFO" "  从文件名提取: $($extractedDate.ToString('yyyy-MM-dd HH:mm:ss'))"
    } else {
        $dateFromUnix = Get-DateFromUnixTimestamp -FileName $fileName
        if ($dateFromUnix) {
            $extractedDate = $dateFromUnix
            Write-Log "INFO" "  从 Unix 时间戳提取: $($extractedDate.ToString('yyyy-MM-dd HH:mm:ss'))"
        }
    }
    
    if ($extractedDate) {
        $now = Get-Date
        if ($extractedDate.Year -lt 1990) {
            Write-Log "WARN" "  提取的时间早于 1990 年，视为无效"
            $extractedDate = $null
        }
    }
    
    $writeSuccess = $false
    if ($extractedDate) {
        Write-Log "INFO" "  使用 ExifTool 写入元数据..."
        $writeSuccess = Write-DateWithExifTool -FilePath $targetFilePath -DateTime $extractedDate
    } else {
        Write-Log "WARN" "  无法从文件名提取任何有效时间信息"
    }
    
    if ($writeSuccess) {
        Write-Log "SUCCESS" "  ✓ 处理成功"
        $script:SuccessCount++
    } else {
        $reviewSubDir = Join-Path $ReviewDir $RelativePath
        if (-not (Test-Path $reviewSubDir)) { New-Item -ItemType Directory $reviewSubDir -Force | Out-Null }
        $reviewFilePath = Join-Path $reviewSubDir $fileName
        
        try {
            Move-Item -Path $targetFilePath -Destination $reviewFilePath -Force -ErrorAction Stop
            Write-Log "WARN" "  ✗ 处理失败，已移至复核目录"
        } catch {
            Write-Log "ERROR" "  移动失败: $($_.Exception.Message)"
        }
        $script:FailCount++
    }
    
    Write-Log "INFO" "----------------------------------------"
}

# =============================================================================
# 主程序
# =============================================================================
function Main {
    Write-Log "INFO" "========================================"
    Write-Log "INFO" "Name2DateFixer 0.1"
    Write-Log "INFO" "脚本位置: $ScriptRoot"
    Write-Log "INFO" "工作目录: $WorkDir"
    Write-Log "INFO" "输出目录: $OutputDir"
    Write-Log "INFO" "复核目录: $ReviewDir"
    Write-Log "INFO" "========================================"
    
    if (-not (Test-ExifTool)) {
        Write-Log "ERROR" "ExifTool 未找到！请检查路径"
        Write-Host "`n按任意键退出..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    Write-Log "INFO" "ExifTool 版本: $(& $ExifToolPath -ver)"
    
    $allFiles = Get-ChildItem -Path $WorkDir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $AllExtensions -contains $_.Extension.ToLower() -and
        $_.Length -ge 1024 -and
        $_.Name -notmatch '_original\.' -and
        $_.Name -notmatch '^\._' -and
        $_.Name -notmatch '^thumbs\.db' -and
        $_.Name -notmatch '^desktop\.ini'
    }
    
    $totalFiles = $allFiles.Count
    Write-Log "INFO" "找到 $totalFiles 个文件待处理"
    
    if ($totalFiles -eq 0) {
        Write-Log "INFO" "工作目录内没有可处理的文件。"
        Write-Host "`n请将文件放入: $WorkDir" -ForegroundColor Yellow
        Write-Host "`n按任意键退出..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return
    }
    
    foreach ($file in $allFiles) {
        $relativePath = ""
        if ($file.DirectoryName.Length -gt $WorkDir.Length) {
            $relativePath = $file.DirectoryName.Substring($WorkDir.Length).TrimStart('\', '/')
        }
        Process-File -File $file -RelativePath $relativePath
    }
    
    Write-Log "INFO" "========================================"
    Write-Log "INFO" "处理完成！"
    Write-Log "INFO" "总计: $totalFiles 个文件"
    Write-Log "SUCCESS" "成功: $script:SuccessCount 个"
    Write-Log "WARN" "需复核: $script:FailCount 个"
    Write-Log "INFO" "日志: $LogFile"
    Write-Log "INFO" "========================================"
    
    Write-Host "`n处理完成！按任意键退出..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Main