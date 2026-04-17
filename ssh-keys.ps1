# ============================================================
#  SSH Keys Manager for RemnaWave nodes
#
#  Запуск локально:
#    .\ssh-keys.ps1
#    .\ssh-keys.ps1 new / list / remove
#
#  Запуск напрямую с GitHub (без скачивания):
#    irm https://raw.githubusercontent.com/jestivald/ssh-keys-manager/main/ssh-keys.ps1 | iex
# ============================================================

param(
    [Parameter(Position = 0)]
    [ValidateSet('new', 'list', 'remove', 'menu')]
    [string]$Action = 'menu'
)

# --- Настройки по умолчанию ---
$DefaultBasePath = "$env:USERPROFILE\Desktop\ssh-keys"
$ConfigFile = "$env:USERPROFILE\.ssh-keys-manager.json"

# --- Цвета и утилиты вывода ---
function Write-Title($text) {
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "===========================================" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Ok($text)    { Write-Host "[OK] $text" -ForegroundColor Green }
function Write-Err($text)   { Write-Host "[ERR] $text" -ForegroundColor Red }
function Write-Info($text)  { Write-Host "[i] $text" -ForegroundColor Yellow }

# --- Проверка ssh-keygen ---
function Test-SshKeygen {
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Err "ssh-keygen не найден. Установите OpenSSH Client:"
        Write-Host "  Settings -> Apps -> Optional features -> OpenSSH Client"
        exit 1
    }
}

# --- Работа с конфигом ---
function Get-BasePath {
    if (Test-Path $ConfigFile) {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.BasePath) { return $cfg.BasePath }
    }
    return $null
}

function Save-BasePath($path) {
    @{ BasePath = $path } | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

function Request-BasePath {
    $saved = Get-BasePath
    $prompt = if ($saved) { "Путь к папке с ключами [$saved]" } else { "Путь к папке с ключами [$DefaultBasePath]" }
    $userInput = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        $userInput = if ($saved) { $saved } else { $DefaultBasePath }
    }

    if (-not (Test-Path $userInput)) {
        $create = Read-Host "Папка не существует. Создать? (Y/n)"
        if ($create -eq '' -or $create -match '^[yYдД]') {
            New-Item -ItemType Directory -Path $userInput -Force | Out-Null
            Write-Ok "Создана папка: $userInput"
        } else {
            Write-Err "Отмена."
            return $null
        }
    }

    Save-BasePath $userInput
    return $userInput
}

# --- Валидация имени ноды ---
function Test-NodeName($name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    return $name -match '^[a-zA-Z0-9_-]+$'
}

# ============================================================
#  УНИВЕРСАЛЬНЫЙ ПОИСК КЛЮЧЕЙ
# ============================================================
function Find-AllSshKeys {
    param([string]$BasePath)

    $keys = @()
    $pubFiles = Get-ChildItem -Path $BasePath -Filter "*.pub" -File -Recurse -ErrorAction SilentlyContinue

    foreach ($pub in $pubFiles) {
        $privatePath = $pub.FullName.Substring(0, $pub.FullName.Length - 4)
        $hasPrivate = Test-Path $privatePath -PathType Leaf

        $content = (Get-Content $pub.FullName -Raw -ErrorAction SilentlyContinue).Trim()
        $keyType = "unknown"
        if ($content -match '^ssh-ed25519') { $keyType = "ed25519" }
        elseif ($content -match '^ssh-rsa') { $keyType = "rsa" }
        elseif ($content -match '^ecdsa-') { $keyType = "ecdsa" }
        elseif ($content -match '^ssh-dss') { $keyType = "dsa" }

        $parentFolder = Split-Path $pub.DirectoryName -Leaf
        $baseFolderName = Split-Path $BasePath -Leaf
        $location = if ($parentFolder -eq $baseFolderName -or $pub.DirectoryName -eq $BasePath) { "(корень)" } else { $parentFolder }

        $keys += [PSCustomObject]@{
            Name          = $pub.BaseName
            Location      = $location
            ParentFolder  = $pub.DirectoryName
            PubPath       = $pub.FullName
            PrivatePath   = $privatePath
            HasPrivate    = $hasPrivate
            KeyType       = $keyType
            Content       = $content
            Created       = if ($hasPrivate) { (Get-Item $privatePath).CreationTime } else { $pub.CreationTime }
        }
    }

    return $keys | Sort-Object Created -Descending
}

