# Registry helper functions
function Set-RegistryValue($Path, $Name, $Type, $Data) {
    reg add "$Path" /v "$Name" /t "$Type" /d "$Data" /f 2>$null | Out-Null
}
function Remove-RegistryValue($Path) {
    reg delete "$Path" /f 2>$null | Out-Null
}

# Phase 1: Administrator privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "You must run Powershell with Administrator privileges!" -ForegroundColor Red
    Pause
    Exit
}

# Phase 2: Creating workspaces
$Workspace = "C:\ElflowerBuilder"
$MountDir = "$Workspace\Mount"
$ExtractDir = "$Workspace\Extract"
$FinalISO = "C:\Elflower.iso"

Clear-Host
Write-Host "=== PastelPink Elflower w/ Administrator Builder ===" -ForegroundColor Cyan
Write-Host "=== for Windows 10 ===" -ForegroundColor Cyan

# Phase 3: Cleaning stuffs
Write-Host "[*] Cleaning up previous workspaces..." -ForegroundColor DarkGray
reg unload HKLM\zCOMPONENTS 2>$null | Out-Null
reg unload HKLM\zDEFAULT 2>$null | Out-Null
reg unload HKLM\zNTUSER 2>$null | Out-Null
reg unload HKLM\zSOFTWARE 2>$null | Out-Null
reg unload HKLM\zSYSTEM 2>$null | Out-Null
dism.exe /Cleanup-Wim /Quiet | Out-Null
dism.exe /Cleanup-Mountpoints /Quiet | Out-Null

if (Test-Path $Workspace) { 
    Remove-Item -Path $Workspace -Recurse -Force -ErrorAction SilentlyContinue 
    # Forcing Powershell to wait for deleting heavy stuffs
    Start-Sleep -Seconds 2
}

New-Item -ItemType Directory -Force -Path $MountDir | Out-Null
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null

# Phase 4: ISO Selection
$IsoPath = Read-Host "-> Enter the path of the original ISO (Example: C:\Windows10.iso)"
if (!(Test-Path $IsoPath -PathType Leaf)) {
    Write-Host "Cannot find the ISO, please check the path again :3" -ForegroundColor Red
    Exit
}

# Phase 5: Mounting ISO and copying
Write-Host "`n[1/13] Mounting ISO and copying contents into the workspace..." -ForegroundColor Yellow
$IsoImage = Mount-DiskImage -ImagePath $IsoPath -PassThru
$IsoDrive = ($IsoImage | Get-Volume).DriveLetter + ":"

robocopy "$IsoDrive\" "$ExtractDir" /E /MT:8 /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null

Dismount-DiskImage -ImagePath $IsoPath | Out-Null
$InstallSystem = "wim"
if (Test-Path "$ExtractDir\sources\install.esd") {
    $InstallSystem = "esd"
}
Set-ItemProperty -Path "$ExtractDir\sources\install.$InstallSystem" -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
Set-ItemProperty -Path "$ExtractDir\sources\boot.wim" -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

# Phase 6: Choosing index
Write-Host "`n[2/13] List of available Windows SKUs:" -ForegroundColor Yellow
dism.exe /Get-WimInfo /WimFile:"$ExtractDir\sources\install.$InstallSystem"
$WimIndex = Read-Host "-> Enter the index number you want to build (e.g., 6)"
if ([string]::IsNullOrWhiteSpace($WimIndex)) { $WimIndex = "1" }

Write-Host "`n[3/13] Extracting Windows system (Mounting WIM Index $WimIndex)..." -ForegroundColor Yellow
dism.exe /Mount-Image /ImageFile:"$ExtractDir\sources\install.$InstallSystem" /Index:$WimIndex /MountDir:"$MountDir" /Optimize

# Phase 7: Debloating
$AdminGroup = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value

