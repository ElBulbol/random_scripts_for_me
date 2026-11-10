<#
.SYNOPSIS
    One-shot setup for Windows: removes any current Spotify (desktop + Microsoft Store),
    installs a chosen older Spotify version, blocks Spotify auto-updates, installs
    Spicetify + Spicetify Marketplace and applies them.
    Also works on a PC that has NO Spotify installed yet.

.DESCRIPTION
    Run it in a NORMAL (non-administrator) PowerShell window on Windows 10 / 11.

    Designed to be started with:
        iwr -useb https://raw.githubusercontent.com/ElBulbol/spiectify_windows_fix/main/Spotify-Spicetify-Setup.ps1 | iex

    A script started through "| iex" cannot take parameters, so options are given through
    the SPSETUP_ARGS environment variable (set it in the same window, right before):

        $env:SPSETUP_ARGS = '-DryRun'
        iwr -useb https://raw.githubusercontent.com/ElBulbol/spiectify_windows_fix/main/Spotify-Spicetify-Setup.ps1 | iex

        $env:SPSETUP_ARGS = '-SpotifyVersion 1.2.98.301 -Yes -SkipMarketplace'

    Or run it from a file / script block with normal switches:
        powershell -ExecutionPolicy Bypass -File .\Spotify-Spicetify-Setup.ps1 -DryRun
        & ([scriptblock]::Create((iwr -useb <url>))) -DryRun

    OPTIONS
        -SpotifyVersion <x.y.z.w>   Spotify version to install. Default 1.2.98.301
        -SpicetifyVersion <ver>     'latest' (default) or e.g. 2.45.3
        -InstallerPath <file>       Use a SpotifySetup.exe you downloaded by hand
        -InstallerUrl <url>         Use this direct download link instead of the version list
        -SkipMarketplace            Do not install Spicetify Marketplace
        -SkipSignatureCheck         Do NOT use unless you know why
        -DryRun                     Show what would happen, change nothing
        -Yes                        Do not ask questions
        -NoPause                    Do not wait for Enter at the end
        -Help                       Show this help

    Order of work (safe by design):
      1. Pre-flight checks (Windows, not admin, disk space, language mode).
      2. Download + verify EVERYTHING first (installer signature, installer really contains
         the requested version, Spicetify zip, Marketplace zip). If anything fails here,
         nothing on the PC has been changed.
      3. Remove the current Spotify (desktop + Store) and VERIFY it is gone.
      4. Install the verified Spotify and VERIFY its version.
      5. Lock the Spotify "Update" folder and VERIFY the lock works.
      6. Install Spicetify, start Spotify once, close it, install Marketplace,
         run "spicetify backup apply".

    Undo the update block any time (Command Prompt):
        icacls "%localappdata%\Spotify\Update" /remove:d "%username%"
    Log file: %TEMP%\Spotify-Spicetify-Setup.log

    NOTE: keep this file saved as plain ASCII / UTF-8 WITHOUT BOM, otherwise "| iex" can fail.
#>

