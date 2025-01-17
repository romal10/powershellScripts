<#
.SYNOPSIS
    example script to install docker on virtual machine scaleset using custom script extension
    use custom script extension in ARM template
    save script file to url that vmss nodes have access to during provisioning
    
.NOTES
v 1.0.3

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


parameters.json :
{
  "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "customScriptExtensionFile": {
      "value": "install-mirantis.ps1"
      //"value": "install-mirantis.ps1 -hypervIsolation"
      //"value": "install-mirantis.ps1 -dockerVersion 18.09.12 -installContainerD"
      //"value": "install-mirantis.ps1 -dockerVersion 18.09.12 -allowUpgrade"
    },
    "customScriptExtensionFileUri": {
      "value": "https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/install-mirantis.ps1"
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

.PARAMETER dockerVersion
[string] Version of docker to install. Default will be to install latest version.
Format '0.0.0.'

.PARAMETER allowUpgrade
[switch] Allow upgrade of docker. Default is to not upgrade version of docker.

.PARAMETER hypervIsolation
[switch] Install hyper-v feature / components. Default is to not install hyper-v feature.
Mirantis install will install container feature.

.PARAMETER installContainerD
[switch] Install containerd. Default is  to not install containerd.
containerd is not needed for docker functionality.

.PARAMETER mirantisInstallUrl
[string] Mirantis installation script url. Default is 'https://get.mirantis.com/install.ps1'

.PARAMETER uninstall
[switch] Uninstall docker only. This will not uninstall containerd or hyper-v feature. 

.PARAMETER norestart
[switch] No restart after installation of docker and container feature. By default, after installation, node is restarted.
Use of -norestart is not supported.

.PARAMETER registerEvent
[bool] If true, will write installation summary information to the Application event log. Default is true.

.PARAMETER registerEventSource
[string] Register event source name used to write installation summary information to the Application event log.. Default name is 'CustomScriptExtension'.

.LINK
    [net.servicePointManager]::Expect100Continue = $true;[net.servicePointManager]::SecurityProtocol = [net.securityProtocolType]::Tls12;
    invoke-webRequest "https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/install-mirantis.ps1" -outFile "$pwd\install-mirantis.ps1";
#>

param(
    [string]$dockerVersion = '0.0.0.0', # latest
    [switch]$allowUpgrade,
    [switch]$hypervIsolation,
    [switch]$installContainerD,
    [string]$mirantisInstallUrl = 'https://get.mirantis.com/install.ps1',
    [switch]$uninstall,
    [switch]$norestart,
    [bool]$registerEvent = $true,
    [string]$registerEventSource = 'CustomScriptExtension'
)

$PSModuleAutoLoadingPreference = 2
$ErrorActionPreference = 'continue'
[net.servicePointManager]::Expect100Continue = $true;
[net.servicePointManager]::SecurityProtocol = [net.SecurityProtocolType]::Tls12;

$eventLogName = 'Application'
$dockerProcessName = 'dockerd'
$dockerServiceName = 'docker'
$transcriptLog = "$psscriptroot\transcript.log"
$defaultDockerExe = 'C:\Program Files\Docker\dockerd.exe'
$nullVersion = '0.0.0.0'
$versionMap = @{}

function main() {

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    if (!$isAdmin) {
        Write-Error "restart script as administrator"
        return
    }
    
    register-event
    start-transcript -Path $transcriptLog
    $error.Clear()

    $installFile = "$psscriptroot\$([io.path]::GetFileName($mirantisInstallUrl))"
    write-host "installation file:$installFile"

    if (!(test-path $installFile)) {
        "Downloading [$url]`nSaving at [$installFile]" 
        write-host "$result = [net.webclient]::new().DownloadFile($mirantisInstallUrl, $installFile)"
        $result = [net.webclient]::new().DownloadFile($mirantisInstallUrl, $installFile)
        write-host "downloadFile result:$($result | Format-List *)"
    }

    # temp fix
    add-UseBasicParsing -scriptFile $installFile

    $version = set-dockerVersion -dockerVersion $dockerVersion
    $installedVersion = get-dockerVersion

    if ($hypervIsolation) {
        $hypervInstalled = (get-windowsFeature -name hyper-v).Installed
        write-host "hyper-v feature installed:$hypervInstalled"
        
        if (!$uninstall -and !$hypervInstalled) {
            write-host "installing hyper-v features"
            install-windowsfeature -name hyper-v
            install-windowsfeature -name rsat-hyper-v-tools
            install-windowsfeature -name hyper-v-tools
            install-windowsfeature -name hyper-v-powershell
        }
        #elseif($uninstall -and $hypervInstalled) {
        #    remove-windowsfeature -name hyper-v
        #}
    }

    if ($uninstall -and (confirm-dockerInstalled)) {
        write-warning "uninstalling docker. uninstall:$uninstall"
        $result = start-script -script $installFile -arguments "-Uninstall -verbose 6>&1"
    }
    elseif ($installedVersion -eq $version) {
        write-host "docker $installedVersion already installed and is equal to $version. skipping install."
        $norestart = $true
    }
    elseif ($installedVersion -ge $version) {
        write-host "docker $installedVersion already installed and is newer than $version. skipping install."
        $norestart = $true
    }
    elseif ($installedVersion -ne $nullVersion -and ($installedVersion -lt $version -and !$allowUpgrade)) {
        write-host "docker $installedVersion already installed and is older than $version. allowupgrade:$allowUpgrade. skipping install."
        $norestart = $true
    }
    else {
        $engineOnly = $null
        if (!$installContainerD) {
            $engineOnly = "-EngineOnly "
        }
    
        write-host "installing docker."
        $result = start-script -script $installFile -arguments "-DockerVersion $($versionMap.($version.tostring())) $engineOnly-verbose 6>&1"

        write-host "install result:$($result | Format-List * | out-string)"
        write-host "installed docker version:$(get-dockerVersion)"
        write-host "restarting OS:$(!$norestart)"
    }

    stop-transcript
    write-event (get-content -raw $transcriptLog)

    if (!$norestart) {
        restart-computer -Force
    }

    return $result
}

function add-UseBasicParsing($scriptFile) {
    $newLine
    $updated = $false
    $scriptLines = [io.file]::ReadAllLines($scriptFile)
    $newScript = [collections.arraylist]::new()
    write-host "updating $scriptFile to use -UseBasicParsing for Invoke-WebRequest"

    foreach ($line in $scriptLines) {
        $newLine = $line
        if ([regex]::IsMatch($line, 'Invoke-WebRequest', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            write-host "found command $line"
            if (![regex]::IsMatch($line, '-UseBasicParsing', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $newLine = [regex]::Replace($line, 'Invoke-WebRequest', 'Invoke-WebRequest -UseBasicParsing', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                write-host "updating command $line to $newLine"
                $updated = $true
            }
        }
        [void]$newScript.Add($newLine)
    }

    if ($updated) {
        $newScriptContent = [string]::Join([Environment]::NewLine, $newScript.ToArray())
        $tempFile = "$scriptFile.oem"
        if ((test-path $tempFile)) {
            remove-item $tempFile -Force
        }
    
        rename-item $scriptFile -NewName $tempFile -force
        write-host "saving new script $scriptFile"
        out-file -InputObject $newScriptContent -FilePath $scriptFile -Force    
    }
}

function confirm-dockerInstalled() {
    $retval = $false

    if ((get-service -name $dockerServiceName -ErrorAction SilentlyContinue)) {
        $retval = $true
    }
    
    $error.clear()
    write-host "docker installed:$retval"
    return $retval
}

function confirm-dockerRunning() {
    $retval = $false
    if (get-process -Name $dockerProcessName -ErrorAction SilentlyContinue) {
        if (invoke-expression 'docker version') {
            $retval = $true
        }
    }
    
    write-host "docker running:$retval"
    return $retval
}

function get-dockerVersion() {
    if (confirm-dockerRunning) {
        $path = (Get-Process -Name $dockerProcessName).Path
        write-host "docker installed and running: $path"
        $dockerInfo = (docker version)
        $installedVersion = [version][regex]::match($dockerInfo, 'Version:\s+?(\d.+?)\s').groups[1].value
    }
    elseif (confirm-dockerInstalled) {
        $path = Get-WmiObject win32_service | Where-Object { $psitem.Name -like $dockerServiceName } | select-object PathName
        write-host "docker exe path:$path"
        $path = [regex]::match($path.PathName, "`"(.+)`"").Groups[1].Value
        write-host "docker exe clean path:$path"
        $installedVersion = [diagnostics.fileVersionInfo]::GetVersionInfo($path)
        Write-Warning "warning:docker installed but not running: $path"
    }
    else {
        write-host "docker not installed"
        $installedVersion = [version]::new($nullVersion)
    }

    write-host "installed docker defaultPath:$($defaultDockerExe -ieq $path) path:$path version:$installedVersion"
    return $installedVersion
}

function get-latestVersion([string[]] $versions) {
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

function register-event() {
    if ($registerEvent) {
        $error.clear()
        New-EventLog -LogName $eventLogName -Source $registerEventSource -ErrorAction silentlycontinue
        if($error -and ($error -inotmatch 'source is already registered')) {
            $registerEvent = $false
        }
        else {
            $error.clear()
        }
    }
}

function set-dockerVersion($dockerVersion) {
    # install.ps1 using write-host to output string data. have to capture with 6>&1
    $currentVersions = start-script -script $installFile -arguments '-showVersions 6>&1'
    write-host "current versions: $currentVersions"
    
    $version = [version]::new($nullVersion)
    $currentDockerVersions = @($currentVersions[0].ToString().TrimStart('docker:').Replace(" ", "").Split(","))
    
    # map string to [version] for 0's
    foreach ($stringVersion in $currentDockerVersions) {
        [void]$versionMap.Add([version]::new($stringVersion).ToString(), $stringVersion)
    }
    
    write-host "version map:`r`n$($versionMap | out-string)"
    write-host "current docker versions: $currentDockerVersions"
    
    $latestDockerVersion = get-latestVersion -versions $currentDockerVersions
    write-host "latest docker version: $latestDockerVersion"
    
    $currentContainerDVersions = @($currentVersions[1].ToString().TrimStart('containerd:').Replace(" ", "").Split(","))
    write-host "current containerd versions: $currentContainerDVersions"

    if ($dockerVersion -ieq 'latest' -or $allowUpgrade) {
        write-host "setting version to latest"
        $version = $latestDockerVersion
    }
    else {
        try {
            $version = [version]::new($dockerVersion)
            write-host "setting version to `$dockerVersion ($dockerVersion)"
        }
        catch {
            $version = [version]::new($nullVersion)
            write-warning "exception setting version to `$dockerVersion ($dockerVersion)`r`n$($error | out-string)"
        }
    
        if ($version -ieq [version]::new($nullVersion)) {
            $version = $latestDockerVersion
            write-host "setting version to latest docker version $latestDockerVersion"
        }
    }

    write-host "returning target install version: $version"
    return $version
}

function start-script([string]$script, [string] $arguments) {
    write-host "Invoke-Expression -Command `"$script $arguments`""
    return Invoke-Expression -Command "$script $arguments"
}

function write-event($data) {
    write-host $data
    try {
        if ($registerEvent) {
            $level = 'Information'

            if ($error -or ($data -imatch "fail|exception|error")) {
                $level = 'Error'
                $data = "$data`r`nerrors:`r`n$($error | out-string)"
            }

            Write-EventLog -LogName $eventLogName -Source $registerEventSource -Message $data -EventId 1000 -EntryType $level
        }
    }
    catch {
        $error.Clear()
    }
}

main
