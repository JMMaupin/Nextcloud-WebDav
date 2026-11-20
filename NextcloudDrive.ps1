<#
.SYNOPSIS
    Nextcloud Drive: mounts a Nextcloud folder (WebDAV) as a Windows drive,
    using rclone + WinFsp. An ad-free replacement for RaiDrive.

.DESCRIPTION
    No parameter : opens the settings window.
    -Mount        : mounts the drive without a window (Startup folder shortcut).
    -Snapshot <f> : diagnostics, saves a PNG image of the window, then exits.

    Files (all in %LOCALAPPDATA%\NextcloudDrive):
      bin\rclone.exe   rclone downloaded from downloads.rclone.org (SHA-256 checked)
      settings.json    settings; password encrypted with DPAPI (readable by this
                       Windows account on this PC only)
      rclone.log       rclone log
      cache\           rclone write cache (files being uploaded)

    The password never appears on a command line: rclone gets it through an
    environment variable, in "obscured" form (the format rclone expects).
#>
[CmdletBinding()]
param(
    [switch]$Mount,
    [string]$Snapshot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppName         = 'NextcloudDrive'
$AppTitle        = 'Nextcloud Drive'
$AppDir          = Join-Path $env:LOCALAPPDATA $AppName
$BinDir          = Join-Path $AppDir 'bin'
$CacheDir        = Join-Path $AppDir 'cache'
$RcloneExe       = Join-Path $BinDir 'rclone.exe'
$SettingsFile    = Join-Path $AppDir 'settings.json'
$PidFile         = Join-Path $AppDir 'rclone.pid'
$LogFile         = Join-Path $AppDir 'rclone.log'
$InstalledScript = Join-Path $AppDir 'NextcloudDrive.ps1'
$IconFile        = Join-Path $AppDir 'NextcloudDrive.ico'
# per-user drive icons (those under HKLM\...\DriveIcons apply to all users)
$DriveIconsKey   = 'HKCU:\Software\Classes\Applications\Explorer.exe\Drives'
$StartupLink     = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppTitle.lnk"
$StartMenuLink   = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppTitle.lnk"
$PowerShellExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$RemoteName      = 'NEXTCLOUD'   # rclone remote defined by environment variables

# ---------------------------------------------------------------- settings

function Get-DefaultSettings {
    [ordered]@{
        DriveLetter    = 'N'
        Label          = 'Nextcloud'
        ConnectAtLogon = $true
        ReadOnly       = $false
        UseHttps       = $true
        Server         = ''
        Port           = 443
        Path           = '/remote.php/dav/files/'
        User           = ''
        Password       = ''        # DPAPI-encrypted (ConvertFrom-SecureString)
        Anonymous      = $false
    }
}

function Read-Settings {
    $s = Get-DefaultSettings
    if (Test-Path $SettingsFile) {
        $saved = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) {
            if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value }
        }
    }
    $s
}

function Write-Settings($s) {
    New-Item -ItemType Directory -Force $AppDir | Out-Null
    $s | ConvertTo-Json | Set-Content $SettingsFile -Encoding UTF8
}

function Protect-Text([string]$text) {
    if (-not $text) { return '' }
    ConvertTo-SecureString $text -AsPlainText -Force | ConvertFrom-SecureString
}

function Unprotect-Text([string]$cipher) {
    if (-not $cipher) { return '' }
    $secure = ConvertTo-SecureString $cipher
    (New-Object Management.Automation.PSCredential 'x', $secure).GetNetworkCredential().Password
}

function Get-WebDavUrl($s) {
    $scheme = if ($s.UseHttps) { 'https' } else { 'http' }
    $defaultPort = if ($s.UseHttps) { 443 } else { 80 }
    $port = ''
    if ([int]$s.Port -gt 0 -and [int]$s.Port -ne $defaultPort) { $port = ":$([int]$s.Port)" }
    $path = ([string]$s.Path).Trim().Trim('/')
    $path = if ($path) { "/$path/" } else { '/' }
    "${scheme}://$(([string]$s.Server).Trim())$port$path"
}