# The whole script runs inside  & { ... }  on purpose: with "iwr | iex" the code runs directly in the
# user's window, and this keeps its variables/functions from leaking into that window.
# There is deliberately NO top-level param() block: it is a parse error under iex.
& {
    param($RawArgs)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # ----------------------------------------------------------------------------------
    # Options (defaults, then overridden by $args and by $env:SPSETUP_ARGS)
    # ----------------------------------------------------------------------------------
    $SpotifyVersion     = '1.2.98.301'
    $SpicetifyVersion   = 'latest'
    $InstallerPath      = ''
    $InstallerUrl       = ''
    $SkipSignatureCheck = $false
    $SkipMarketplace    = $false
    $DryRun             = $false
    $Yes                = $false
    $NoPause            = $false
    $ShowHelp           = $false

    try {
        $tokens = New-Object System.Collections.Generic.List[string]
        if ($null -ne $RawArgs) {
            foreach ($a in @($RawArgs)) {
                if ($null -ne $a -and ([string]$a) -ne '') { [void]$tokens.Add([string]$a) }
            }
        }
        if ($env:SPSETUP_ARGS) {
            foreach ($t in ($env:SPSETUP_ARGS -split '\s+')) {
                if ($t) { [void]$tokens.Add($t) }
            }
        }
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $tok  = $tokens[$i]
            $name = $tok.TrimStart('-', '/').ToLowerInvariant()
            $val  = $null
            if ($name -match '^([^:=]+)[:=](.*)$') { $name = $Matches[1]; $val = $Matches[2] }
            switch ($name) {
                'dryrun'             { $DryRun = $true }
                'yes'                { $Yes = $true }
                'y'                  { $Yes = $true }
                'nopause'            { $NoPause = $true }
                'skipmarketplace'    { $SkipMarketplace = $true }
                'skipsignaturecheck' { $SkipSignatureCheck = $true }
                'help'               { $ShowHelp = $true }
                '?'                  { $ShowHelp = $true }
                { $_ -in @('spotifyversion', 'spicetifyversion', 'installerpath', 'installerurl') } {
                    if ($null -eq $val) {
                        $i++
                        if ($i -ge $tokens.Count) { throw "Option -$name needs a value." }
                        $val = $tokens[$i]
                    }
                    if ($name -eq 'spotifyversion')   { $SpotifyVersion = $val }
                    if ($name -eq 'spicetifyversion') { $SpicetifyVersion = $val }
                    if ($name -eq 'installerpath')    { $InstallerPath = $val }
                    if ($name -eq 'installerurl')     { $InstallerUrl = $val }
                }
                default { throw "Unknown option: $tok  (use -Help)" }
            }
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if ($ShowHelp) {
        Write-Host ''
        Write-Host 'Spotify + Spicetify setup - options:'
        Write-Host '  -SpotifyVersion <x.y.z.w>  (default 1.2.98.301)'
        Write-Host '  -SpicetifyVersion <ver>    (default latest)'
        Write-Host '  -InstallerPath <file>      use your own SpotifySetup.exe'
        Write-Host '  -InstallerUrl <url>        use a direct download link'
        Write-Host '  -SkipMarketplace  -SkipSignatureCheck  -DryRun  -Yes  -NoPause'
        Write-Host ''
        Write-Host 'With "iwr | iex", set options first:  $env:SPSETUP_ARGS = ''-DryRun'''
        return
    }

    # ----------------------------------------------------------------------------------
    # Constants
    # ----------------------------------------------------------------------------------
    $ManifestUrl    = 'https://raw.githubusercontent.com/LoaderSpot/table/refs/heads/main/table/versions.json'
    $MarketplaceUrl = 'https://github.com/spicetify/marketplace/releases/latest/download/marketplace.zip'
    $StoreName      = 'SpotifyAB.SpotifyMusic'
    $StoreWingetId  = '9NCBCSZSJRSB'
    $SpRoaming      = Join-Path $env:APPDATA 'Spotify'
    $SpLocal        = Join-Path $env:LOCALAPPDATA 'Spotify'
    $SpUpdate       = Join-Path $SpLocal 'Update'
    $SpExe          = Join-Path $SpRoaming 'Spotify.exe'
    $SpPrefs        = Join-Path $SpRoaming 'prefs'
    $SpicetifyDir   = Join-Path $env:LOCALAPPDATA 'spicetify'
    $SpicetifyExe   = Join-Path $SpicetifyDir 'spicetify.exe'
    $SpicetifyCfg   = Join-Path $env:APPDATA 'spicetify'
    $StageDir       = Join-Path $env:TEMP 'spotify-setup-stage'
    $MarketTmp      = Join-Path $env:TEMP 'spotify-setup-marketplace'
    $LogFile        = Join-Path $env:TEMP 'Spotify-Spicetify-Setup.log'
    $Warnings       = New-Object System.Collections.Generic.List[string]

    # ----------------------------------------------------------------------------------
    # Small helpers
    # ----------------------------------------------------------------------------------
    function Say   { param([string]$Message) Write-Host $Message }
    function Step  { param([string]$Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
    function Good  { param([string]$Message) Write-Host "    [ok] $Message" -ForegroundColor Green }
    function Warn  { param([string]$Message) Write-Host "    [!]  $Message" -ForegroundColor Yellow; [void]$Warnings.Add($Message) }
    function Dry   { param([string]$Message) Write-Host "    [dry-run] $Message" -ForegroundColor Magenta }
    function Fail  { param([string]$Message) throw $Message }

    function Test-IsAdmin {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Get-OsArch {
        $a = $env:PROCESSOR_ARCHITEW6432
        if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
        if (-not $a) { Fail 'Could not detect the CPU architecture.' }
        switch ($a.ToUpper()) {
            'AMD64' { return 'x64' }
            'ARM64' { return 'arm64' }
            'X86'   { return 'x86' }
            default { Fail "Unsupported CPU architecture: $a" }
        }
    }

    function Get-Prop {
        # Reads a property from a PSCustomObject OR a dictionary (JavaScriptSerializer result).
        param($Obj, [string]$Name)
        if ($null -eq $Obj) { return $null }
        if ($Obj -is [System.Collections.IDictionary]) {
            if ($Obj.Contains($Name)) { return $Obj[$Name] }
            return $null
        }
        $p = $Obj.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    }

    function Invoke-Native {
        # Runs a program, shows its output (unless -Quiet), returns its exit code.
        param([string]$Exe, [string[]]$ArgList, [switch]$Quiet)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if ($Quiet) { & $Exe @ArgList 2>&1 | Out-Null }
            else        { & $Exe @ArgList | Out-Host }
            return $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $old
        }
    }

    function Get-WinPowerShell {
        $p = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $p) { return $p }
        return 'powershell.exe'
    }

    function Test-FreeSpace {
        param([string]$Path, [long]$NeedBytes)
        $free = $null
        try {
            $root = [IO.Path]::GetPathRoot($Path)
            if ($root -and -not $root.StartsWith('\\')) {
                $free = (New-Object IO.DriveInfo($root)).AvailableFreeSpace
            }
        }
        catch { $free = $null }
        if ($null -ne $free -and $free -lt $NeedBytes) {
            Fail ('Not enough free disk space on {0}: {1} MB free, about {2} MB needed.' -f $root, [int]($free / 1MB), [int]($NeedBytes / 1MB))
        }
    }

    function Stop-Spotify {
        param([switch]$Graceful)
        $names = @('Spotify', 'SpotifyWebHelper', 'SpotifyCrashService', 'SpotifyMigrator')
        if ($Graceful) {
            Get-Process -Name 'Spotify' -ErrorAction SilentlyContinue | ForEach-Object {
                try { [void]$_.CloseMainWindow() } catch { }
            }
            Start-Sleep -Seconds 3
        }
        for ($i = 0; $i -lt 8; $i++) {
            $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
            if ($procs.Count -eq 0) { return }
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }

    function Remove-FolderRobust {
        param([string]$Path, [switch]$KillSpotify)
        for ($i = 1; $i -le 5; $i++) {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
            catch {
                if ($KillSpotify) { Stop-Spotify }
                if ($i -ge 2) { [void](Invoke-Native -Exe 'icacls.exe' -ArgList @($Path, '/reset', '/t', '/c', '/q') -Quiet) }
                if ($i -ge 3) { [void](Invoke-Native -Exe 'cmd.exe' -ArgList @('/c', 'rd', '/s', '/q', $Path) -Quiet) }
                Start-Sleep -Seconds 2
            }
        }
        if (Test-Path -LiteralPath $Path) {
            Fail "Could not delete '$Path' (a file in it is probably still in use, or an antivirus holds it). Restart the PC and run the script again."
        }
    }

    function Get-ExeVersion {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $vi = (Get-Item -LiteralPath $Path).VersionInfo
        $v = [string]$vi.FileVersion
        if (-not $v) { $v = [string]$vi.ProductVersion }
        if (-not $v) { $v = 'unknown version' }
        return $v
    }

    function Test-ExeIsVersion {
        # True when the exe's FileVersion or ProductVersion equals the wanted version
        # (an optional suffix such as ".g1234abc" is allowed, but 1.2.98.3011 does NOT match 1.2.98.301).
        param([string]$Path, [string]$Want)
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $vi = (Get-Item -LiteralPath $Path).VersionInfo
        foreach ($found in @([string]$vi.FileVersion, [string]$vi.ProductVersion)) {
            if (-not $found) { continue }
            $found = $found.Trim()
            if ($found -eq $Want) { return $true }
            foreach ($sep in @('.', ' ', '-', '+')) {
                if ($found.StartsWith($Want + $sep)) { return $true }
            }
        }
        return $false
    }

    function Get-UserSid {
        return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }

    function Add-ToUserPath {
        # Edits the user PATH in the registry directly, so REG_EXPAND_SZ and %VARS% entries stay intact.
        param([string]$Dir)
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try {
            $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $want = $Dir.TrimEnd('\')
            $parts = @($cur -split ';' | Where-Object { $_ -ne '' })
            $has = $false
            foreach ($p in $parts) {
                if ([Environment]::ExpandEnvironmentVariables($p).TrimEnd('\') -ieq $want) { $has = $true }
            }
            if (-not $has) {
                $new = (@($parts) + $Dir) -join ';'
                $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            }
        }
        finally { $key.Close() }
        if (($env:PATH -split ';') -notcontains $Dir) { $env:PATH = "$env:PATH;$Dir" }
        # Setting any user variable makes Windows broadcast "environment changed" to new windows.
        try { [Environment]::SetEnvironmentVariable('SPSETUP_PATH_REFRESH', $null, 'User') } catch { }
    }

    # ----------------------------------------------------------------------------------
    # Zip helpers (.NET, no dependence on Expand-Archive quirks)
    # ----------------------------------------------------------------------------------
    function Test-ZipEntry {
        param([string]$Zip, [string]$Pattern)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = $null
        try {
            $z = [IO.Compression.ZipFile]::OpenRead($Zip)
            foreach ($e in $z.Entries) { if ($e.FullName -match $Pattern) { return $true } }
            return $false
        }
        catch { return $false }
        finally { if ($z) { $z.Dispose() } }
    }

    function Expand-ZipSafe {
        param([string]$Zip, [string]$Dest)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
        $root = [IO.Path]::GetFullPath($Dest).TrimEnd('\') + '\'
        $z = [IO.Compression.ZipFile]::OpenRead($Zip)
        try {
            foreach ($e in $z.Entries) {
                $target = [IO.Path]::GetFullPath((Join-Path $Dest ($e.FullName -replace '/', '\')))
                if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }   # zip-slip guard
                if ($e.FullName.EndsWith('/') -or -not $e.Name) {
                    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                    continue
                }
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            }
        }
        finally { $z.Dispose() }
    }

    # ----------------------------------------------------------------------------------
    # Downloading
    # ----------------------------------------------------------------------------------
    function Get-WebText {
        param([string]$Url)
        $last = ''
        for ($i = 1; $i -le 3; $i++) {
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Uri $Url
                if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content) }
                return [string]$r.Content
            }
            catch {
                $last = $_.Exception.Message
                Start-Sleep -Seconds (2 * $i)
            }
        }
        Fail "Could not download $Url ($last)"
    }

    function ConvertFrom-JsonBig {
        # Windows PowerShell 5.1 can choke on large JSON; fall back to a serializer with no size limit.
        param([string]$Text)
        try { return ($Text | ConvertFrom-Json) }
        catch {
            try {
                Add-Type -AssemblyName System.Web.Extensions
                $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                $ser.MaxJsonLength = [int]::MaxValue
                return $ser.DeserializeObject($Text)
            }
            catch { Fail "Could not read the Spotify version list: $($_.Exception.Message)" }
        }
    }

    function Save-Url {
        # Tries Invoke-WebRequest, then curl.exe, then BITS. Downloads to .partial first so a half file is never used.
        param([string]$Url, [string]$OutFile, [long]$MinBytes = 1000000)
        $part = "$OutFile.partial"
        foreach ($method in @('iwr', 'curl', 'bits')) {
            try {
                if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
                switch ($method) {
                    'iwr' { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $part }
                    'curl' {
                        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                        if (-not $curl) { throw 'curl.exe is not available' }
                        & $curl.Source -L --fail --silent --show-error --retry 2 -o $part $Url
                        if ($LASTEXITCODE -ne 0) { throw "curl.exe exit code $LASTEXITCODE" }
                    }
                    'bits' { Start-BitsTransfer -Source $Url -Destination $part }
                }
                if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part).Length -ge $MinBytes)) {
                    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
                    Move-Item -LiteralPath $part -Destination $OutFile -Force
                    return
                }
                throw 'the downloaded file is missing or too small'
            }
            catch {
                Warn "Download method '$method' failed: $($_.Exception.Message)"
            }
        }
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        Fail "Download failed with every method: $Url`n    Try a VPN or another DNS (1.1.1.1), or download the file by hand (for Spotify use -InstallerPath)."
    }

    function Test-SpotifySignature {
        param([string]$Path)
        $sig = Get-AuthenticodeSignature -FilePath $Path
        $subject = ''
        if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
        $ok = ($sig.Status -eq 'Valid') -and ($subject -match '(^|,\s*)(CN|O)="?Spotify AB"?\s*(,|$)')
        return [pscustomobject]@{ Ok = $ok; Status = [string]$sig.Status; Subject = $subject }
    }

    function Assert-SpotifySignature {
        param([string]$Path)
        $r = Test-SpotifySignature -Path $Path
        if ($r.Ok) { Good 'Installer is digitally signed by Spotify AB.'; return }
        $msg = "Installer signature check FAILED. Status: $($r.Status). Signer: '$($r.Subject)'."
        if ($SkipSignatureCheck) { Warn "$msg Continuing only because -SkipSignatureCheck was used."; return }
        Fail "$msg`n    For your safety the script stopped before running it."
    }

    # ----------------------------------------------------------------------------------
    # Finding what to download
    # ----------------------------------------------------------------------------------
    function Resolve-SpotifyLink {
        param([string]$Version, [string]$Arch)
        $manifest = ConvertFrom-JsonBig -Text (Get-WebText -Url $ManifestUrl)
        $entry = Get-Prop $manifest $Version
        if (-not $entry) {
            Fail "Spotify $Version is not in the version list. See https://loadspot.pages.dev/versions for valid versions."
        }
        $win = Get-Prop $entry 'win'
        if (-not $win) { Fail "Spotify $Version has no Windows build in the version list." }

        # Preferred architecture first, then sensible fallbacks (x64 runs on ARM64 Windows 11, x86 runs on x64).
        $order = @($Arch)
        if ($Arch -eq 'arm64') { $order += @('x64', 'x86') }
        elseif ($Arch -eq 'x64') { $order += @('x86') }

        foreach ($a in $order) {
            $data = Get-Prop $win $a
            if (-not $data) { continue }
            $link = ''
            $size = [long]0
            if ($data -is [string]) { $link = $data }
            else {
                $link = [string](Get-Prop $data 'url')
                $rawSize = Get-Prop $data 'size'
                if ($rawSize) { try { $size = [long]$rawSize } catch { $size = [long]0 } }
            }
            if ($link) {
                if ($a -ne $Arch) { Warn "Spotify $Version has no $Arch build; using the $a build instead." }
                return [pscustomobject]@{ Url = $link; Size = $size; Arch = $a }
            }
        }
        $avail = @('x86', 'x64', 'arm64') | Where-Object { Get-Prop $win $_ }
        Fail "Spotify $Version has no usable build for $Arch. Available for this version: $($avail -join ', ')"
    }

    function Get-LatestSpicetifyVersion {
        # 1) follow the "latest" redirect (not subject to the GitHub API rate limit)
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/spicetify/cli/releases/latest'
            $final = ''
            if ($r.BaseResponse.ResponseUri) { $final = [string]$r.BaseResponse.ResponseUri.AbsoluteUri }
            elseif ($r.BaseResponse.RequestMessage) { $final = [string]$r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
            if ($final -match '/releases/tag/v?(\d+\.\d+\.\d+)') { return $Matches[1] }
        }
        catch { }
        # 2) GitHub API as a fallback
        try {
            $rel = (Get-WebText -Url 'https://api.github.com/repos/spicetify/cli/releases/latest') | ConvertFrom-Json
            $tag = ([string]$rel.tag_name).TrimStart('v')
            if ($tag -match '^\d+\.\d+\.\d+$') { return $tag }
        }
        catch { }
        Fail 'Could not find the latest Spicetify version. Run again with  -SpicetifyVersion 2.45.3'
    }

    function Get-SpotifyInstaller {
        param([string]$Version, [string]$Arch)
        Step "Getting the Spotify $Version installer ($Arch)"
        if ($InstallerPath) {
            if (-not (Test-Path -LiteralPath $InstallerPath)) { Fail "Installer file not found: $InstallerPath" }
            $file = (Resolve-Path -LiteralPath $InstallerPath).Path
            Say "    Using your file: $file"
            Assert-SpotifySignature -Path $file
            return $file
        }

        $link = ''
        $size = [long]0
        $gotArch = $Arch
        if ($InstallerUrl) {
            $link = $InstallerUrl
            Say '    Using the direct link you gave.'
        }
        else {
            $found = Resolve-SpotifyLink -Version $Version -Arch $Arch
            $link = $found.Url
            $size = $found.Size
            $gotArch = $found.Arch
        }
        $uri = [Uri]$link
        Say "    Download address: $link"
        if ($uri.Host -eq 'loadspot.amd64fox1.workers.dev') {
            Say '    Note: this list (LoaderSpot) serves the file through its own proxy, not straight from Spotify.'
            Say '          That is why the installer signature is verified below before anything is run.'
        }
        elseif ($uri.Host -notmatch '(^|\.)(scdn\.co|spotify\.com)$') {
            Warn "Unknown download host: $($uri.Host). The signature check below is what protects you."
        }
        if ($uri.Scheme -ne 'https') { Warn 'The address is not https. The signature check below is what protects you.' }
        if ($DryRun) { Dry 'would download the installer and check its signature'; return $null }

        $file = Join-Path $env:TEMP "SpotifySetup-$Version-$gotArch.exe"
        $min = [long]20000000
        if ($size -gt 0) { $min = [long]($size * 0.9) }

        # Re-use a complete, correctly signed download from an earlier run.
        if ((Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file).Length -ge $min)) {
            if ((Test-SpotifySignature -Path $file).Ok) {
                Say "    Re-using the installer already downloaded: $file"
                Assert-SpotifySignature -Path $file
                return $file
            }
        }
        Say '    Downloading (about 100-150 MB, please wait) ...'
        Save-Url -Url $link -OutFile $file -MinBytes $min
        Assert-SpotifySignature -Path $file
        return $file
    }

    function Get-SpicetifyPackage {
        param([string]$Arch)
        Step "Getting Spicetify ($SpicetifyVersion)"
        $suffix = ''
        switch ($Arch) {
            'x64'   { $suffix = 'windows-x64' }
            'arm64' { $suffix = 'windows-arm64' }
            'x86'   { $suffix = 'windows-x32' }
        }
        $ver = $SpicetifyVersion.TrimStart('v')
        if ($SpicetifyVersion -eq 'latest') { $ver = Get-LatestSpicetifyVersion }
        if ($ver -notmatch '^\d+\.\d+\.\d+$') { Fail "Invalid Spicetify version: $SpicetifyVersion" }
        $url = "https://github.com/spicetify/cli/releases/download/v$ver/spicetify-$ver-$suffix.zip"
        Say "    Version: $ver"
        Say "    Download address: $url"
        if ($DryRun) { Dry 'would download Spicetify'; return [pscustomobject]@{ Zip = ''; Version = $ver } }
        $zip = Join-Path $env:TEMP "spicetify-$ver-$suffix.zip"
        Save-Url -Url $url -OutFile $zip -MinBytes 1000000
        if (-not (Test-ZipEntry -Zip $zip -Pattern '(^|/)spicetify\.exe$')) {
            Fail "The Spicetify download is not a valid package (spicetify.exe is missing inside). Nothing was changed on your PC."
        }
        Good 'Spicetify package downloaded and checked.'
        return [pscustomobject]@{ Zip = $zip; Version = $ver }
    }

    function Get-MarketplacePackage {
        Step 'Getting Spicetify Marketplace'
        Say "    Download address: $MarketplaceUrl"
        if ($DryRun) { Dry 'would download marketplace.zip'; return $null }
        $zip = Join-Path $env:TEMP 'spotify-setup-marketplace.zip'
        Save-Url -Url $MarketplaceUrl -OutFile $zip -MinBytes 20000
        if (-not (Test-ZipEntry -Zip $zip -Pattern '(^|/)manifest\.json$')) {
            Fail 'The Marketplace download is not valid (manifest.json is missing inside). Nothing was changed on your PC. Re-run, or use -SkipMarketplace.'
        }
        Good 'Marketplace package downloaded and checked.'
        return $zip
    }

    # ----------------------------------------------------------------------------------
    # Detecting / removing Spotify
    # ----------------------------------------------------------------------------------
    function Test-StoreSpotify {
        # The Appx cmdlets are unreliable in PowerShell 7, so always ask Windows PowerShell 5.1.
        $ps = Get-WinPowerShell
        $cmd = "try { [Console]::Out.Write(@(Get-AppxPackage -Name '$StoreName' -ErrorAction Stop).Count) } catch { [Console]::Out.Write(0) }"
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmd 2>$null
            $txt = (($out | Out-String).Trim() -split '\s+' | Select-Object -Last 1)
            $n = 0
            if ([int]::TryParse([string]$txt, [ref]$n)) { return ($n -gt 0) }
            return $false
        }
        catch { return $false }
        finally { $ErrorActionPreference = $old }
    }

    function Remove-StoreSpotify {
        if (-not (Test-StoreSpotify)) { return }
        Say '    Removing the Microsoft Store version of Spotify ...'
        $ps = Get-WinPowerShell
        $cmd = "Get-AppxPackage -Name '$StoreName' | Remove-AppxPackage -ErrorAction Stop"
        [void](Invoke-Native -Exe $ps -ArgList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $cmd))
        if (Test-StoreSpotify) {
            $w = Get-Command winget.exe -ErrorAction SilentlyContinue
            if ($w) {
                Say '    Trying winget as a fallback ...'
                [void](Invoke-Native -Exe $w.Source -ArgList @('uninstall', '--id', $StoreWingetId, '--source', 'msstore', '--silent', '--accept-source-agreements'))
            }
        }
        if (Test-StoreSpotify) {
            Fail 'The Microsoft Store version of Spotify is still installed. Remove it by hand (Settings > Apps > Installed apps > Spotify > Uninstall) and run the script again.'
        }
        # leftover package data (best effort)
        try {
            $pk = Join-Path $env:LOCALAPPDATA 'Packages'
            Get-ChildItem -LiteralPath $pk -Filter "${StoreName}_*" -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
        catch { }
        Good 'Microsoft Store version removed.'
    }

    function Unlock-SpotifyUpdates {
        if (-not (Test-Path -LiteralPath $SpUpdate)) { return }
        $sid = Get-UserSid
        [void](Invoke-Native -Exe 'icacls.exe' -ArgList @($SpUpdate, '/remove:d', "*$sid") -Quiet)
    }

    function Reset-SpicetifyBackupState {
        # A fresh Spotify needs a fresh Spicetify backup. Clear the old one (config/themes are kept).
        $backupDir = Join-Path $SpicetifyCfg 'Backup'
        if (Test-Path -LiteralPath $backupDir) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $ini = Join-Path $SpicetifyCfg 'config-xpui.ini'
        if (Test-Path -LiteralPath $ini) {
            Copy-Item -LiteralPath $ini -Destination "$ini.bak-before-setup" -Force
            $section = ''
            $lines = foreach ($l in [System.IO.File]::ReadAllLines($ini)) {
                if ($l -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1] }
                if ($section -eq 'Backup' -and $l -match '^\s*(version|with)\s*=') { '{0} = ' -f $Matches[1] }
                else { $l }
            }
            [System.IO.File]::WriteAllLines($ini, [string[]]@($lines), (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    function Get-SpotifyState {
        # Looks at what is on this PC right now: FRESH install (no Spotify) vs REPLACE.
        $store    = Test-StoreSpotify
        $desktop  = Test-Path -LiteralPath $SpExe
        $leftover = (Test-Path -LiteralPath $SpRoaming) -or (Test-Path -LiteralPath $SpLocal)
        $ver = ''
        if ($desktop) { $ver = Get-ExeVersion -Path $SpExe }

        $machineWide = $false
        foreach ($d in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($d -and (Test-Path -LiteralPath (Join-Path $d 'Spotify\Spotify.exe'))) { $machineWide = $true }
        }

        $text = 'none - Spotify is not installed on this PC'
        if ($desktop -and $store) { $text = "$ver (desktop) + the Microsoft Store version" }
        elseif ($desktop)         { $text = "$ver (desktop version)" }
        elseif ($store)           { $text = 'the Microsoft Store version' }
        elseif ($leftover)        { $text = 'none - only leftover files of an old install' }

        return [pscustomobject]@{
            Installed   = ($desktop -or $store)
            Desktop     = $desktop
            Store       = $store
            Leftover    = $leftover
            MachineWide = $machineWide
            Text        = $text
        }
    }

    function Remove-OldSpotify {
        param($State)
        if ($State.Installed) { Step 'Removing the current Spotify' }
        else { Step 'Checking for an old Spotify (none installed - this will be a fresh install)' }
        if ($DryRun) {
            if ($State.Installed) { Dry "would close Spotify, remove the Store version if present, and delete '$SpRoaming' and '$SpLocal'" }
            else { Dry 'Spotify is not installed: nothing to delete (would only clear leftover files and any stale Spicetify backup)' }
            return
        }
        Stop-Spotify
        Remove-StoreSpotify
        Unlock-SpotifyUpdates
        Remove-FolderRobust -Path $SpRoaming -KillSpotify
        Remove-FolderRobust -Path $SpLocal -KillSpotify
        foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Spotify', 'HKCU:\Software\Spotify')) {
            if (Test-Path -Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        foreach ($name in @('Spotify', 'SpotifyWebHelper')) {
            Remove-ItemProperty -Path $run -Name $name -ErrorAction SilentlyContinue
        }
        Reset-SpicetifyBackupState

        # Verify instead of assuming.
        if (Test-Path -LiteralPath $SpExe) { Fail "Spotify.exe is still present in '$SpRoaming' after removal." }
        if (Test-StoreSpotify)             { Fail 'The Microsoft Store version of Spotify is still installed.' }
        if ($State.Installed) { Good 'Old Spotify removed and verified.' }
        else { Good 'Nothing to remove - ready for a fresh install.' }
    }

    # ----------------------------------------------------------------------------------
    # Installing Spotify
    # ----------------------------------------------------------------------------------
    function Wait-DirStable {
        param([string]$Path, [int]$MaxSeconds = 60)
        $last = -1
        $same = 0
        $end = (Get-Date).AddSeconds($MaxSeconds)
        while ((Get-Date) -lt $end) {
            $size = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($null -ne $size -and $size -eq $last -and $size -gt 0) { $same++ } else { $same = 0 }
            if ($same -ge 2) { return }
            $last = $size
            Start-Sleep -Seconds 1
        }
    }

    function Expand-SpotifyInstaller {
        # Extracts the installer into $Dest and returns the path of the extracted Spotify.exe.
        param([string]$Installer, [string]$Dest)
        Remove-FolderRobust -Path $Dest
        $argText = '/extract ' + $Dest
        if ($Dest -match '\s') { $argText = '/extract "' + $Dest + '"' }
        Start-Process -FilePath $Installer -ArgumentList $argText -Wait
        $exe = Join-Path $Dest 'Spotify.exe'
        $end = (Get-Date).AddSeconds(60)
        while (-not (Test-Path -LiteralPath $exe) -and (Get-Date) -lt $end) { Start-Sleep -Seconds 1 }
        if (-not (Test-Path -LiteralPath $exe)) {
            Fail "Spotify.exe was not created in '$Dest'. The installer did not extract (antivirus? wrong file?)."
        }
        Wait-DirStable -Path $Dest
        return $exe
    }

    function Test-InstallerVersion {
        # Extracts to a temporary folder and checks the version BEFORE anything on the PC is deleted.
        param([string]$Installer)
        Step "Checking that the installer really contains Spotify $SpotifyVersion"
        if ($DryRun) { Dry 'would extract the installer to a temporary folder and compare its version'; return }
        $exe = Expand-SpotifyInstaller -Installer $Installer -Dest $StageDir
        Stop-Spotify   # in case the installer started something
        $v = Get-ExeVersion -Path $exe
        if (-not (Test-ExeIsVersion -Path $exe -Want $SpotifyVersion)) {
            Remove-FolderRobust -Path $StageDir
            Fail "The installer contains Spotify '$v', not '$SpotifyVersion'. Nothing was changed on your PC. (With -InstallerPath/-InstallerUrl, make sure -SpotifyVersion matches that file.)"
        }
        Good "Installer contains Spotify $v - matches the requested version."
    }

    function Install-SpotifyClient {
        param([string]$Installer)
        Step "Installing Spotify $SpotifyVersion"
        if ($DryRun) { Dry "would copy the verified Spotify files into '$SpRoaming'"; return }
        if (-not (Test-Path -LiteralPath (Join-Path $StageDir 'Spotify.exe'))) {
            [void](Expand-SpotifyInstaller -Installer $Installer -Dest $StageDir)
            Stop-Spotify
        }
        $parent = Split-Path -Parent $SpRoaming
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if (Test-Path -LiteralPath $SpRoaming) { Remove-FolderRobust -Path $SpRoaming -KillSpotify }
        try { Move-Item -LiteralPath $StageDir -Destination $SpRoaming -ErrorAction Stop }
        catch {
            Say '    Move failed, copying instead ...'
            if (-not (Test-Path -LiteralPath $SpRoaming)) { New-Item -ItemType Directory -Path $SpRoaming -Force | Out-Null }
            Copy-Item -Path (Join-Path $StageDir '*') -Destination $SpRoaming -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath $SpExe)) { Fail "Spotify.exe was not created in '$SpRoaming'." }
        $found = Get-ExeVersion -Path $SpExe
        if (-not (Test-ExeIsVersion -Path $SpExe -Want $SpotifyVersion)) {
            Fail "Installed Spotify is version '$found' but '$SpotifyVersion' was requested."
        }
        Good "Spotify $found installed and verified."
    }

    function New-SpotifyShortcuts {
        if ($DryRun) { Dry 'would create the desktop and Start menu shortcuts and the Apps & Features entry'; return }
        try {
            $shell = New-Object -ComObject WScript.Shell
            $folders = @(
                [Environment]::GetFolderPath('Desktop'),
                (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
            )
            foreach ($dir in $folders) {
                if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
                $lnk = $shell.CreateShortcut((Join-Path $dir 'Spotify.lnk'))
                $lnk.TargetPath = $SpExe
                $lnk.WorkingDirectory = $SpRoaming
                $lnk.Save()
            }
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Spotify'
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name 'DisplayName' -Value 'Spotify'
            Set-ItemProperty -Path $key -Name 'DisplayIcon' -Value "$SpExe,0"
            Set-ItemProperty -Path $key -Name 'DisplayVersion' -Value (Get-ExeVersion -Path $SpExe)
            Set-ItemProperty -Path $key -Name 'Publisher' -Value 'Spotify AB'
            Set-ItemProperty -Path $key -Name 'UninstallString' -Value ('"{0}" /uninstall' -f $SpExe)
            Good 'Shortcuts created.'
        }
        catch { Warn "Could not create shortcuts (not critical): $($_.Exception.Message)" }
    }

    # ----------------------------------------------------------------------------------
    # Blocking Spotify updates
    # ----------------------------------------------------------------------------------
    function Test-UpdateLockWorks {
        # Real test: try to create a file in the Update folder. If it works, the lock is NOT effective.
        if (-not (Test-Path -LiteralPath $SpUpdate)) { return $false }
        $probe = Join-Path $SpUpdate 'lock-test.tmp'
        try {
            [IO.File]::WriteAllText($probe, 'x')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            return $false
        }
        catch { return $true }
    }

    function Lock-SpotifyUpdates {
        Step 'Blocking Spotify auto-updates'
        if ($DryRun) { Dry "would recreate '$SpUpdate' and deny your user write/delete/read on it"; return }
        if (Test-Path -LiteralPath $SpUpdate) {
            Unlock-SpotifyUpdates
            Remove-FolderRobust -Path $SpUpdate -KillSpotify
        }
        New-Item -ItemType Directory -Path $SpUpdate -Force | Out-Null
        $sid = Get-UserSid
        $code = Invoke-Native -Exe 'icacls.exe' -ArgList @($SpUpdate, '/deny', "*${sid}:(W,D,R)") -Quiet
        if ($code -ne 0) { Fail "icacls failed (exit code $code) while locking '$SpUpdate'." }
        if (-not (Test-UpdateLockWorks)) { Fail 'The update lock did not take effect (a file could still be created in the Update folder).' }
        Good "Update folder locked and verified: $SpUpdate"
    }

    # ----------------------------------------------------------------------------------
    # Spicetify + Marketplace
    # ----------------------------------------------------------------------------------
    function Install-SpicetifyCli {
        param($Package)
        Step 'Installing Spicetify'
        if ($DryRun) { Dry "would unpack Spicetify into '$SpicetifyDir' and add it to your PATH"; return }
        if (-not (Test-Path -LiteralPath $SpicetifyDir)) { New-Item -ItemType Directory -Path $SpicetifyDir -Force | Out-Null }
        Get-Process -Name 'spicetify' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Expand-ZipSafe -Zip $Package.Zip -Dest $SpicetifyDir
        if (-not (Test-Path -LiteralPath $SpicetifyExe)) { Fail "spicetify.exe was not found in '$SpicetifyDir' after unpacking." }
        Add-ToUserPath -Dir $SpicetifyDir
        Good "Spicetify $($Package.Version) installed in $SpicetifyDir"
    }

    function Wait-ForSpotifyPrefs {
        # Returns 'full' (Spotify wrote its launch marker), 'weak' (file exists but marker not seen) or ''.
        param([int]$Seconds)
        $end = (Get-Date).AddSeconds($Seconds)
        $weak = $false
        while ((Get-Date) -lt $end) {
            try {
                if (Test-Path -LiteralPath $SpPrefs) {
                    $fs = New-Object IO.FileStream($SpPrefs, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    try {
                        $sr = New-Object IO.StreamReader($fs)
                        $txt = $sr.ReadToEnd()
                    }
                    finally { $fs.Dispose() }
                    if ($txt -match 'app\.last-launched-version') { Start-Sleep -Seconds 3; return 'full' }
                    if ($txt.Length -gt 0) { $weak = $true }
                }
            }
            catch { }
            Start-Sleep -Seconds 2
        }
        if ($weak) { return 'weak' }
        return ''
    }

    function Initialize-SpotifyFirstRun {
        # Spicetify reads Spotify's settings file ("prefs"). Spotify only creates it after it has run once.
        Step 'Starting Spotify once so it creates its settings file'
        if ($DryRun) { Dry 'would start Spotify, wait for its settings file, then close it'; return }
        Say '    A brand-new Spotify may show a welcome or login screen - that is normal.'
        Say '    The script closes it for you; you can log in afterwards.'
        Start-Process -FilePath $SpExe
        $r = Wait-ForSpotifyPrefs -Seconds 60
        if ($r -eq '' -and -not $Yes) {
            Warn 'Spotify has not written its settings file yet.'
            Say  '    Look at the Spotify window: finish the first-run screen / log in if it asks.'
            try { [void](Read-Host '    Press Enter here when Spotify is open') } catch { }
            $r = Wait-ForSpotifyPrefs -Seconds 40
        }
        elseif ($r -eq '') {
            $r = Wait-ForSpotifyPrefs -Seconds 60
        }
        Stop-Spotify -Graceful
        if ($r -eq 'full') { Good 'Spotify created its settings file.' }
        elseif ($r -eq 'weak') { Warn "Settings file exists but is incomplete ('$SpPrefs'); continuing anyway." }
        else { Warn "Settings file not confirmed ('$SpPrefs'). If Spicetify complains: open Spotify, log in, close it and run  spicetify backup apply" }

        # Spotify must not have updated itself in the meantime.
        if (-not (Test-ExeIsVersion -Path $SpExe -Want $SpotifyVersion)) {
            Fail "Spotify changed its version while starting (now '$(Get-ExeVersion -Path $SpExe)', wanted '$SpotifyVersion'). The update block did not hold."
        }
    }

    function Invoke-SpicetifyConfigure {
        Step 'Configuring Spicetify'
        if ($DryRun) { Dry 'would run: spicetify config spotify_path / prefs_path'; return }
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'spotify_path', $SpRoaming))
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'prefs_path', $SpPrefs))
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'check_spicetify_update', '0') -Quiet)
        Good 'Spicetify paths configured.'
    }

    function Install-Marketplace {
        param([string]$Zip)
        Step 'Installing Spicetify Marketplace'
        if ($DryRun) { Dry 'would copy Marketplace into the Spicetify CustomApps folder and enable it'; return }
        $apps = Join-Path $SpicetifyCfg 'CustomApps'
        $dest = Join-Path $apps 'marketplace'
        if (-not (Test-Path -LiteralPath $apps)) { New-Item -ItemType Directory -Path $apps -Force | Out-Null }
        if (Test-Path -LiteralPath $dest) { Remove-FolderRobust -Path $dest }
        Remove-FolderRobust -Path $MarketTmp
        Expand-ZipSafe -Zip $Zip -Dest $MarketTmp
        $m = Get-ChildItem -LiteralPath $MarketTmp -Recurse -Filter 'manifest.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $m) { Fail 'Marketplace package has no manifest.json after unpacking.' }
        Move-Item -LiteralPath $m.DirectoryName -Destination $dest -Force
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'manifest.json'))) { Fail "Marketplace was not copied to '$dest'." }
        # drop the old app name if an earlier install used it, then enable the new one
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'custom_apps', 'spicetify-marketplace-', '-q') -Quiet)
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'custom_apps', 'marketplace') -Quiet)
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'inject_css', '1', 'replace_colors', '1') -Quiet)
        Good 'Marketplace installed and enabled.'
    }

    function Invoke-SpicetifyApply {
        Step 'Applying Spicetify'
        if ($DryRun) { Dry 'would run: spicetify backup apply'; return }
        Stop-Spotify
        $code = Invoke-Native -Exe $SpicetifyExe -ArgList @('backup', 'apply')
        if ($code -ne 0) {
            Warn "'spicetify backup apply' failed (exit code $code). Trying 'restore backup apply' ..."
            $code = Invoke-Native -Exe $SpicetifyExe -ArgList @('restore', 'backup', 'apply')
        }
        if ($code -ne 0) {
            Fail "Spicetify could not be applied (exit code $code). Send the log file to whoever is helping you: $LogFile"
        }
        Good 'Spicetify applied.'
    }

    function Remove-TempFiles {
        foreach ($p in @($StageDir, $MarketTmp)) {
            try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        }
        foreach ($f in @((Join-Path $env:TEMP 'spotify-setup-marketplace.zip'))) {
            try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
        }
    }

    # ----------------------------------------------------------------------------------
    # Main
    # ----------------------------------------------------------------------------------
    function Invoke-Main {
        Write-Host ''
        Write-Host 'ElBulbol - Spotify + Spicetify setup (more about me: https://elbulbol.github.io/)' -ForegroundColor Green
        Write-Host 'This can take a few minutes. Log file: ' -NoNewline; Write-Host $LogFile -ForegroundColor DarkGray
        if ($DryRun) { Write-Host '*** DRY RUN: nothing will be changed ***' -ForegroundColor Magenta }

        # ---- pre-flight ----
        if ($env:OS -ne 'Windows_NT') { Fail 'This script only works on Windows.' }
        if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Windows 10 or newer is required.' }
        if ($PSVersionTable.PSVersion.Major -lt 5) { Fail 'PowerShell 5.1 or newer is required.' }
        if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
            Fail "PowerShell is in '$($ExecutionContext.SessionState.LanguageMode)' mode (a security policy restricts it). This script cannot run here."
        }
        if (Test-IsAdmin) {
            if ($DryRun) { Warn 'You are running as Administrator. The real run must be done in a normal PowerShell window.' }
            else { Fail 'Please close this window and run the script in a NORMAL (non-administrator) PowerShell window. Spotify must not be installed as admin.' }
        }
        if ($SpotifyVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { Fail "Invalid -SpotifyVersion '$SpotifyVersion'. Example: 1.2.98.301" }
        if ($SpicetifyVersion -ne 'latest' -and $SpicetifyVersion.TrimStart('v') -notmatch '^\d+\.\d+\.\d+$') {
            Fail "Invalid -SpicetifyVersion '$SpicetifyVersion'. Use 'latest' or a number like 2.45.3"
        }
        if ($InstallerPath -and $InstallerUrl) { Fail 'Use either -InstallerPath or -InstallerUrl, not both.' }
        if (-not $env:APPDATA -or -not $env:LOCALAPPDATA -or -not $env:TEMP) { Fail 'APPDATA / LOCALAPPDATA / TEMP are not set - cannot continue.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultCredentials } catch { }
        Test-FreeSpace -Path $env:TEMP -NeedBytes ([long]700MB)
        Test-FreeSpace -Path $env:LOCALAPPDATA -NeedBytes ([long]700MB)

        $arch  = Get-OsArch
        $state = Get-SpotifyState

        Step 'Plan'
        Say "    This PC            : Windows, $arch"
        Say "    Spotify installed  : $($state.Text)"
        Say "    Spotify to install : $SpotifyVersion"
        Say "    Spicetify          : $SpicetifyVersion"
        if ($SkipMarketplace) { Say '    Marketplace        : skipped' } else { Say '    Marketplace        : will be installed' }
        Say ''
        Say '    1. Download and verify everything first (nothing changes if this fails)'
        if ($state.Installed) {
            Say '    2. Close and DELETE the current Spotify (desktop + Store version; local cache and offline'
            Say '       downloads are lost; your account, playlists and liked songs are safe in your account)'
        }
        else {
            Say '    2. Spotify is not installed on this PC, so there is nothing to remove'
            Say '       (it will be installed fresh; any leftover junk files are cleaned up)'
        }
        Say "    3. Install Spotify $SpotifyVersion, check its version, and block its auto-updates"
        Say '    4. Install Spicetify (your Spicetify themes/extensions are kept)'
        Say '    5. Start Spotify once, close it, install Marketplace, run "spicetify backup apply"'
        if ($state.MachineWide) {
            Warn 'A machine-wide Spotify exists in Program Files. This script cannot remove it without admin rights; remove it yourself if Spotify misbehaves.'
        }

        if (-not $Yes -and -not $DryRun) {
            Write-Host ''
            $answer = ''
            try { $answer = Read-Host 'Continue? (Y/N)' } catch { Fail 'No interactive console available. Re-run with -Yes.' }
            if ($answer -notmatch '^[Yy]') { Say 'Cancelled. Nothing was changed.'; return }
        }

        # ---- download + verify EVERYTHING before touching the PC ----
        $installer = Get-SpotifyInstaller -Version $SpotifyVersion -Arch $arch
        $package   = Get-SpicetifyPackage -Arch $arch
        $market    = $null
        if (-not $SkipMarketplace) { $market = Get-MarketplacePackage }
        if ($installer) { Test-InstallerVersion -Installer $installer } else { Test-InstallerVersion -Installer '' }

        # ---- the real work ----
        Remove-OldSpotify -State $state
        Install-SpotifyClient -Installer $installer
        New-SpotifyShortcuts
        Lock-SpotifyUpdates
        Install-SpicetifyCli -Package $package
        Initialize-SpotifyFirstRun
        Invoke-SpicetifyConfigure
        if (-not $SkipMarketplace) { Install-Marketplace -Zip $market }
        Invoke-SpicetifyApply

        # ---- summary ----
        Write-Host ''
        if ($DryRun) {
            Write-Host 'Dry run finished. Nothing was changed.' -ForegroundColor Magenta
        }
        else {
            Write-Host 'All done.' -ForegroundColor Green
            $sv = Get-ExeVersion -Path $SpExe
            $lockOk = Test-UpdateLockWorks
            Say "    Spotify     : $sv"
            if ($lockOk) { Say '    Update lock : active' } else { Warn 'Update lock is NOT active.' }
            Say "    Spicetify   : $($package.Version)"
            if ($SkipMarketplace) { Say '    Marketplace : skipped' } else { Say '    Marketplace : installed (look for it in the Spotify sidebar)' }
            Say '    To allow Spotify updates again (Command Prompt):'
            Say '      icacls "%localappdata%\Spotify\Update" /remove:d "%username%"'
            Say '    Open a NEW terminal window before typing "spicetify" yourself (PATH was updated).'
            if (-not $SkipMarketplace) {
                Say '    Note: if Marketplace does not show up, the newest Marketplace may not support this old Spotify version.'
            }
        }
        if ($Warnings.Count -gt 0) {
            Write-Host ''
            Write-Host "    $($Warnings.Count) warning(s) were shown above - please read them." -ForegroundColor Yellow
        }
    }

    $transcriptStarted = $false
    $failed = $false
    try {
        try { Start-Transcript -Path $LogFile -Force | Out-Null; $transcriptStarted = $true } catch { }
        Invoke-Main
    }
    catch {
        $failed = $true
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Log file: $LogFile" -ForegroundColor Yellow
    }
    finally {
        try { Remove-TempFiles } catch { }
        if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    }

    if (-not $Yes -and -not $NoPause) {
        Write-Host ''
        try { [void](Read-Host 'Press Enter to finish') } catch { }
    }

    # "exit" would CLOSE the user's PowerShell window when started with  iwr | iex,
    # so it is only used when the script was started from a file.
    if ($failed -and $PSCommandPath) { exit 1 }
} $args
