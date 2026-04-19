# ============================================================
#  SSH Keys Manager for RemnaWave nodes
#
#  Запуск локально:
#    .\ssh-keys.ps1
#    .\ssh-keys.ps1 new / list / remove / config / deploy
#
#  Запуск напрямую с GitHub (без скачивания):
#    irm https://raw.githubusercontent.com/jestivald/ssh-keys-manager/main/ssh-keys.ps1 | iex
# ============================================================

param(
    [Parameter(Position = 0)]
    [ValidateSet('new', 'list', 'remove', 'config', 'deploy', 'menu')]
    [string]$Action = 'menu',

    [switch]$Passphrase
)

# --- Пути ---
$DefaultBasePath = "$env:USERPROFILE\Desktop\ssh-keys"
$ConfigDir       = "$env:APPDATA\ssh-keys-manager"
$ConfigFile      = "$ConfigDir\config.json"
$LegacyConfig    = "$env:USERPROFILE\.ssh-keys-manager.json"
$SshConfigPath   = "$env:USERPROFILE\.ssh\config"

# --- Утилиты вывода ---
function Write-Title($text) {
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "===========================================" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Ok($text)   { Write-Host "[OK] $text"  -ForegroundColor Green }
function Write-Err($text)  { Write-Host "[ERR] $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "[i] $text"   -ForegroundColor Yellow }

function Test-SshKeygen {
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Err "ssh-keygen не найден. Установите OpenSSH Client:"
        Write-Host "  Settings -> Apps -> Optional features -> OpenSSH Client"
        exit 1
    }
}

# --- Конфиг ---
function Get-Config {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    if ((-not (Test-Path $ConfigFile)) -and (Test-Path $LegacyConfig)) {
        Move-Item -Path $LegacyConfig -Destination $ConfigFile -Force
    }
    if (Test-Path $ConfigFile) {
        return Get-Content $ConfigFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Save-Config($cfg) {
    if (-not (Test-Path $ConfigDir)) {
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
    }
    $cfg | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8
}

function Get-BasePath {
    $cfg = Get-Config
    if ($cfg -and $cfg.BasePath) { return $cfg.BasePath }
    return $null
}

function Save-BasePath($path) {
    $cfg = Get-Config
    if (-not $cfg) { $cfg = [PSCustomObject]@{ BasePath = $path } }
    else { $cfg | Add-Member -NotePropertyName BasePath -NotePropertyValue $path -Force }
    Save-Config $cfg
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
            Write-Err "Отмена."; return $null
        }
    }
    Save-BasePath $userInput
    return $userInput
}

function Test-NodeName($name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    return $name -match '^[a-zA-Z0-9_-]+$'
}

# ============================================================
#  Поиск ключей
# ============================================================
function Find-AllSshKeys {
    param([string]$BasePath)
    $keys = @()
    $pubFiles = Get-ChildItem -Path $BasePath -Filter "*.pub" -File -Recurse -ErrorAction SilentlyContinue
    foreach ($pub in $pubFiles) {
        $privatePath = $pub.FullName.Substring(0, $pub.FullName.Length - 4)
        $hasPrivate  = Test-Path $privatePath -PathType Leaf
        $content     = (Get-Content $pub.FullName -Raw -ErrorAction SilentlyContinue).Trim()
        $keyType     = "unknown"
        if     ($content -match '^ssh-ed25519') { $keyType = "ed25519" }
        elseif ($content -match '^ssh-rsa')     { $keyType = "rsa" }
        elseif ($content -match '^ecdsa-')      { $keyType = "ecdsa" }
        elseif ($content -match '^ssh-dss')     { $keyType = "dsa" }

        $parentFolder   = Split-Path $pub.DirectoryName -Leaf
        $baseFolderName = Split-Path $BasePath -Leaf
        $location = if ($parentFolder -eq $baseFolderName -or $pub.DirectoryName -eq $BasePath) { "(корень)" } else { $parentFolder }

        $keys += [PSCustomObject]@{
            Name         = $pub.BaseName
            Location     = $location
            ParentFolder = $pub.DirectoryName
            PubPath      = $pub.FullName
            PrivatePath  = $privatePath
            HasPrivate   = $hasPrivate
            KeyType      = $keyType
            Content      = $content
            Created      = if ($hasPrivate) { (Get-Item $privatePath).CreationTime } else { $pub.CreationTime }
        }
    }
    return $keys | Sort-Object Created -Descending
}

function Select-Key {
    param([array]$Keys, [string]$Action = "выбора")
    Write-Host "Доступные ключи:" -ForegroundColor White
    Write-Host ""
    $i = 1; $map = @{}
    foreach ($key in $Keys) {
        Write-Host "  [$i] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($key.Name) " -ForegroundColor Cyan -NoNewline
        Write-Host "[$($key.KeyType)]" -ForegroundColor DarkYellow -NoNewline
        Write-Host " $($key.Location)" -ForegroundColor DarkGray
        $map[$i] = $key; $i++
    }
    Write-Host ""
    $userInput = Read-Host "Введи номер или имя ключа для $Action (0 для отмены)"
    if ($userInput -eq '0' -or [string]::IsNullOrWhiteSpace($userInput)) { return $null }
    if ($userInput -match '^\d+$' -and $map.ContainsKey([int]$userInput)) { return $map[[int]$userInput] }
    return $Keys | Where-Object { $_.Name -eq $userInput } | Select-Object -First 1
}

# ============================================================
#  Генерация
# ============================================================
function Invoke-Keygen {
    param([string]$KeyPath, [string]$Comment, [string]$Pass)
    # Через cmd /c — обходим проблему PowerShell с пустыми кавычками,
    # из-за которой -N '""' превращался в литеральный пароль "".
    $escPass    = $Pass -replace '"', '\"'
    $escComment = $Comment -replace '"', '\"'
    $cmdLine    = "ssh-keygen -t ed25519 -q -C `"$escComment`" -f `"$KeyPath`" -N `"$escPass`""
    & cmd.exe /c $cmdLine 2>&1
    return $LASTEXITCODE
}

function New-SshKey {
    param([string]$BasePath, [string]$NodeName, [string]$Pass)

    if (-not (Test-NodeName $NodeName)) {
        Write-Err "Недопустимое имя '$NodeName'. Разрешены: буквы, цифры, - и _"
        return $null
    }
    $nodeFolder = Join-Path $BasePath $NodeName
    $keyPath    = Join-Path $nodeFolder $NodeName
    if (Test-Path $keyPath) {
        Write-Err "Ключ '$NodeName' уже существует в $nodeFolder"
        return $null
    }

    New-Item -ItemType Directory -Path $nodeFolder -Force | Out-Null
    $result = Invoke-Keygen -KeyPath $keyPath -Comment $NodeName -Pass $Pass
    if ($result -ne 0) {
        Write-Err "Ошибка генерации (код $result)"
        return $null
    }

    Write-Ok "Создан ключ: $NodeName"
    Write-Host "   Папка:     $nodeFolder" -ForegroundColor DarkGray
    $fp = (& ssh-keygen -lf "$keyPath.pub") -replace '\s+', ' '
    Write-Host "   Fingerprint: $fp" -ForegroundColor DarkGray

    Get-Content "$keyPath.pub" | Set-Clipboard
    Write-Info "Публичный ключ скопирован в буфер обмена"

    return [PSCustomObject]@{ Name = $NodeName; KeyPath = $keyPath; PubPath = "$keyPath.pub" }
}

function Read-Passphrase {
    $sec1 = Read-Host "Passphrase (Enter = без пароля)" -AsSecureString
    if ($sec1.Length -eq 0) { return "" }
    $sec2 = Read-Host "Повтори passphrase" -AsSecureString
    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec1))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2))
    if ($p1 -ne $p2) {
        Write-Err "Пароли не совпали."
        return $null
    }
    return $p1
}

