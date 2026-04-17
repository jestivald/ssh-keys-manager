# ============================================================
#  SSH Keys Manager for RemnaWave nodes
#  Author: you :)
#  Usage:
#    .\ssh-keys.ps1                 - интерактивное меню
#    .\ssh-keys.ps1 new             - создать ключ(и)
#    .\ssh-keys.ps1 list            - показать все ключи
#    .\ssh-keys.ps1 remove          - удалить ключ
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
    Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Ok($text)    { Write-Host "✓ $text" -ForegroundColor Green }
function Write-Err($text)   { Write-Host "✗ $text" -ForegroundColor Red }
function Write-Info($text)  { Write-Host "ℹ $text" -ForegroundColor Yellow }

# --- Проверка ssh-keygen ---
function Test-SshKeygen {
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Err "ssh-keygen не найден. Установите OpenSSH Client:"
        Write-Host "  Settings → Apps → Optional features → OpenSSH Client"
        exit 1
    }
}

# --- Получить базовый путь (из конфига или спросить) ---
function Get-BasePath {
    if (Test-Path $ConfigFile) {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.BasePath -and (Test-Path $cfg.BasePath -PathType Container -ErrorAction SilentlyContinue) -or $cfg.BasePath) {
            return $cfg.BasePath
        }
    }
    return $null
}

function Save-BasePath($path) {
    @{ BasePath = $path } | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

function Request-BasePath {
    $saved = Get-BasePath
    $prompt = if ($saved) { "Путь к папке с ключами [$saved]" } else { "Путь к папке с ключами [$DefaultBasePath]" }
    $input = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($input)) {
        $input = if ($saved) { $saved } else { $DefaultBasePath }
    }

    if (-not (Test-Path $input)) {
        $create = Read-Host "Папка не существует. Создать? (Y/n)"
        if ($create -eq '' -or $create -match '^[yYдД]') {
            New-Item -ItemType Directory -Path $input -Force | Out-Null
            Write-Ok "Создана папка: $input"
        } else {
            Write-Err "Отмена."
            exit 1
        }
    }

    Save-BasePath $input
    return $input
}

# --- Валидация имени ноды ---
function Test-NodeName($name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    return $name -match '^[a-zA-Z0-9_-]+$'
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

    # Ed25519 без passphrase (-N "") и с комментарием
    $result = & ssh-keygen -t ed25519 -C $NodeName -f $keyPath -N '""' 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Ошибка генерации: $result"
        return $false
    }

    Write-Ok "Создан ключ: $NodeName"
    Write-Host "   📂 $nodeFolder" -ForegroundColor DarkGray
    Write-Host "   🔐 приватный:  $NodeName" -ForegroundColor DarkGray
    Write-Host "   📤 публичный:  $NodeName.pub" -ForegroundColor DarkGray

    # Копируем публичный ключ в буфер
    Get-Content "$keyPath.pub" | Set-Clipboard
    Write-Info "Публичный ключ скопирован в буфер обмена"

    return $true
}

function Invoke-NewKeys {
    Write-Title "Генерация SSH-ключей"
    $base = Request-BasePath

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
        $created | ForEach-Object { Write-Host "   • $_" -ForegroundColor Green }
        Write-Host ""
        Write-Info "Последний публичный ключ в буфере. Вставляй в панель RemnaWave (Ctrl+V)"
    } else {
        Write-Err "Не создано ни одного ключа."
    }
}

# ============================================================
#  LIST - список всех ключей
# ============================================================
function Invoke-ListKeys {
    Write-Title "Список SSH-ключей"
    $base = Request-BasePath

    $folders = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue
    if (-not $folders -or $folders.Count -eq 0) {
        Write-Info "Ключей пока нет. Создай первый: .\ssh-keys.ps1 new"
        return
    }

    $total = 0
    foreach ($folder in $folders) {
        $keyFile    = Join-Path $folder.FullName $folder.Name
        $pubKeyFile = "$keyFile.pub"

        if (Test-Path $keyFile -PathType Leaf) {
            $total++
            Write-Host "  🔑 $($folder.Name)" -ForegroundColor Cyan
            Write-Host "     📂 $($folder.FullName)" -ForegroundColor DarkGray

            if (Test-Path $pubKeyFile) {
                $pub = (Get-Content $pubKeyFile -Raw).Trim()
                # Показываем первые 40 символов ключа + последние 20
                if ($pub.Length -gt 80) {
                    $short = $pub.Substring(0, 40) + "..." + $pub.Substring($pub.Length - 20)
                } else {
                    $short = $pub
                }
                Write-Host "     📤 $short" -ForegroundColor DarkGray
            }
            $created = (Get-Item $keyFile).CreationTime
            Write-Host "     📅 $($created.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    Write-Host "───────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Ok "Всего ключей: $total"
}

# ============================================================
#  REMOVE - удаление ключа
# ============================================================
function Invoke-RemoveKey {
    Write-Title "Удаление SSH-ключа"
    $base = Request-BasePath

    $folders = Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue
    if (-not $folders -or $folders.Count -eq 0) {
        Write-Info "Ключей нет."
        return
    }

    # Показываем нумерованный список
    Write-Host "Доступные ключи:"
    Write-Host ""
    $i = 1
    $map = @{}
    foreach ($folder in $folders) {
        $keyFile = Join-Path $folder.FullName $folder.Name
        if (Test-Path $keyFile -PathType Leaf) {
            Write-Host "  [$i] $($folder.Name)" -ForegroundColor Cyan
            $map[$i] = $folder
            $i++
        }
    }
    Write-Host ""

    $input = Read-Host "Введи номер или имя ключа для удаления (или 'q' для отмены)"
    if ($input -eq 'q' -or [string]::IsNullOrWhiteSpace($input)) {
        Write-Info "Отмена."
        return
    }

    # Номер или имя?
    $target = $null
    if ($input -match '^\d+$' -and $map.ContainsKey([int]$input)) {
        $target = $map[[int]$input]
    } else {
        $target = $folders | Where-Object { $_.Name -eq $input } | Select-Object -First 1
    }

    if (-not $target) {
        Write-Err "Ключ не найден."
        return
    }

    Write-Host ""
    Write-Host "Будет удалена папка: $($target.FullName)" -ForegroundColor Yellow
    $confirm = Read-Host "Точно удалить '$($target.Name)'? (y/N)"

    if ($confirm -match '^[yYдД]') {
        Remove-Item -Path $target.FullName -Recurse -Force
        Write-Ok "Удалено: $($target.Name)"
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
    Write-Host "  ╔═══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║     SSH Keys Manager (RemnaWave)      ║" -ForegroundColor Cyan
    Write-Host "  ╚═══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   [1] Создать ключ(и)" -ForegroundColor White
    Write-Host "   [2] Список ключей" -ForegroundColor White
    Write-Host "   [3] Удалить ключ" -ForegroundColor White
    Write-Host "   [q] Выход" -ForegroundColor DarkGray
    Write-Host ""
    $choice = Read-Host "   Выбор"

    switch ($choice) {
        '1' { Invoke-NewKeys }
        '2' { Invoke-ListKeys }
        '3' { Invoke-RemoveKey }
        'q' { return $false }
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
        Write-Host "Пока!" -ForegroundColor Cyan
    }
}