# ============================================================
#  NEW - генерация ключей
# ============================================================
function New-SshKey {
    param(
        [string]$BasePath,
        [string]$NodeName
    )

    if (-not (Test-NodeName $NodeName)) {
        Write-Err "Недопустимое имя '$NodeName'. Разрешены: буквы, цифры, - и _"
        return $false
    }

    $nodeFolder = Join-Path $BasePath $NodeName
    $keyPath    = Join-Path $nodeFolder $NodeName

    if (Test-Path $keyPath) {
        Write-Err "Ключ '$NodeName' уже существует в $nodeFolder"
        return $false
    }

    New-Item -ItemType Directory -Path $nodeFolder -Force | Out-Null
    $result = & ssh-keygen -t ed25519 -C $NodeName -f $keyPath -N '""' 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Ошибка генерации: $result"
        return $false
    }

    Write-Ok "Создан ключ: $NodeName"
    Write-Host "   Папка:     $nodeFolder" -ForegroundColor DarkGray
    Write-Host "   Приватный: $NodeName" -ForegroundColor DarkGray
    Write-Host "   Публичный: $NodeName.pub" -ForegroundColor DarkGray

    Get-Content "$keyPath.pub" | Set-Clipboard
    Write-Info "Публичный ключ скопирован в буфер обмена"

    return $true
}

function Invoke-NewKeys {
    Write-Title "Генерация SSH-ключей"
    $base = Request-BasePath
    if (-not $base) { return }

    $count = Read-Host "Сколько ключей создать? [1]"
    if ([string]::IsNullOrWhiteSpace($count)) { $count = 1 }
    if (-not ($count -match '^\d+$') -or [int]$count -lt 1) {
        Write-Err "Нужно положительное число."
        return
    }
    $count = [int]$count

    Write-Host ""
    $created = @()
    for ($i = 1; $i -le $count; $i++) {
        $name = Read-Host "[$i/$count] Имя ноды (например ru-node)"
        if (New-SshKey -BasePath $base -NodeName $name) {
            $created += $name
        }
        Write-Host ""
    }

    Write-Title "Готово"
    if ($created.Count -gt 0) {
        Write-Ok "Создано ключей: $($created.Count)"
        $created | ForEach-Object { Write-Host "   - $_" -ForegroundColor Green }
        Write-Host ""
        Write-Info "Последний публичный ключ в буфере. Вставляй в панель RemnaWave (Ctrl+V)"
    } else {
        Write-Err "Не создано ни одного ключа."
    }
}

# ============================================================
#  LIST - показывает ВСЕ ключи
# ============================================================
function Invoke-ListKeys {
    Write-Title "Список SSH-ключей"
    $base = Request-BasePath
    if (-not $base) { return }

    $keys = Find-AllSshKeys -BasePath $base

    if (-not $keys -or $keys.Count -eq 0) {
        Write-Info "Ключей пока нет. Создай первый через меню."
        return
    }

    $i = 1
    foreach ($key in $keys) {
        $typeTag = "[$($key.KeyType)]"
        $warning = if (-not $key.HasPrivate) { " [только публичный!]" } else { "" }

        Write-Host "  [$i] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($key.Name) " -ForegroundColor Cyan -NoNewline
        Write-Host "$typeTag" -ForegroundColor DarkYellow -NoNewline
        Write-Host " $($key.Location)" -ForegroundColor DarkGray -NoNewline
        Write-Host "$warning" -ForegroundColor Red

        $pub = $key.Content
        if ($pub.Length -gt 80) {
            $short = $pub.Substring(0, 40) + "..." + $pub.Substring($pub.Length - 20)
        } else {
            $short = $pub
        }
        Write-Host "      $short" -ForegroundColor DarkGray
        Write-Host "      $($key.Created.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor DarkGray
        Write-Host "      $($key.PubPath)" -ForegroundColor DarkGray
        Write-Host ""

        $i++
    }

    Write-Host "-------------------------------------------" -ForegroundColor DarkGray
    Write-Ok "Всего ключей: $($keys.Count)"
}

