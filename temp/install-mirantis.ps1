# The MIT License (MIT)
#
# Copyright (c) 2015 Microsoft Azure
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

<#
.SYNOPSIS
    This script checks if Mirantis needs to be installed by downloading and executing the Mirantis installer, after successful installation the machine will be restarted.
    More information about the Mirantis installer, see: https://docs.mirantis.com/mcr/20.10/install/mcr-windows.html

.NOTES
    v 1.0.4 adding support for docker ce using https://github.com/microsoft/Windows-Containers/tree/Main/helpful_tools/Install-DockerCE 
        https://docs.docker.com/desktop/install/windows-install/
        https://learn.microsoft.com/en-us/azure/virtual-machines/acu

.PARAMETER dockerVersion
[string] Version of docker to install. Default will be to install latest version.
Format '0.0.0.'

.PARAMETER allowUpgrade
[switch] Allow upgrade of docker. Default is to not upgrade version of docker.

.PARAMETER hypervIsolation
[switch] Install Hyper-V feature / components. Default is to not install Hyper-V feature.
Mirantis install will install container feature.

.PARAMETER installContainerD
[switch] Install containerd. Default is to not install containerd.
containerd is not needed for docker functionality.

.PARAMETER mirantisInstallUrl
[string] Mirantis installation script url. Default is 'https://get.mirantis.com/install.ps1'

.PARAMETER uninstall
[switch] Uninstall docker only. This will not uninstall containerd or Hyper-V feature. 

.PARAMETER norestart
[switch] No restart after installation of docker and container feature. By default, after installation, node is restarted.
Use of -norestart is not supported.

.PARAMETER registerEvent
[bool] If true, will write installation summary information to the Application event log. Default is true.

.PARAMETER registerEventSource
[string] Register event source name used to write installation summary information to the Application event log.. Default name is 'CustomScriptExtension'.

.INPUTS
    None. You cannot pipe objects to Add-Extension.

.OUTPUTS
    Result object from the execution of https://get.mirantis.com/install.ps1.

.EXAMPLE
parameters.json :
{
  "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "customScriptExtensionFile": {
      "value": "install-mirantis.ps1"
    },
    "customScriptExtensionFileUri": {
      "value": "https://aka.ms/install-mirantis.ps1"
    },