function Get-SafeLabel([string]$label) {
    $clean = ($label -replace '[\\/:*?"<>|]', '').Trim()
    if ($clean) { $clean } else { 'Nextcloud' }
}

function Get-VolumeName($s) {
    # "\\server\share" as shown by Explorer. WinFsp truncates it to 32 characters:
    # keep only the first word of the server name to leave room for the drive name.
    $hostLabel = (([string]$s.Server).Trim() -split '[.:]')[0]
    if (-not $hostLabel) { $hostLabel = 'nextcloud' }
    if ($hostLabel.Length -gt 20) { $hostLabel = $hostLabel.Substring(0, 20) }
    $prefix = "\\$hostLabel\"
    $label = Get-SafeLabel $s.Label
    $max = 32 - $prefix.Length
    if ($label.Length -gt $max) { $label = $label.Substring(0, $max) }
    $prefix + $label
}

# ---------------------------------------------------------------- components

function Test-WinFsp {
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\WinFsp', 'HKLM:\SOFTWARE\WinFsp') {
        $dir = (Get-ItemProperty $key -Name InstallDir -ErrorAction SilentlyContinue).InstallDir
        if ($dir -and (Test-Path (Join-Path $dir 'bin'))) { return $true }
    }
    Test-Path (Join-Path ${env:ProgramFiles(x86)} 'WinFsp\bin')
}

function Get-RcloneVersion {
    if (-not (Test-Path $RcloneExe)) { return $null }
    try { ((& $RcloneExe version 2>$null) | Select-Object -First 1) -replace '^rclone\s+', '' }
    catch { 'unknown version' }
}