# ============================================================
#  REMOVE - удаляет любой ключ
# ============================================================
function Invoke-RemoveKey {
    Write-Title "Удаление SSH-ключа"
    $base = Request-BasePath
    if (-not $base) { return }

    $keys = Find-AllSshKeys -BasePath $base

    if (-not $keys -or $keys.Count -eq 0) {
        Write-Info "Ключей нет."
        return
    }

    Write-Host "Доступные ключи:"
    Write-Host ""
    $i = 1
    $map = @{}
    foreach ($key in $keys) {
        $typeTag = "[$($key.KeyType)]"
        Write-Host "  [$i] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($key.Name) " -ForegroundColor Cyan -NoNewline
        Write-Host "$typeTag" -ForegroundColor DarkYellow -NoNewline
        Write-Host " $($key.Location)" -ForegroundColor DarkGray
        $map[$i] = $key
        $i++
    }
    Write-Host ""

    $userInput = Read-Host "Введи номер или имя ключа для удаления (0 для отмены)"
    if ($userInput -eq '0' -or [string]::IsNullOrWhiteSpace($userInput)) {
        Write-Info "Отмена."
        return
    }

    $target = $null
    if ($userInput -match '^\d+$' -and $map.ContainsKey([int]$userInput)) {
        $target = $map[[int]$userInput]
    } else {
        $target = $keys | Where-Object { $_.Name -eq $userInput } | Select-Object -First 1
    }

    if (-not $target) {
        Write-Err "Ключ не найден."
        return
    }

    Write-Host ""
    Write-Host "Ключ: $($target.Name)" -ForegroundColor Yellow
    Write-Host "Публичный:  $($target.PubPath)" -ForegroundColor DarkGray
    if ($target.HasPrivate) {
        Write-Host "Приватный:  $($target.PrivatePath)" -ForegroundColor DarkGray
    }

    $parentFolder = $target.ParentFolder
    $filesInFolder = Get-ChildItem -Path $parentFolder -File -ErrorAction SilentlyContinue

    $removeFolder = $false
    if ($parentFolder -ne $base) {
        $keyFiles = @($target.PubPath)
        if ($target.HasPrivate) { $keyFiles += $target.PrivatePath }
        $otherFiles = $filesInFolder | Where-Object { $_.FullName -notin $keyFiles }
        if (-not $otherFiles -or $otherFiles.Count -eq 0) {
            $removeFolder = $true
            Write-Host "Будет удалена папка целиком: $parentFolder" -ForegroundColor Yellow
        } else {
            Write-Info "В папке есть другие файлы, удалим только ключи."
        }
    }

    $confirm = Read-Host "Точно удалить '$($target.Name)'? (y/N)"

    if ($confirm -match '^[yYдД]') {
        try {
            if ($removeFolder) {
                Remove-Item -Path $parentFolder -Recurse -Force
                Write-Ok "Удалена папка и ключ: $($target.Name)"
            } else {
                Remove-Item -Path $target.PubPath -Force -ErrorAction SilentlyContinue
                if ($target.HasPrivate) {
                    Remove-Item -Path $target.PrivatePath -Force -ErrorAction SilentlyContinue
                }
                Write-Ok "Удалены файлы ключа: $($target.Name)"
            }
        } catch {
            Write-Err "Ошибка при удалении: $_"
        }
    } else {
        Write-Info "Отмена."
    }
}

# ============================================================
#  Интерактивное меню
# ============================================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  +---------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |     SSH Keys Manager (RemnaWave)      |" -ForegroundColor Cyan
    Write-Host "  +---------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   [1] Создать ключ(и)" -ForegroundColor White
    Write-Host "   [2] Список ключей" -ForegroundColor White
    Write-Host "   [3] Удалить ключ" -ForegroundColor White
    Write-Host "   [0] Выход" -ForegroundColor DarkGray
    Write-Host ""
    $choice = Read-Host "   Выбор"

    switch ($choice) {
        '1' { Invoke-NewKeys }
        '2' { Invoke-ListKeys }
        '3' { Invoke-RemoveKey }
        '0' { return $false }
        ''  { return $false }
        default { Write-Err "Неверный выбор." }
    }

    Write-Host ""
    Read-Host "Нажми Enter чтобы вернуться в меню"
    return $true
}

# ============================================================
#  Точка входа
# ============================================================
Test-SshKeygen

switch ($Action) {
    'new'    { Invoke-NewKeys }
    'list'   { Invoke-ListKeys }
    'remove' { Invoke-RemoveKey }
    'menu'   {
        while (Show-Menu) { }
        Write-Host ""
        Write-Host "Пока!" -ForegroundColor Cyan
    }
}