template json :
"virtualMachineProfile": {
    "extensionProfile": {
        "extensions": [
            {
                "name": "CustomScriptExtension",
                "properties": {
                    "publisher": "Microsoft.Compute",
                    "type": "CustomScriptExtension",
                    "typeHandlerVersion": "1.10",
                    "autoUpgradeMinorVersion": true,
                    "settings": {
                        "fileUris": [
                            "[parameters('customScriptExtensionFileUri')]"
                        ],
                        "commandToExecute": "[concat('powershell -ExecutionPolicy Unrestricted -File .\\', parameters('customScriptExtensionFile'))]"
                    }
                    }
                }
            },
            {
                "name": "[concat(parameters('vmNodeType0Name'),'_ServiceFabricNode')]",
                "properties": {
                    "provisionAfterExtensions": [
                        "CustomScriptExtension"
                    ],
                    "type": "ServiceFabricNode",

.LINK
    https://github.com/Azure/Service-Fabric-Troubleshooting-Guides
#>

param(
    [string]$dockerVersion = '0.0.0.0', # latest
    [switch]$allowUpgrade,
    [switch]$hypervIsolation,
    [switch]$installContainerD,
    [string]$mirantisInstallUrl = 'https://get.mirantis.com/install.ps1',
    [switch]$dockerCe,
    [switch]$uninstall,
    [switch]$noRestart,
    [switch]$noExceptionOnError,
    [bool]$registerEvent = $true,
    [string]$registerEventSource = 'CustomScriptExtension',
    [string]$offlineFile = "$psscriptroot/Docker.zip"
)

#$PSModuleAutoLoadingPreference = 2
#$ErrorActionPreference = 'continue'
[Net.ServicePointManager]::Expect100Continue = $true;
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;

$eventLogName = 'Application'
$dockerProcessName = 'dockerd'
$dockerServiceName = 'docker'
$transcriptLog = "$psscriptroot\transcript.log"
$defaultDockerExe = 'C:\Program Files\Docker\dockerd.exe'
$nullVersion = '0.0.0.0'
$versionMap = @{}
$mirantisRepo = 'https://repos.mirantis.com'
$dockerCeRepo = 'https://download.docker.com'
$dockerPackageAbsolutePath = 'win/static/stable/x86_64'

$global:currentDockerVersions = @{}
$global:currentContainerDVersions = @{}
$global:downloadUrl = $mirantisRepo
$global:restart = !$noRestart
$global:result = $true

function Main() {

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    if (!$isAdmin) {
        Write-Error "Restart script as administrator."
        return $false
    }
    
    Register-Event
    Start-Transcript -Path $transcriptLog
    $error.Clear()

    $installFile = "$psscriptroot\$([IO.Path]::GetFileName($mirantisInstallUrl))"
    Write-Host "Installation file:$installFile"

    if (!(Test-Path $installFile)) {
        Download-File -url $mirantisInstallUrl -outputFile $installFile
    }

    # temp fix
    Add-UseBasicParsing -ScriptFile $installFile

    $version = Set-DockerVersion -dockerVersion $dockerVersion
    $installedVersion = Get-DockerVersion

    # install windows-features
    Install-Feature -name 'containers'

    if ($hypervIsolation) {
        Install-Feature -Name 'hyper-v'
        Install-Feature -Name 'rsat-hyper-v-tools'
        Install-Feature -Name 'hyper-v-tools'
        Install-Feature -Name 'hyper-v-powershell'
    }

    if ($uninstall -and (Test-DockerIsInstalled)) {
        Write-Warning "Uninstalling docker. Uninstall:$uninstall"
        Invoke-Script -Script $installFile -Arguments "-Uninstall -verbose 6>&1"
    }
    elseif ($installedVersion -eq $version) {
        Write-Host "Docker $installedVersion already installed and is equal to $version. Skipping install."
        $global:restart = $false
    }
    elseif ($installedVersion -ge $version) {
        Write-Host "Docker $installedVersion already installed and is newer than $version. Skipping install."
        $global:restart = $false
    }
    elseif ($installedVersion -ne $nullVersion -and ($installedVersion -lt $version -and !$allowUpgrade)) {
        Write-Host "Docker $installedVersion already installed and is older than $version. allowupgrade:$allowUpgrade. skipping install."
        $global:restart = $false
    }
    else {
        $error.Clear()
        $engineOnly = $null
        if (!$installContainerD) {
            $engineOnly = "-EngineOnly "
        }

        $noServiceStarts = $null
        if ($global:restart) {
            $noServiceStarts = "-NoServiceStarts "
        }

        $global:downloadUrl = $mirantisRepo
        if ($dockerCe) {
            $global:downloadUrl = $dockerCeRepo
        }

        # download docker outside mirantis script
        $downloadFile = $global:currentDockerVersions.Item($version)

        Download-File -url "$global:downloadUrl/$dockerPackageAbsolutePath/$downloadFile" -outputFile $offlineFile

        # docker script will always emit errors checking for files even when successful
        Write-Host "Installing docker."
        $scriptResult = Invoke-Script -script $installFile `
            -arguments "-DockerVersion $($version.tostring()) -OffLine -OffLinePackagesPath $psscriptroot $engineOnly$noServiceStarts-Verbose 6>&1" `
            -checkError $false
        
        $error.Clear()
        $finalVersion = Get-DockerVersion
        if ($finalVersion -eq $nullVersion) {
            $global:result = $false
        }

        Write-Host "Install result:$($scriptResult | Format-List * | Out-String)"
        Write-Host "Global result:$global:result"
        Write-Host "Installed docker version:$finalVersion"
        Write-Host "Restarting OS:$global:restart"
    }

    Stop-Transcript
    $level = 'Information'
    if (!$global:result) {
        $level = 'Error'
    }

    $transcript = Get-Content -raw $transcriptLog
    Write-Event -data $transcript -level $level


    if ($global:result -and $global:restart) {
        # prevent sf extension from trying to install before restart
        Start-Process powershell '-c', {
            $outvar = $null;
            $mutex = [threading.mutex]::new($true, 'Global\ServiceFabricExtensionHandler.A6C37D68-0BDA-4C46-B038-E76418AFC690', [ref]$outvar);
            write-host $mutex;
            write-host $outvar;
            read-host;
        }

        # return immediately after this call
        Restart-Computer -Force
    }

    if (!$noExceptionOnError -and !$global:result) {
        throw [Exception]::new("Exception $($MyInvocation.ScriptName)`n$($transcript)")
    }
    return $global:result
}

# Adding as most Windows Server images have installed PowerShell 5.1 and without this switch Invoke-WebRequest is using Internet Explorer COM API which is causing issues with PowerShell < 6.0.
function Add-UseBasicParsing($scriptFile) {
    $newLine
    $updated = $false
    $scriptLines = [IO.File]::ReadAllLines($scriptFile)
    $newScript = [Collections.ArrayList]::new()
    Write-Host "Updating $scriptFile to use -UseBasicParsing for Invoke-WebRequest"

    foreach ($line in $scriptLines) {
        $newLine = $line
        if ([Text.RegularExpressions.Regex]::IsMatch($line, 'Invoke-WebRequest', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            Write-Host "Found command $line"
            if (![Text.RegularExpressions.Regex]::IsMatch($line, '-UseBasicParsing', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $newLine = [Text.RegularExpressions.Regex]::Replace($line, 'Invoke-WebRequest', 'Invoke-WebRequest -UseBasicParsing', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                Write-Host "Updating command $line to $newLine"
                $updated = $true
            }
        }
        [void]$newScript.Add($newLine)
    }

    if ($updated) {
        $newScriptContent = [string]::Join([Environment]::NewLine, $newScript.ToArray())
        $tempFile = "$scriptFile.oem"
        if ((Test-Path $tempFile)) {
            Remove-Item $tempFile -Force
        }
    
        Rename-Item $scriptFile -NewName $tempFile -force
        Write-Host "Saving new script $scriptFile"
        Out-File -InputObject $newScriptContent -FilePath $scriptFile -Force    
    }
}

function Download-File($url, $outputFile) {
    Write-Host "$result = [Net.WebClient]::New().DownloadFile($url, $outputFile)"
    $global:result = [Net.WebClient]::new().DownloadFile($url, $outputFile)
    Write-Host "DownloadFile result:$($result | Format-List *)"

    if ($error -or !(Test-Path $outputFile)) {
        Write-Error "failure downloading file:$($error | out-string)"
        $global:result = $false
    }
    return $global:result
}

# Get the docker version
function Get-DockerVersion() {
    $installedVersion = [version]::new($nullVersion)

    if (Test-IsDockerRunning) {
        $path = (Get-Process -Name $dockerProcessName).Path
        Write-Host "Docker installed and running: $path"
        $dockerInfo = (docker version)
        $installedVersion = [version][Text.RegularExpressions.Regex]::Match($dockerInfo, 'Version:\s+?(\d.+?)\s').Groups[1].Value
    }
    elseif (Test-DockerIsInstalled) {
        $path = Get-WmiObject win32_service | Where-Object { $psitem.Name -like $dockerServiceName } | Select-Object PathName
        Write-Host "Docker exe path:$path"
        $path = [Text.RegularExpressions.Regex]::Match($path.PathName, "`"(.+)`"").Groups[1].Value
        Write-Host "Docker exe clean path:$path"
        $installedVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
        Write-Warning "Warning: docker installed but not running: $path"
    }
    else {
        Write-Host "Docker not installed"
    }

    Write-Host "Installed docker defaultPath:$($defaultDockerExe -ieq $path) path:$path version:$installedVersion"
    return $installedVersion
}

# Get the latest docker version
function Get-LatestVersion([string[]] $versions) {
    $latestVersion = [version]::new()
    
    if (!$versions) {
        return [version]::new($nullVersion)
    }

    foreach ($version in $versions) {
        try {
            $currentVersion = [version]::new($version)
            if ($currentVersion -gt $latestVersion) {
                $latestVersion = $currentVersion
            }
        }
        catch {
            $error.Clear()
            continue
        }
    }

    return $latestVersion
}

# Install Windows-Feature if not installed
function Install-Feature([string]$name) {
    $feautureResult = $null
    $isInstalled = (Get-WindowsFeature -name $name).Installed
    Write-Host "Windows feature '$name' installed:$isInstalled"

    if (!$isInstalled) {
        Write-Host "Installing windows feature '$name'"
        $feautureResult = Install-WindowsFeature -Name $name
        if (!$feautureResult.Success) {
            Write-Error "error installing feature:$($error | out-string)"
            $global:result = $false
        }
        else {
            if (!$noRestart) {
                $global:restart = $global:restart -or $feautureResult.RestartNeeded -ieq 'yes'
                Write-Host "`$global:restart set to $global:restart"
            }
        }
    }

    return $feautureResult
}

# Invoke the MCR installer (this will require a reboot)
function Invoke-Script([string]$script, [string] $arguments, [bool]$checkError = $true) {
    Write-Host "Invoke-Expression -Command `"$script $arguments`""
    $scriptResult = Invoke-Expression -Command "$script $arguments"

    if ($checkError -and $error) {
        Write-Error "failure executing script:$script $arguments $($error | out-string)"
        $global:result = $false
    }

    return $scriptResult
}

# Set docker version parameter (script internally)
function Set-DockerVersion($dockerVersion) {
    # install.ps1 using Write-Host to output string data. have to capture with 6>&1
    # for docker ce and mirantis compat, query versions outside install.ps1

    $result = Invoke-WebRequest -Uri "$global:downloadUrl/$dockerPackageAbsolutePath" -UseBasicParsing

    $filePattern = '(?<file>(?<filetype>docker|containerd)-(?<major>\d+?)\.(?<minor>\d+?)\.(?<build>\d+?)\.zip)'
    $linkMatches = [regex]::matches($result.Links.href, $filePattern, [text.regularexpressions.regexoptions]::IgnoreCase)

    foreach ($match in $linkMatches) {
        $major = $match.groups['major'].value
        $minor = $match.groups['minor'].value
        $build = $match.groups['build'].value
        $version = [version]::new($major, $minor, $build)

        $file = $match.groups['file'].value
        $filetype = $match.groups['filetype'].value
        
        if ($filetype -ieq 'docker') {
            [void]$global:currentDockerVersions.Add($version, $file)
        }
        else {
            [void]$global:currentContainerDVersions.Add($version, $file)
        }
    }

    Write-Host "Current docker versions: $($global:currentDockerVersions | out-string)"

    $latestDockerVersion = Get-LatestVersion -versions $global:currentDockerVersions.Keys
    Write-Host "Latest docker version: $latestdockerVersion"

    #$currentContainerDVersions = @($currentVersions[1].ToString().TrimStart('containerd:').Replace(" ", "").Split(","))
    Write-Host "Current containerd versions: $($currentContainerDVersions | out-string)"

    if ($dockerVersion -ieq 'latest' -or $allowUpgrade) {
        Write-Host "Setting version to latest"
        $version = $latestDockerVersion
    }
    else {
        try {
            $version = [version]::new($dockerVersion)
            Write-Host "Setting version to `$dockerVersion ($dockerVersion)"
        }
        catch {
            $version = [version]::new($nullVersion)
            Write-Warning "Exception setting version to `$dockerVersion ($dockerVersion)`r`n$($error | Out-String)"
        }
    
        if ($version -ieq [version]::new($nullVersion)) {
            $version = $latestdockerVersion
            Write-Host "Setting version to latest docker version $latestdockerVersion"
        }
    }

    Write-Host "Returning target install version: $version"
    return $version
}

# Validate if docker is installed
function Test-DockerIsInstalled() {
    $retval = $false

    if ((Get-Service -name $dockerServiceName -ErrorAction SilentlyContinue)) {
        $retval = $true
    }
    
    $error.Clear()
    Write-Host "Docker installed:$retval"
    return $retval
}

# Check if docker is already running
function Test-IsDockerRunning() {
    $retval = $false
    if (Get-Process -Name $dockerProcessName -ErrorAction SilentlyContinue) {
        if (Invoke-Expression 'Docker version') {
            $retval = $true
        }
    }
    
    Write-Host "Docker running:$retval"
    return $retval
}

# Register Windows event source 
function Register-Event() {
    if ($registerEvent) {
        $error.clear()
        New-EventLog -LogName $eventLogName -Source $registerEventSource -ErrorAction silentlycontinue
        if ($error -and ($error -inotmatch 'source is already registered')) {
            $registerEvent = $false
        }
        else {
            $error.clear()
        }
    }
}

# Trace event
function Write-Event($data, $level = 'Information') {
    Write-Host $data

    if ($error -or $level -ieq 'Error') {
        $level = 'Error'
        $data = "$data`r`nErrors:`r`n$($error | Out-String)"
        Write-Error $data
        $error.Clear()
    }

    try {
        if ($registerEvent) {
            Write-EventLog -LogName $eventLogName -Source $registerEventSource -Message $data -EventId 1000 -EntryType $level
        }
    }
    catch {
        Write-Host "exception writing event to event log:$($error | out-string)"
        $error.Clear()
    }
}

Main