function Install-Rclone {
    if (Get-MountProcess) { throw 'Disconnect the drive before updating rclone.' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $web = New-Object Net.WebClient
    $version = ($web.DownloadString('https://downloads.rclone.org/version.txt').Trim() -split '\s+')[-1]
    if ($version -notmatch '^v\d+\.\d+\.\d+$') { throw "Unexpected rclone version string: $version" }
    $name = "rclone-$version-windows-$arch.zip"
    $tmp = Join-Path $env:TEMP "$AppName-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory $tmp | Out-Null
    try {
        $zip = Join-Path $tmp $name
        $web.DownloadFile("https://downloads.rclone.org/$version/$name", $zip)
        $sums = $web.DownloadString("https://downloads.rclone.org/$version/SHA256SUMS")
        if ($sums -notmatch "(?m)^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($name))\s*$") {
            throw "Checksum for $name not found."
        }
        $expected = $Matches[1]
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "Checksum mismatch for $name." }
        Expand-Archive $zip (Join-Path $tmp 'x')
        $exe = Get-ChildItem (Join-Path $tmp 'x') -Recurse -Filter rclone.exe | Select-Object -First 1
        if (-not $exe) { throw 'rclone.exe not found in the archive.' }
        New-Item -ItemType Directory -Force $BinDir | Out-Null
        Copy-Item $exe.FullName $RcloneExe -Force
    }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-WinFsp {
    $release = Invoke-RestMethod 'https://api.github.com/repos/winfsp/winfsp/releases/latest' -Headers @{ 'User-Agent' = $AppName }
    $asset = $release.assets | Where-Object { $_.name -like 'winfsp-*.msi' } | Select-Object -First 1
    if (-not $asset) { throw 'WinFsp installer not found on GitHub.' }
    $msi = Join-Path $env:TEMP $asset.name
    (New-Object Net.WebClient).DownloadFile($asset.browser_download_url, $msi)
    try {
        $sig = Get-AuthenticodeSignature $msi
        if ($sig.Status -ne 'Valid') { throw "WinFsp installer signature is not valid ($($sig.Status))." }
        # msiexec asks for elevation (UAC): WinFsp installs a driver
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /passive /norestart" -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "WinFsp installer failed (exit code $($p.ExitCode))." }
    }
    finally { Remove-Item $msi -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- mount

function Get-MountProcess {
    if (-not (Test-Path $PidFile)) { return $null }
    $id = 0
    if (-not [int]::TryParse((Get-Content $PidFile -Raw).Trim(), [ref]$id)) { return $null }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and $p.Path -and ($p.Path -ieq $RcloneExe)) { return $p }
    $null
}

function ConvertTo-Argument([string]$arg) {
    if ($arg -notmatch '[\s"]') { return $arg }
    '"' + ($arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Get-ObscuredPassword([string]$plain) {
    # "rclone obscure -" reads the password from standard input
    $psi = New-Object Diagnostics.ProcessStartInfo $RcloneExe, 'obscure -'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd().Trim()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0 -or -not $out) { throw 'rclone obscure failed.' }
    $out
}

function Wait-Ui([int]$ms) {
    if ($script:Form) {
        $end = [DateTime]::Now.AddMilliseconds($ms)
        while ([DateTime]::Now -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    }
    else { Start-Sleep -Milliseconds $ms }
}

function Get-LogTail {
    if (Test-Path $LogFile) { (Get-Content $LogFile -Tail 5 -Encoding UTF8) -join "`n" } else { '' }
}

function Start-Mount($s) {
    if (Get-MountProcess) { return }
    if (-not (Test-Path $RcloneExe)) { throw 'rclone is not installed.' }
    if (-not (Test-WinFsp)) { throw 'WinFsp is not installed.' }
    if (-not ([string]$s.Server).Trim()) { throw 'Server address is empty.' }
    $drive = "$($s.DriveLetter):"
    if (Test-Path "$drive\") { throw "Drive $drive is already in use." }

    $remote = $RemoteName.ToLower() + ':'
    $arguments = @(
        'mount', $remote, $drive,
        '--network-mode',
        '--volname', (Get-VolumeName $s),
        '--vfs-cache-mode', 'writes',
        '--dir-cache-time', '1m',
        '--cache-dir', $CacheDir,
        '--log-file', $LogFile,
        '--log-level', 'NOTICE'
    )
    if ($s.ReadOnly) { $arguments += '--read-only' }

    $psi = New-Object Diagnostics.ProcessStartInfo $RcloneExe
    $psi.Arguments = ($arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $envVars = $psi.EnvironmentVariables
    # rclone remote fully defined by the environment: no rclone.conf
    $envVars['RCLONE_CONFIG'] = Join-Path $AppDir 'rclone.conf'
    $envVars["RCLONE_CONFIG_${RemoteName}_TYPE"] = 'webdav'
    $envVars["RCLONE_CONFIG_${RemoteName}_URL"] = Get-WebDavUrl $s
    $envVars["RCLONE_CONFIG_${RemoteName}_VENDOR"] = 'nextcloud'
    if (-not $s.Anonymous) {
        $envVars["RCLONE_CONFIG_${RemoteName}_USER"] = [string]$s.User
        $envVars["RCLONE_CONFIG_${RemoteName}_PASS"] = Get-ObscuredPassword (Unprotect-Text $s.Password)
    }

    New-Item -ItemType Directory -Force $AppDir | Out-Null
    $p = [Diagnostics.Process]::Start($psi)
    Set-Content $PidFile $p.Id

    # wait for the drive to appear (20 s max)
    for ($i = 0; $i -lt 80; $i++) {
        if (Test-Path "$drive\") { return }
        if ($p.HasExited) { break }
        Wait-Ui 250
    }
    if ($p.HasExited) {
        Remove-Item $PidFile -ErrorAction SilentlyContinue
        throw "rclone stopped.`n`n$(Get-LogTail)"
    }
    throw "Drive $drive did not appear after 20 s. rclone is still running; see the log."
}

function Send-CtrlC([int]$processId) {
    # Ctrl+C sent to rclone's (hidden) console: it unmounts cleanly.
    # Done in a separate PowerShell: attaching to another process's console
    # requires leaving our own.
    $helper = @"
Add-Type -Namespace W -Name C -MemberDefinition '
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);'
[void][W.C]::FreeConsole()
if (-not [W.C]::AttachConsole($processId)) { exit 1 }
[void][W.C]::SetConsoleCtrlHandler([IntPtr]::Zero, `$true)
if (-not [W.C]::GenerateConsoleCtrlEvent(0, 0)) { exit 2 }
Start-Sleep -Milliseconds 500
exit 0
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helper))
    $psi = New-Object Diagnostics.ProcessStartInfo $PowerShellExe, "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $h = [Diagnostics.Process]::Start($psi)
    if (-not $h.WaitForExit(15000)) { $h.Kill(); return $false }
    $h.ExitCode -eq 0
}

function Stop-Mount([string]$letter) {
    $p = Get-MountProcess
    if ($p) {
        # clean stop first; killing rclone does not remove the drive from Explorer.
        # Files not uploaded yet: rclone resumes them at the next mount (cache).
        $stopped = (Send-CtrlC $p.Id) -and $p.WaitForExit(15000)
        if (-not $stopped) {
            $p.Kill()
            [void]$p.WaitForExit(5000)
        }
    }
    Remove-Item $PidFile -ErrorAction SilentlyContinue
    if ($letter) { Send-DriveRemoved $letter }
}

function Test-Tcp([string]$server, [int]$port, [int]$timeoutMs = 3000) {
    $client = New-Object Net.Sockets.TcpClient
    try { $client.ConnectAsync($server, $port).Wait($timeoutMs) -and $client.Connected }
    catch { $false }
    finally { $client.Dispose() }
}

function Test-WebDav($s, [string]$plainPassword) {
    $req = [Net.HttpWebRequest]::Create((Get-WebDavUrl $s))
    $req.Method = 'PROPFIND'
    $req.Headers.Add('Depth', '0')
    $req.Timeout = 15000
    if (-not $s.Anonymous) {
        $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($s.User):$plainPassword"))
        $req.Headers.Add('Authorization', "Basic $token")
    }
    $code = 0
    try {
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
    }
    catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $code = [int]$ex.Response.StatusCode; $ex.Response.Close() }
        else { return @{ Ok = $false; Text = "Cannot reach server: $(if ($ex) { $ex.Message } else { $_.Exception.Message })" } }
    }
    switch ($code) {
        207     { @{ Ok = $true;  Text = 'Connection OK.' } }
        401     { @{ Ok = $false; Text = 'Wrong login or password (HTTP 401).' } }
        404     { @{ Ok = $false; Text = 'Path not found (HTTP 404).' } }
        default { @{ Ok = $false; Text = "Unexpected answer: HTTP $code." } }
    }
}

# ---------------------------------------------------------------- shortcuts

function Get-ShortcutIcon {
    if (Test-Path $IconFile) { "$IconFile,0" } else { "$env:SystemRoot\System32\shell32.dll,9" }
}

function Install-Self {
    New-Item -ItemType Directory -Force $AppDir | Out-Null
    if ($PSCommandPath -and ($PSCommandPath -ine $InstalledScript)) {
        Copy-Item $PSCommandPath $InstalledScript -Force
        # the icon ships next to the script
        $sourceIcon = Join-Path $PSScriptRoot 'NextcloudDrive.ico'
        if (Test-Path $sourceIcon) { Copy-Item $sourceIcon $IconFile -Force }
    }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($StartMenuLink)
    $lnk.TargetPath = $PowerShellExe
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`""
    $lnk.IconLocation = Get-ShortcutIcon
    $lnk.Description = 'Nextcloud WebDAV drive (rclone + WinFsp)'
    $lnk.Save()
}

function Initialize-ShellApi {
    if ('Native.Shell' -as [type]) { return }
    Add-Type -Namespace Native -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern void SHChangeNotify(int eventId, uint flags, string item1, IntPtr item2);
[DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
[StructLayout(LayoutKind.Sequential)] public struct DevBroadcastVolume { public int Size; public int DeviceType; public int Reserved; public int UnitMask; public short Flags; }
[DllImport("user32.dll")] public static extern int BroadcastSystemMessage(int flags, ref int recipients, int msg, IntPtr wParam, ref DevBroadcastVolume lParam);
'@
}

function Send-ShellNotify([int]$eventId, [string]$path) {
    # tells Explorer about a change (drive added, removed, icon changed)
    Initialize-ShellApi
    if ($path) { [Native.Shell]::SHChangeNotify($eventId, 5, $path, [IntPtr]::Zero) }   # SHCNF_PATHW
    else { [Native.Shell]::SHChangeNotify($eventId, 0, [IntPtr]::Zero, [IntPtr]::Zero) }
}

function Send-DriveRemoved([string]$letter) {
    # Announces the drive removal to all windows (WM_DEVICECHANGE,
    # DBT_DEVICEREMOVECOMPLETE), as the DefineDosDevice docs require,
    # then to Explorer (SHCNE_DRIVEREMOVED).
    Initialize-ShellApi
    $volume = New-Object Native.Shell+DevBroadcastVolume
    $volume.Size = [Runtime.InteropServices.Marshal]::SizeOf($volume)
    $volume.DeviceType = 2                                      # DBT_DEVTYP_VOLUME
    $volume.UnitMask = 1 -shl ([int][char]$letter.ToUpper()[0] - [int][char]'A')
    $volume.Flags = 2                                           # DBTF_NET
    $recipients = 8                                             # BSM_APPLICATIONS
    # BSF_IGNORECURRENTTASK | BSF_NOHANG | BSF_FORCEIFHUNG | BSF_NOTIMEOUTIFNOTHUNG
    [void][Native.Shell]::BroadcastSystemMessage(0x2 -bor 0x8 -bor 0x20 -bor 0x40, [ref]$recipients, 0x0219, [IntPtr]0x8004, [ref]$volume)
    Send-ShellNotify 0x00000080 "${letter}:\"                   # SHCNE_DRIVEREMOVED
}

function Set-DriveIcon($s) {
    # Drive icon in Explorer: HKCU\Software\Classes\Applications\
    # Explorer.exe\Drives\<letter>\DefaultIcon (the key RaiDrive used as well).
    # It stays attached to the letter, even while the drive is disconnected.
    $letter = [string]$s.DriveLetter
    if (Test-Path $DriveIconsKey) {
        # remove the one set on another letter (drive letter changed)
        foreach ($k in Get-ChildItem $DriveIconsKey) {
            $iconKey = Get-Item (Join-Path $k.PSPath 'DefaultIcon') -ErrorAction SilentlyContinue
            if ($k.PSChildName -ne $letter -and $iconKey -and ([string]$iconKey.GetValue('')) -ieq $IconFile) {
                Remove-Item $k.PSPath -Recurse -Force
            }
        }
    }
    if (Test-Path $IconFile) {
        # New-Item -Force only recreates the DefaultIcon leaf, not its existing parents
        $key = Join-Path $DriveIconsKey "$letter\DefaultIcon"
        New-Item $key -Force | Out-Null
        Set-Item $key -Value $IconFile
    }
    Send-ShellNotify 0x00002000 "${letter}:\"   # SHCNE_UPDATEITEM
    Send-ShellNotify 0x08000000 $null           # SHCNE_ASSOCCHANGED
}

function Set-AutoStart([bool]$enabled) {
    if (-not $enabled) { Remove-Item $StartupLink -ErrorAction SilentlyContinue; return }
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($StartupLink)
    $lnk.TargetPath = $PowerShellExe
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`" -Mount"
    $lnk.WindowStyle = 7
    $lnk.IconLocation = Get-ShortcutIcon
    $lnk.Save()
}

# ---------------------------------------------------------------- windowless mode

if ($Mount) {
    $s = Read-Settings
    try {
        # at logon the network may be slow to come up: 2 min max
        $deadline = (Get-Date).AddMinutes(2)
        while ((Get-Date) -lt $deadline -and -not (Test-Tcp $s.Server ([int]$s.Port))) { Start-Sleep -Seconds 5 }
        Start-Mount $s
    }
    catch {
        New-Item -ItemType Directory -Force $AppDir | Out-Null
        Add-Content $LogFile "$(Get-Date -Format s) NextcloudDrive: mount at logon failed: $($_.Exception.Message)" -Encoding UTF8
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------- user interface

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace Native -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][Native.Dpi]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

function Get-FreeDriveLetters([string]$keep) {
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
    $used += @(Get-ChildItem HKCU:\Network -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName.ToUpper() })
    'DEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray() | ForEach-Object { [string]$_ } |
        Where-Object { $_ -eq $keep -or $used -notcontains $_ }
}

function New-Control([string]$type, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text = '') {
    $c = New-Object "Windows.Forms.$type"
    $c.SetBounds($x, $y, $w, $h)
    if ($text) { $c.Text = $text }
    $c
}

$script:Form = $null
$settings = Read-Settings

$form = New-Object Windows.Forms.Form
$form.Text = $AppTitle
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object Drawing.Size(480, 468)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$formIcon = @((Join-Path $PSScriptRoot 'NextcloudDrive.ico'), $IconFile) | Where-Object { Test-Path $_ } | Select-Object -First 1
$form.Icon = if ($formIcon) { New-Object Drawing.Icon $formIcon } else { [Drawing.Icon]::ExtractAssociatedIcon($PowerShellExe) }
$tips = New-Object Windows.Forms.ToolTip

# --- Drive
$grpDrive = New-Control GroupBox 10 8 460 82 'Drive'
$cboLetter = New-Control ComboBox 62 22 60 24
$cboLetter.DropDownStyle = 'DropDownList'
$txtLabel = New-Control TextBox 190 22 255 24
$chkLogon = New-Control CheckBox 14 52 220 22 'Connect at Windows logon'
$chkReadOnly = New-Control CheckBox 250 52 120 22 'Read-only'
$grpDrive.Controls.AddRange(@(
    (New-Control Label 12 25 48 20 'Letter'), $cboLetter,
    (New-Control Label 140 25 48 20 'Name'), $txtLabel,
    $chkLogon, $chkReadOnly))

# --- Address
$grpAddress = New-Control GroupBox 10 96 460 84 'Address'
$chkHttps = New-Control CheckBox 14 23 64 22 'HTTPS'
$txtServer = New-Control TextBox 80 22 290 24
$txtPort = New-Control TextBox 385 22 60 24
$txtPath = New-Control TextBox 80 52 365 24
$grpAddress.Controls.AddRange(@(
    $chkHttps, $txtServer, (New-Control Label 373 25 10 20 ':'), $txtPort,
    (New-Control Label 12 55 64 20 'Path'), $txtPath))
$tips.SetToolTip($txtServer, 'Server name, e.g. nextcloud.example.org')

# --- Account
$grpAccount = New-Control GroupBox 10 186 460 84 'Account'
$txtUser = New-Control TextBox 80 22 200 24
$txtPassword = New-Control TextBox 80 52 200 24
$txtPassword.UseSystemPasswordChar = $true
$chkAnonymous = New-Control CheckBox 300 23 120 22 'Anonymous'
$lnkAppPwd = New-Control LinkLabel 300 55 150 20 'Create an app password'
$grpAccount.Controls.AddRange(@(
    (New-Control Label 12 25 64 20 'User'), $txtUser,
    (New-Control Label 12 55 64 20 'Password'), $txtPassword,
    $chkAnonymous, $lnkAppPwd))
$tips.SetToolTip($txtPassword, 'Use a Nextcloud app password (Settings > Security), not your main password.')

# --- URL
$lblUrl = New-Control Label 12 276 456 20
$lblUrl.ForeColor = [Drawing.Color]::Gray
$lblUrl.AutoEllipsis = $true

# --- Components
$grpComp = New-Control GroupBox 10 300 460 74 'Components'
$lblRclone = New-Control Label 12 22 300 20
$lblWinFsp = New-Control Label 12 46 300 20
$btnInstall = New-Control Button 325 26 120 32 'Install / Update'
$grpComp.Controls.AddRange(@($lblRclone, $lblWinFsp, $btnInstall))

# --- Actions
$btnTest = New-Control Button 10 384 90 32 'Test'
$btnSave = New-Control Button 106 384 90 32 'Save'
$btnOpen = New-Control Button 202 384 90 32 'Open drive'
$btnConnect = New-Control Button 350 384 120 32 'Connect'
$lblStatus = New-Control Label 12 426 456 36
$lblStatus.AutoEllipsis = $true

$form.Controls.AddRange(@($grpDrive, $grpAddress, $grpAccount, $lblUrl, $grpComp,
    $btnTest, $btnSave, $btnOpen, $btnConnect, $lblStatus))
$form.AcceptButton = $btnConnect

# --- fill in
foreach ($l in Get-FreeDriveLetters $settings.DriveLetter) { [void]$cboLetter.Items.Add($l) }
$cboLetter.SelectedItem = [string]$settings.DriveLetter
if ($cboLetter.SelectedIndex -lt 0 -and $cboLetter.Items.Count) { $cboLetter.SelectedIndex = 0 }
$txtLabel.Text = $settings.Label
$chkLogon.Checked = [bool]$settings.ConnectAtLogon
$chkReadOnly.Checked = [bool]$settings.ReadOnly
$chkHttps.Checked = [bool]$settings.UseHttps
$txtServer.Text = $settings.Server
$txtPort.Text = [string]$settings.Port
$txtPath.Text = $settings.Path
$txtUser.Text = $settings.User
try { $txtPassword.Text = Unprotect-Text $settings.Password } catch { $txtPassword.Text = '' }
$chkAnonymous.Checked = [bool]$settings.Anonymous

# --- UI functions

function Get-FormSettings {
    $port = 0
    if (-not [int]::TryParse($txtPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        $port = if ($chkHttps.Checked) { 443 } else { 80 }
    }
    $s = Get-DefaultSettings
    $s.DriveLetter = [string]$cboLetter.SelectedItem
    $s.Label = Get-SafeLabel $txtLabel.Text
    $s.ConnectAtLogon = $chkLogon.Checked
    $s.ReadOnly = $chkReadOnly.Checked
    $s.UseHttps = $chkHttps.Checked
    $s.Server = ($txtServer.Text.Trim() -replace '^https?://', '').TrimEnd('/')
    $s.Port = $port
    $s.Path = $txtPath.Text.Trim()
    $s.User = $txtUser.Text.Trim()
    $s.Password = Protect-Text $txtPassword.Text
    $s.Anonymous = $chkAnonymous.Checked
    $s
}

function Set-Status([string]$text, [string]$kind = 'info') {
    $lblStatus.Text = $text
    $lblStatus.ForeColor = switch ($kind) {
        'ok'    { [Drawing.Color]::ForestGreen }
        'error' { [Drawing.Color]::Firebrick }
        default { [Drawing.SystemColors]::ControlText }
    }
    [Windows.Forms.Application]::DoEvents()
}

function Update-Url {
    $s = Get-FormSettings
    $lblUrl.Text = if ($s.Server) { Get-WebDavUrl $s } else { '' }
}

function Update-State {
    $version = Get-RcloneVersion
    $lblRclone.Text = if ($version) { "rclone: $version" } else { 'rclone: not installed' }
    $lblRclone.ForeColor = if ($version) { [Drawing.Color]::ForestGreen } else { [Drawing.Color]::Firebrick }
    $fsp = Test-WinFsp
    $lblWinFsp.Text = if ($fsp) { 'WinFsp: installed' } else { 'WinFsp: not installed' }
    $lblWinFsp.ForeColor = if ($fsp) { [Drawing.Color]::ForestGreen } else { [Drawing.Color]::Firebrick }
    $mounted = [bool](Get-MountProcess)
    $btnConnect.Text = if ($mounted) { 'Disconnect' } else { 'Connect' }
    $btnConnect.Enabled = $mounted -or ($version -and $fsp)
    $btnOpen.Enabled = $mounted
    foreach ($c in $grpDrive, $grpAddress, $grpAccount) { $c.Enabled = -not $mounted }
    $txtUser.Enabled = -not $chkAnonymous.Checked
    $txtPassword.Enabled = -not $chkAnonymous.Checked
}

function Invoke-Safely([scriptblock]$action) {
    $form.Cursor = 'WaitCursor'
    try { & $action }
    catch { Set-Status $_.Exception.Message 'error' }
    finally { $form.Cursor = 'Default'; Update-State }
}

function Save-All {
    $s = Get-FormSettings
    Write-Settings $s
    Install-Self
    Set-AutoStart $s.ConnectAtLogon
    Set-DriveIcon $s
    $s
}

# --- events

$txtServer.Add_TextChanged({ Update-Url })
$txtPort.Add_TextChanged({ Update-Url })
$txtPath.Add_TextChanged({ Update-Url })
$chkHttps.Add_CheckedChanged({
    if ($chkHttps.Checked -and $txtPort.Text -eq '80') { $txtPort.Text = '443' }
    if (-not $chkHttps.Checked -and $txtPort.Text -eq '443') { $txtPort.Text = '80' }
    Update-Url
})
$txtUser.Add_TextChanged({
    # keep the standard Nextcloud path in line with the login
    if ($txtPath.Text -match '^/remote\.php/dav/files/[^/]*/?$') {
        $txtPath.Text = '/remote.php/dav/files/' + $txtUser.Text.Trim() + '/'
    }
})
$chkAnonymous.Add_CheckedChanged({ Update-State })
$lnkAppPwd.Add_LinkClicked({
    $s = Get-FormSettings
    if ($s.Server) {
        $scheme = if ($s.UseHttps) { 'https' } else { 'http' }
        Start-Process "${scheme}://$($s.Server)/index.php/settings/user/security"
    }
})

$btnInstall.Add_Click({ Invoke-Safely {
    Set-Status 'Downloading rclone...'
    Install-Rclone
    if (-not (Test-WinFsp)) {
        Set-Status 'Installing WinFsp (administrator approval required)...'
        Install-WinFsp
    }
    Set-Status 'Components installed.' 'ok'
} })

$btnTest.Add_Click({ Invoke-Safely {
    $s = Get-FormSettings
    if (-not $s.Server) { throw 'Server address is empty.' }
    Set-Status 'Testing connection...'
    $r = Test-WebDav $s $txtPassword.Text
    Set-Status $r.Text $(if ($r.Ok) { 'ok' } else { 'error' })
} })

$btnSave.Add_Click({ Invoke-Safely {
    [void](Save-All)
    Set-Status 'Settings saved.' 'ok'
} })

$btnOpen.Add_Click({ Start-Process explorer.exe "$($cboLetter.SelectedItem):\" })

$btnConnect.Add_Click({ Invoke-Safely {
    if (Get-MountProcess) {
        Set-Status 'Disconnecting...'
        Stop-Mount ([string]$cboLetter.SelectedItem)
        Set-Status 'Disconnected.' 'ok'
        return
    }
    $s = Save-All
    Set-Status "Connecting $($s.DriveLetter): ..."
    Start-Mount $s
    Set-Status "Connected: $($s.DriveLetter): -> $(Get-WebDavUrl $s)" 'ok'
} })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ if ($form.Cursor -ne 'WaitCursor') { Update-State } })

$form.Add_Shown({
    Update-Url
    Update-State
    if (Get-MountProcess) { Set-Status "Connected: $($cboLetter.SelectedItem):" 'ok' }
    elseif (-not (Test-Path $RcloneExe) -or -not (Test-WinFsp)) { Set-Status 'Click "Install / Update" to install rclone and WinFsp.' }
    $timer.Start()
    if ($Snapshot) {
        $form.Refresh()
        $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.Close()
    }
})

$script:Form = $form
[void]$form.ShowDialog()
$timer.Stop()