function Invoke-NewKeys {
    Write-Title "Генерация SSH-ключей"
    $base = Request-BasePath
    if (-not $base) { return }

    $count = Read-Host "Сколько ключей создать? [1]"
    if ([string]::IsNullOrWhiteSpace($count)) { $count = 1 }
    if (-not ($count -match '^\d+$') -or [int]$count -lt 1) {
        Write-Err "Нужно положительное число."; return
    }
    $count = [int]$count

    $pass = ""
    if ($Passphrase) {
        $pass = Read-Passphrase
        if ($null -eq $pass) { return }
    }

    Write-Host ""
    $created = @()
    for ($i = 1; $i -le $count; $i++) {
        $name = Read-Host "[$i/$count] Имя ноды (например ru-node)"
        $key  = New-SshKey -BasePath $base -NodeName $name -Pass $pass
        if ($key) { $created += $key }
        Write-Host ""
    }

    Write-Title "Готово"
    if ($created.Count -gt 0) {
        Write-Ok "Создано ключей: $($created.Count)"
        $created | ForEach-Object { Write-Host "   - $($_.Name)" -ForegroundColor Green }
        Write-Host ""
        Write-Info "Последний публичный ключ в буфере. Вставляй в панель RemnaWave (Ctrl+V)"

        $extra = Read-Host "Добавить ключ(и) в ~/.ssh/config? (y/N)"
        if ($extra -match '^[yYдД]') {
            foreach ($k in $created) { Invoke-AddToSshConfig -Key $k }
        }
    } else {
        Write-Err "Не создано ни одного ключа."
    }
}