Write-Host "`n[4/13] Debloating system apps..." -ForegroundColor Yellow
Write-Host "  - Dynamically scanning and removing UWP/APPX apps..." -ForegroundColor DarkGray

$KeepApps = @(
    "Microsoft.AV1VideoExtension",
    "Microsoft.AVCEncoderVideoExtension",
    "Microsoft.DesktopAppInstaller",
    "Microsoft.HEIFImageExtension",
    "Microsoft.HEVCVideoExtension",
    "Microsoft.MPEG2VideoExtension",
    "Microsoft.NET.Native",
    "Microsoft.RawImageExtension",
    "Microsoft.SecHealthUI",
    "Microsoft.Services.Store.Engagement",
    "Microsoft.StorePurchaseApp",
    "Microsoft.UI.Xaml",
    "Microsoft.VCLibs",
    "Microsoft.VP9VideoExtensions",
    "Microsoft.WebMediaExtensions",
    "Microsoft.WebpImageExtension",
    "Microsoft.WindowsAppRuntime"
)


$InstalledPackages = Get-AppxProvisionedPackage -Path $MountDir

foreach ($App in $InstalledPackages) {
    $IsKept = $false
    
    foreach ($Keep in $KeepApps) {
        if ($App.DisplayName -match $Keep -or $App.PackageName -match $Keep) {
            $IsKept = $true
            break
        }
    }

    if (-not $IsKept) {
        Write-Host "  - Deleted $($App.DisplayName)" -ForegroundColor DarkGray
        Remove-AppxProvisionedPackage -Path $MountDir -PackageName $App.PackageName -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-Host "  - Kept $($App.DisplayName)" -ForegroundColor Green
    }
}

Write-Host "`n[5/13] Removing Edge and OneDrive..." -ForegroundColor Yellow

$EdgePaths = @(
    "$MountDir\Program Files (x86)\Microsoft\Edge",
    "$MountDir\Program Files (x86)\Microsoft\EdgeUpdate",
    "$MountDir\Program Files (x86)\Microsoft\EdgeCore"
)