# ============================================================
#  LIST
# ============================================================
function Invoke-ListKeys {
    Write-Title "Список SSH-ключей"
    $base = Request-BasePath; if (-not $base) { return }
    $keys = Find-AllSshKeys -BasePath $base
    if (-not $keys -or $keys.Count -eq 0) {
        Write-Info "Ключей пока нет. Создай первый через меню."; return
    }
    $i = 1
    foreach ($key in $keys) {
        $warn = if (-not $key.HasPrivate) { " [только публичный!]" } else { "" }
        Write-Host "  [$i] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($key.Name) " -ForegroundColor Cyan -NoNewline
        Write-Host "[$($key.KeyType)]" -ForegroundColor DarkYellow -NoNewline
        Write-Host " $($key.Location)" -ForegroundColor DarkGray -NoNewline
        Write-Host "$warn" -ForegroundColor Red

        $pub = $key.Content
        $short = if ($pub.Length -gt 80) { $pub.Substring(0, 40) + "..." + $pub.Substring($pub.Length - 20) } else { $pub }
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
#  REMOVE
# ============================================================
function Invoke-RemoveKey {
    Write-Title "Удаление SSH-ключа"
    $base = Request-BasePath; if (-not $base) { return }
    $keys = Find-AllSshKeys -BasePath $base
    if (-not $keys -or $keys.Count -eq 0) { Write-Info "Ключей нет."; return }

    $target = Select-Key -Keys $keys -Action "удаления"
    if (-not $target) { Write-Info "Отмена."; return }

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
        } catch { Write-Err "Ошибка при удалении: $_" }
    } else { Write-Info "Отмена." }
}

# ============================================================
#  ~/.ssh/config
# ============================================================
function Invoke-AddToSshConfig {
    param($Key)

    $alias = Read-Host "Host alias для '$($Key.Name)' [$($Key.Name)]"
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = $Key.Name }
    $hostName = Read-Host "HostName (IP или домен)"
    if ([string]::IsNullOrWhiteSpace($hostName)) { Write-Err "HostName пуст, отмена."; return }
    $user = Read-Host "User [root]"
    if ([string]::IsNullOrWhiteSpace($user)) { $user = "root" }
    $port = Read-Host "Port [22]"
    if ([string]::IsNullOrWhiteSpace($port)) { $port = "22" }

    $sshDir = Split-Path $SshConfigPath -Parent
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }

    if (Test-Path $SshConfigPath) {
        $existing = Get-Content $SshConfigPath -Raw
        if ($existing -match "(?m)^\s*Host\s+$([regex]::Escape($alias))\s*$") {
            Write-Err "Host '$alias' уже есть в $SshConfigPath"
            return
        }
    }

    $block = @"

Host $alias
    HostName $hostName
    User $user
    Port $port
    IdentityFile $($Key.PrivatePath)
    IdentitiesOnly yes
"@
    Add-Content -Path $SshConfigPath -Value $block -Encoding UTF8
    Write-Ok "Добавлено в ~/.ssh/config: ssh $alias"
}

function Invoke-ConfigKey {
    Write-Title "Добавление ключа в ~/.ssh/config"
    $base = Request-BasePath; if (-not $base) { return }
    $keys = Find-AllSshKeys -BasePath $base
    if (-not $keys -or $keys.Count -eq 0) { Write-Info "Ключей нет."; return }
    $target = Select-Key -Keys $keys -Action "добавления в config"
    if (-not $target) { Write-Info "Отмена."; return }
    if (-not $target.HasPrivate) { Write-Err "Нет приватного ключа — нечего указывать в IdentityFile."; return }
    Invoke-AddToSshConfig -Key ([PSCustomObject]@{
        Name        = $target.Name
        PrivatePath = $target.PrivatePath
        PubPath     = $target.PubPath
    })
}

# ============================================================
#  Деплой публичного ключа на сервер (аналог ssh-copy-id)
# ============================================================
function Invoke-DeployKey {
    Write-Title "Деплой публичного ключа на сервер"
    $base = Request-BasePath; if (-not $base) { return }
    $keys = Find-AllSshKeys -BasePath $base
    if (-not $keys -or $keys.Count -eq 0) { Write-Info "Ключей нет."; return }
    $target = Select-Key -Keys $keys -Action "деплоя"
    if (-not $target) { Write-Info "Отмена."; return }

    $hostName = Read-Host "Хост (user@host или host)"
    if ([string]::IsNullOrWhiteSpace($hostName)) { Write-Err "Пусто."; return }
    if ($hostName -notmatch '@') { $hostName = "root@$hostName" }
    $port = Read-Host "Port [22]"
    if ([string]::IsNullOrWhiteSpace($port)) { $port = "22" }

    Write-Info "Заливаю ключ. Будет запрошен пароль сервера."
    $pubContent = (Get-Content $target.PubPath -Raw).Trim()
    $remoteCmd  = "umask 077; mkdir -p ~/.ssh && echo '$pubContent' >> ~/.ssh/authorized_keys && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys"
    & ssh -p $port -o StrictHostKeyChecking=accept-new $hostName $remoteCmd
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Ключ '$($target.Name)' добавлен на $hostName"
        Write-Info "Проверь: ssh -i `"$($target.PrivatePath)`" -p $port $hostName"
    } else {
        Write-Err "Деплой не удался (код $LASTEXITCODE)"
    }
}

# ============================================================
#  Меню
# ============================================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  +---------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |     SSH Keys Manager (RemnaWave)      |" -ForegroundColor Cyan
    Write-Host "  +---------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   [1] Создать ключ(и)"           -ForegroundColor White
    Write-Host "   [2] Список ключей"             -ForegroundColor White
    Write-Host "   [3] Удалить ключ"              -ForegroundColor White
    Write-Host "   [4] Добавить в ~/.ssh/config"  -ForegroundColor White
    Write-Host "   [5] Залить ключ на сервер"     -ForegroundColor White
    Write-Host "   [0] Выход"                     -ForegroundColor DarkGray
    Write-Host ""
    $choice = Read-Host "   Выбор"
    switch ($choice) {
        '1' { Invoke-NewKeys }
        '2' { Invoke-ListKeys }
        '3' { Invoke-RemoveKey }
        '4' { Invoke-ConfigKey }
        '5' { Invoke-DeployKey }
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
    'config' { Invoke-ConfigKey }
    'deploy' { Invoke-DeployKey }
    'menu'   {
        while (Show-Menu) { }
        Write-Host ""
        Write-Host "Пока!" -ForegroundColor Cyan
    }
}