foreach ($Path in $EdgePaths) {
    if (Test-Path $Path) {
        Write-Host "  - Removed $Path" -ForegroundColor DarkGray
        takeown.exe /F $Path /R /A /D Y 2>$null | Out-Null
        icacls.exe $Path /grant "$($AdminGroup):(F)" /T /C /Q 2>$null | Out-Null
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$OneDrivePaths = @(
    "$MountDir\Windows\System32\OneDriveSetup.exe",
    "$MountDir\Windows\SysWOW64\OneDriveSetup.exe"
)

foreach ($Path in $OneDrivePaths) {
    if (Test-Path $Path) {
        if ((Get-Item $Path) -is [System.IO.DirectoryInfo]) {
            takeown.exe /F $Path /R /A /D Y 2>$null | Out-Null
            icacls.exe $Path /grant "$($AdminGroup):(F)" /T /C /Q 2>$null | Out-Null
        } else {
            takeown.exe /F $Path /A 2>$null | Out-Null
            icacls.exe $Path /grant "$($AdminGroup):(F)" /C /Q 2>$null | Out-Null
        }
        
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue

        if (!(Test-Path $Path)) {
            Write-Host "  - Removed $Path" -ForegroundColor DarkGray
        } else {
            Write-Host "  - Failed to remove $Path" -ForegroundColor Red
        }
    }
}

Write-Host "`n[6/13] Removing Telemetry files..." -ForegroundColor Yellow

Write-Host "  - Deleting Telemetry files..." -ForegroundColor DarkGray

$TelemetryFiles = @(
    "$MountDir\Windows\System32\appraiser.exe",
    "$MountDir\Windows\System32\CompatTelRunner.exe",
    "$MountDir\Windows\System32\DeviceCensus.exe",
    "$MountDir\Windows\System32\wsqmcons.exe"
)

foreach ($File in $TelemetryFiles) {
    if (Test-Path $File) {
        takeown.exe /F $File /A 2>$null | Out-Null
        icacls.exe $File /grant "$($AdminGroup):(F)" /C /Q 2>$null | Out-Null
        Remove-Item -Path $File -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "  - Deleting Retail Demo & Help..." -ForegroundColor DarkGray
$UselessFolders = @(
    "$MountDir\Windows\System32\RetailDemo",
    "$MountDir\Windows\Help",
    "$MountDir\Windows\System32\DiagSvcs",
    "$MountDir\PerfLogs"
)

foreach ($Folder in $UselessFolders) {
    if (Test-Path $Folder) {
        takeown.exe /F $Folder /R /A /D Y 2>$null | Out-Null
        icacls.exe $Folder /grant "$($AdminGroup):(F)" /T /C /Q 2>$null | Out-Null
        Remove-Item -Path $Folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$OptionalFeatures = @(
    "FaxServicesClientPackage",
    "Printing-Foundation-InternetPrinting-Client",
    "WorkFolders-Client",
    "MediaPlayback",
    "SMB1Protocol"
)

foreach ($Feature in $OptionalFeatures) {
    $CheckFeature = Get-WindowsOptionalFeature -Path $MountDir -FeatureName $Feature -ErrorAction SilentlyContinue
    
    if ($CheckFeature) {
        Write-Host "  - Deleted $Feature" -ForegroundColor DarkGray
        try {
            Disable-WindowsOptionalFeature -Path $MountDir -FeatureName $Feature -Remove -NoRestart -ErrorAction Stop | Out-Null
        } catch {
        }
    } else {
        Write-Host "  - Skipped $Feature (Not found in this Windows edition)" -ForegroundColor DarkGray
    }
}

# Phase 8: Removing SystemPackages
Write-Host "`n[7/13] Removing system packages..." -ForegroundColor Yellow

$PackagePatterns = @(
    "*InternetExplorer-Optional*",
    "*LanguageFeatures-Handwriting*",
    "*LanguageFeatures-OCR*",
    "*LanguageFeatures-Speech*",
    "*LanguageFeatures-TextToSpeech*",
    "*MediaPlayer*",
    "*OneDrive-Setup-Package*",
    "*PowerShell-ISE-FOD*",
    "*QuickAssist-*",
    "*StepsRecorder*",
    "*TabletPCMath*",
    "*Wallpaper-Content-Extended*",
    "*WordPad-FoD*"
)

Write-Host "  - Scanning system packages..." -ForegroundColor DarkGray
$DismPackagesOutput = dism.exe /Image:"$MountDir" /Get-Packages /English

$AllPackageNames = $DismPackagesOutput | Select-String "Package Identity : " | ForEach-Object {
    $_.Line.Replace("Package Identity : ", "").Trim()
}

foreach ($Pattern in $PackagePatterns) {
    $PackagesToRemove = $AllPackageNames | Where-Object { $_ -like $Pattern }
    
    if ($PackagesToRemove) {
        foreach ($Pkg in $PackagesToRemove) {
            Write-Host "  - Removed $Pkg" -ForegroundColor DarkGray
            dism.exe /Image:"$MountDir" /Remove-Package /PackageName:"$Pkg" /Quiet /NoRestart | Out-Null
        }
    }
}

# Phase 9: Registry"ing"
Write-Host "`n[8/13] Applying registry..." -ForegroundColor Yellow
try {
    reg load HKLM\zCOMPONENTS "$MountDir\Windows\System32\config\COMPONENTS" | Out-Null
    reg load HKLM\zDEFAULT "$MountDir\Windows\System32\config\default" | Out-Null
    reg load HKLM\zNTUSER "$MountDir\Users\Default\ntuser.dat" | Out-Null
    reg load HKLM\zSOFTWARE "$MountDir\Windows\System32\config\SOFTWARE" | Out-Null
    reg load HKLM\zSYSTEM "$MountDir\Windows\System32\config\SYSTEM" | Out-Null

    Write-Host "  - Disabling Sponsored Apps & Content Delivery..."
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{\"pinnedList\": [{}]}'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    Write-Output "  - Enabling Local Accounts on OOBE..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
    Write-Output "  - Disabling Reserved Storage..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
    Write-Output "  - Disabling BitLocker Device Encryption..."
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
    Write-Output "  - Disabling Services..."
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\SysMain' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\DiagTrack' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\BITS' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\DoSvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\DPS' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WdiServiceHost' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WdiSystemHost' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\PcaSvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\FontCache' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WbioSrvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\DusmSvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WpnService' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\LanmanServer' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\LanmanWorkstation' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\TrkWks' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\MapsBroker' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WerSvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\Spooler' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\SDRSVC' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\wbengine' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\fhsvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\wisvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\RemoteRegistry' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\PhoneSvc' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\RetailDemo' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\shpamsvc' 'Start' 'REG_DWORD' '4'
    Write-Output "  - Disabling OneDrive folder backup..."
    Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
    Write-Output "  - Disabling Telemetry..."
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
    Write-Output "  - Preventing installation of apps..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
    Write-Output "  - Disabling Folder Auto Discovery..."
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'REG_SZ' 'NotSpecified'
    Write-Output "  - Disabling Search Highlights..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 'REG_DWORD' '0'
    Write-Output "  - Disabling Bing..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 'REG_DWORD' '0'
    Write-Output "  - Disabling Copilot..."
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
    Write-Output "  - Disabling OneDrive ActiveSetup..."
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Active Setup\Installed Components\{8A69D345-D564-463c-AFF1-A69D9E530F96}'
    Write-Output "  - Disabling Start Menu Iris recommendation..."
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 'REG_DWORD' '0'
    Write-Output "  - Disabling GameDVR and Xbox Game Bar..."
    Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\BcastDVRUserService' 'Start' 'REG_DWORD' '4'
    Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\GameBarPresenceWriter' 'Start' 'REG_DWORD' '4'
    Write-Output "  - Removing residual OneDrive Startup key..."
    Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Run\OneDriveSetup'
    Write-Output "  - Deleting Edge related registries..."
    Remove-RegistryValue "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    Remove-RegistryValue "HKLM\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\EdgeUpdate' 'DoNotUpdateToEdgeWithChromium' 'REG_DWORD' '1'
    Write-Output "  - Deleting Telemetry Scheduled Tasks..."
    $tasksPath = "$MountDir\Windows\System32\Tasks"
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
}
finally {
    reg unload HKLM\zCOMPONENTS 2>$null | Out-Null
    reg unload HKLM\zDEFAULT 2>$null | Out-Null
    reg unload HKLM\zNTUSER 2>$null | Out-Null
    reg unload HKLM\zSOFTWARE 2>$null | Out-Null
    reg unload HKLM\zSYSTEM 2>$null | Out-Null
    [GC]::Collect()
    Start-Sleep -Seconds 3
}

# Phase 10: ResetBase
Write-Host "`n[9/13] Deep cleaning image components..." -ForegroundColor Yellow

Write-Host "  - Applying ResetBase..." -ForegroundColor DarkGray
dism.exe /Image:$MountDir /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null

Write-Host "  - Emptying WinSxS Temp..." -ForegroundColor DarkGray
Remove-Item -Path "$MountDir\Windows\WinSxS\Backup\*" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$MountDir\Windows\WinSxS\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$MountDir\Windows\WinSxS\InstallTemp\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "  - Emptying Windows Update Cache..." -ForegroundColor DarkGray
Remove-Item -Path "$MountDir\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$MountDir\Windows\SoftwareDistribution\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue

# Phase 11: Saving & Exporting
Write-Host "`n[10/13] Saving changes to install.$InstallSystem..." -ForegroundColor Yellow
dism.exe /Unmount-Image /MountDir:"$MountDir" /Commit | Out-Null

Write-Host "`n[!] Choose compression:" -ForegroundColor Cyan
Write-Host "   [1] WIM (Fast but also recommended)" -ForegroundColor Cyan
Write-Host "   [2] ESD (Slow, smallest size)" -ForegroundColor Cyan
$Choice = Read-Host "-> Enter 1 or 2 (Default: 1)"

$DestExt = if ($Choice -eq '2') { "esd" } else { "wim" }
$CompressType = if ($Choice -eq '2') { "recovery" } else { "max" }

$SourceFile = "$ExtractDir\sources\install.$InstallSystem"
$OptimizedFile = "$ExtractDir\sources\install_optimized.$DestExt"

Write-Host "  - Exporting and optimizing to install.$DestExt..." -ForegroundColor DarkGray
dism.exe /Export-Image /SourceImageFile:$SourceFile /SourceIndex:$WimIndex /DestinationImageFile:$OptimizedFile /Compress:$CompressType | Out-Null

Remove-Item -Path $SourceFile -Force
Rename-Item -Path $OptimizedFile -NewName "install.$DestExt"

$InstallSystem = $DestExt

# Phase 12: Autounattend.xml
Write-Host "`n[11/13] Generating autounattend.xml..." -ForegroundColor Yellow

$XmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <DynamicUpdate>
                <WillShowUI>OnError</WillShowUI>
                <Enable>false</Enable>
            </DynamicUpdate>
            <ImageInstall>
                <OSImage>
                    <Compact>false</Compact>
                    <WillShowUI>OnError</WillShowUI>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>$WimIndex</Value>
                        </MetaData>
                    </InstallFrom>
                </OSImage>
            </ImageInstall>
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
        </component>
    </settings>
</unattend>
"@

$XmlContent | Out-File -FilePath "$ExtractDir\autounattend.xml" -Encoding UTF8

Write-Host "  - Injecting ei.cfg to skip Product Key prompts..." -ForegroundColor DarkGray
$EiCfgContent = @"
[EditionID]

[Channel]
Retail
[VL]
0
"@
$EiCfgContent | Out-File -FilePath "$ExtractDir\sources\ei.cfg" -Encoding ASCII

# Phase 13: Creating ISO files
Write-Host "`n[12/13] ISO Creation Process..." -ForegroundColor Yellow

$OscdimgPath = "$Workspace\oscdimg.exe"
$MicrosoftUrl = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

if (!(Test-Path $OscdimgPath)) {
    Write-Host "-> Cannot find oscdimg, downloading securely from Microsoft..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $MicrosoftUrl -OutFile $OscdimgPath -UseBasicParsing
        Write-Host "-> Completed!" -ForegroundColor Green
    } catch {
        Write-Host "-> Error: Cannot download tool!" -ForegroundColor Red
    }
}

if (Test-Path $OscdimgPath) {
    Write-Host "Building ISO... (Please wait)" -ForegroundColor Cyan
    $BuildArgs = "-m -o -u2 -udfver102 -bootdata:2#p0,e,b`"$ExtractDir\boot\etfsboot.com`"#pEF,e,b`"$ExtractDir\efi\microsoft\boot\efisys.bin`" `"$ExtractDir`" `"$FinalISO`""
    
    Start-Process -FilePath $OscdimgPath -ArgumentList $BuildArgs -Wait -NoNewWindow
    
    Write-Host "`n[13/11] Completed! Your ISO is ready at: $FinalISO" -ForegroundColor Green
    Write-Host "Cleaning up workspace..." -ForegroundColor DarkGray
    Remove-Item -Path $Workspace -Recurse -Force
} else {
    Write-Host "`n[!] Cannot compress into ISO, your Windows path is: $ExtractDir" -ForegroundColor Yellow
}

Write-Host "`nPress Enter to exit..."
Read-Host
