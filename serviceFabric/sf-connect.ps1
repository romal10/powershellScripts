<#
.SYNOPSIS
    powershell script to connect to existing service fabric cluster with connect-servicefabriccluster cmdlet

.LINK
    [net.servicePointManager]::Expect100Continue = $true;[net.servicePointManager]::SecurityProtocol = [net.SecurityProtocolType]::Tls12;
    invoke-webRequest "https://raw.githubusercontent.com/jagilber/powershellScripts/master/serviceFabric/sf-connect.ps1" -outFile "$pwd/sf-connect.ps1";
    ./sf-connect.ps1 -clusterEndpoint <cluster endpoint fqdn> -thumbprint <thumbprint>
#>
using namespace System.Net;
using namespace System.Net.Sockets;
using namespace System.Net.Security;
using namespace System.Security.Cryptography.X509Certificates;

[cmdletbinding()]
param(
    $clusterendpoint = "cluster.location.cloudapp.azure.com", #"10.0.0.4:19000",
    $thumbprint,
    $subjectName,
    $resourceGroup,
    $clustername = $resourceGroup,
    [ValidateSet('LocalMachine', 'CurrentUser')]
    $storeLocation = "CurrentUser",
    $clusterendpointPort = 19000,
    $clusterExplorerPort = 19080
)

# proxy test
#$proxyString = "http://127.0.0.1:5555"
#$proxyUri = new-object System.Uri($proxyString)
#[Net.WebRequest]::DefaultWebProxy = new-object System.Net.WebProxy ($proxyUri, $true)
#$proxy = [System.Net.CredentialCache]::DefaultCredentials
#[System.Net.WebRequest]::DefaultWebProxy.Credentials = $proxy

#Add-azAccount
$PSModuleAutoLoadingPreference = 2
$ErrorActionPreference = 'continue'
[net.servicePointManager]::Expect100Continue = $true;
[net.servicePointManager]::SecurityProtocol = [net.SecurityProtocolType]::Tls12;

function main() {
    set-callback
    $error.Clear()
    if (!(get-command Connect-ServiceFabricCluster)) {
        import-module servicefabric
        if (!(get-command Connect-ServiceFabricCluster)) {
            write-error "unable to import servicefabric powershell module. try executing script from a working node."
            return
        }
    }

    $publicIp = (Invoke-RestMethod https://ipinfo.io/json).ip
    write-host "current public ip:$publicIp" -ForegroundColor Green

    $managementEndpoint = $clusterEndpoint
    $currentVerbose = $VerbosePreference
    $currentDebug = $DebugPreference
    $VerbosePreference = "continue"
    $DebugPreference = "continue"
    $global:ClusterConnection = $null

    if ($resourceGroup -and $clustername) {
        $cluster = Get-azServiceFabricCluster -ResourceGroupName $resourceGroup -Name $clustername
        $managementEndpoint = $cluster.ManagementEndpoint
        $thumbprint = $cluster.Certificate.Thumbprint
        $global:cluster | ConvertTo-Json -Depth 99
    }

    if ($managementEndpoint -inotmatch ':\d{2,5}$') {
        $managementEndpoint = "$($managementEndpoint):$($clusterEndpointPort)"
    }

    $managementEndpoint = $managementEndpoint.Replace("19080", "19000").Replace("https://", "")
    $clusterFqdn = [regex]::match($managementEndpoint, "(?:http.//|^)(.+?)(?:\:|$|/)").Groups[1].Value

    $VerbosePreference = "silentlycontinue"
    $DebugPreference = "silentlycontinue"
    
    $result = Test-NetConnection -ComputerName $clusterFqdn -Port $clusterendpointPort
    write-host ($result | out-string)

    if ($result.tcpTestSucceeded) {
        write-host "able to connect to $($clusterFqdn):$($clusterEndpointPort)" -ForegroundColor Green
        get-certValidationTcp -url $clusterFqdn -port $clusterEndpointPort
    }
    else {
        write-error "unable to connect to $($clusterFqdn):$($clusterEndpointPort)"
    }

    $result = Test-NetConnection -ComputerName $clusterFqdn -Port $clusterExplorerPort
    write-host ($result | out-string)

    $VerbosePreference = "continue"
    $DebugPreference = "continue"

    if ($result.tcpTestSucceeded) {
        write-host "able to connect to $($clusterFqdn):$($clusterExplorerPort)" -ForegroundColor Green
    #    get-certValidationHttp -url "https://$($clusterFqdn):$($clusterExplorerPort)/Explorer/index.html#/"
    }
    else {
        write-error "unable to connect to $($clusterFqdn):$($clusterExplorerPort)"
    }

    write-host "Connect-ServiceFabricCluster -ConnectionEndpoint $managementEndpoint `
        -ServerCertThumbprint $thumbprint `
        -StoreLocation $storeLocation `
        -X509Credential `
        -FindType FindByThumbprint `
        -FindValue $thumbprint `
        -verbose" -ForegroundColor Green

    # this sets wellknown local variable $ClusterConnection
    Connect-ServiceFabricCluster `
        -ConnectionEndpoint $managementEndpoint `
        -ServerCertThumbprint $thumbprint `
        -StoreLocation $storeLocation `
        -X509Credential `
        -FindType FindByThumbprint `
        -FindValue $thumbprint `
        -Verbose


    write-host "Get-ServiceFabricClusterConnection" -ForegroundColor Green

    write-host "============================" -ForegroundColor Green
    Get-ServiceFabricClusterConnection
    $DebugPreference = "silentlycontinue"

    # set global so commands can be run outside of script
    $global:ClusterConnection = $ClusterConnection
    $currentVerbose = $VerbosePreference
    $currentDebug = $DebugPreference
    $VerbosePreference = $currentVerbose
    $DebugPreference = $currentDebug
}

function get-certValidationHttp([string] $url) {
    write-host "get-certValidationHttp:$($url) $($certFile)" -ForegroundColor Green
    $error.Clear()
    $webRequest = [Net.WebRequest]::Create($url)
    $webRequest.ServerCertificateValidationCallback = [net.servicePointManager]::ServerCertificateValidationCallback
    $webRequest.Timeout = 1000 #ms

    try { 
        [void]$webRequest.GetResponse() 
        # return $null
    }
    catch [System.Exception] {
        Write-Verbose "get-certValidationHttp:first catch getresponse: $($url) $($certFile) $($error | Format-List * | out-string)`r`n$($_.Exception|Format-List *)" 
        $error.Clear()
    }
}

function get-certValidationTcp([string] $url, [int]  $port) {
    #$ipAddress = [dns]::resolve($url).AddressList[0]
    write-host "get-certValidationTcp:$ipAddress $url $certFile" -ForegroundColor Green
    $error.Clear()
    $tcpClient = [Net.Sockets.TcpClient]::new($url, $port)
    #  $sslStream = [sslstream]::new($tcpClient.GetStream(),`
    #      $false,`
    #      [net.servicePointManager]::ServerCertificateValidationCallback,`
    #      $null)
    #  $sslStream = [sslstream]::new($tcpClient.GetStream(),`
    #      $false,`
    #      [System.Net.Security.RemoteCertificateValidationCallback]($global:securityCallback.ValidationCallback),`
    #      [System.Net.Security.LocalCertificateSelectionCallback]($global:securityCallback.LocalCallback))
    $sslStream = [sslstream]::new($tcpClient.GetStream(), $false)
    #$sslStream = [sslstream]::new($tcpClient.GetStream(),$false, [net.servicePointManager]::ServerCertificateValidationCallback)
    # $webRequest.ServerCertificateValidationCallback = [net.servicePointManager]::ServerCertificateValidationCallback
    # $webRequest.Timeout = 1000 #ms
    #$sslStream.AuthenticateAsClient($url)
    #$sslStream.AuthenticateAsClient('sfjagilber')
    try { 
        $sslAuthenticationOptions = [SslClientAuthenticationOptions]::new()
        $sslAuthenticationOptions.AllowRenegotiation = $true
        $sslAuthenticationOptions.CertificateRevocationCheckMode = 0
        $sslAuthenticationOptions.EncryptionPolicy = 1
        $sslAuthenticationOptions.EnabledSslProtocols = 3072 # tls 1.2 #(3072 -bor 12288)
        #$sslAuthenticationOptions.ClientCertificates = [System.Security.Cryptography.X509Certificates.X509CertificateCollection]::new((get-clientCert $thumbprint $storeLocation))
        $sslAuthenticationOptions.ClientCertificates = [System.Security.Cryptography.X509Certificates.X509CertificateCollection]::new((get-clientCert $thumbprint $storeLocation))
        $sslAuthenticationOptions.LocalCertificateSelectionCallback = [System.Net.Security.LocalCertificateSelectionCallback]($global:securityCallback.LocalCallback)
        $sslAuthenticationOptions.RemoteCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]($global:securityCallback.ValidationCallback)
        $sslAuthenticationOptions.TargetHost = $subjectName
        # $sslAuthenticationOptions.
        ## todo: not working
        # https://docs.microsoft.com/en-us/dotnet/api/system.net.security.sslstream.authenticateasclient?view=net-5.0
        write-host "sslAuthenticationOptions:$($sslAuthenticationOptions | convertto-json)" -ForegroundColor Cyan
        $sslStream.AuthenticateAsClient($sslAuthenticationOptions)

        #$sslStream.AuthenticateAsClient('sfjagilber') #($url)
        # [void]$webRequest.GetResponse() 
        # return $null
    }
    catch [System.Exception] {
        Write-Host "get-certValidationTcp:first catch getresponse: $url $($error | Format-List * | out-string)`r`n$($_.Exception|Format-List *)" 
        #$error.Clear()
    }
}

function get-clientCert($thumbprint, $storeLocation) {
    $pscerts = @(Get-ChildItem -Path Cert:\$storeLocation\My -Recurse | Where-Object Thumbprint -eq $thumbprint)
    #[System.Security.Cryptography.X509Certificates.X509Certificate[]]$certArr = @(0) * $pscerts.length
    #$certArr = @(0) * $pscerts.length
    #for($i = 0;$i -lt $pscerts.length;$i++){
    #    $certArr[$i] = [System.Security.Cryptography.X509Certificates.X509Certificate]::new($pscerts[$i])
    #}
    [collections.generic.list[System.Security.Cryptography.X509Certificates.X509Certificate]] $certCol = [collections.generic.list[System.Security.Cryptography.X509Certificates.X509Certificate]]::new()
    foreach ($cert in $pscerts) {
        [void]$certCol.Add([System.Security.Cryptography.X509Certificates.X509Certificate]::new($cert))
    }
    #return $pscerts # $certCol.ToArray()
    return $certCol.ToArray()
}

function set-callback() {
    if ($PSVersionTable.PSEdition -ieq 'core') {
        class SecurityCallback {
            [bool] ValidationCallback(
                [object]$senderObject, 
                [System.Security.Cryptography.X509Certificates.X509Certificate]$cert, 
                [System.Security.Cryptography.X509Certificates.X509Chain]$chain, 
                [System.Net.Security.SslPolicyErrors]$policyErrors
            ) {
                write-host "validation callback:sender:$($senderObject | out-string)" -ForegroundColor Cyan
                write-verbose "validation callback:sender:$($senderObject | convertto-json)"
        
                write-host "validation callback:cert:$($cert | Format-List * |out-string)" -ForegroundColor Cyan
                write-verbose  "validation callback:cert:$($cert | convertto-json)"
        
                write-host "validation callback:chain:$($chain | Format-List * |out-string)" -ForegroundColor Cyan
                write-verbose  "validation callback:chain:$($chain | convertto-json)"
        
                write-host "validation callback:errors:$($policyErrors | out-string)" -ForegroundColor Cyan
                write-verbose  "validation callback:errors:$($policyErrors | convertto-json)"
                return $true
            }
            [System.Security.Cryptography.X509Certificates.X509Certificate] LocalCallback(
                [object]$senderObject, 
                [string]$targetHost,
                [System.Security.Cryptography.X509Certificates.X509CertificateCollection]$certCol, 
                [System.Security.Cryptography.X509Certificates.X509Certificate]$remoteCert, 
                [string[]]$issuers
            ) {
                write-host "validation callback:sender:$($senderObject | out-string)" -ForegroundColor Cyan
                write-verbose "validation callback:sender:$($senderObject | convertto-json)"
        
                write-host "validation callback:targethost:$($targetHost | out-string)" -ForegroundColor Cyan
                write-verbose "validation callback:targethost:$($targetHost | convertto-json)"

                write-host "validation callback:certCol:$($certCol | Format-List * |out-string)" -ForegroundColor Cyan
                write-verbose  "validation callback:certCol:$($certCol | convertto-json)"
        
                write-host "validation callback:remotecert:$($remoteCert | Format-List * |out-string)" -ForegroundColor Cyan
                write-verbose  "validation callback:remotecert:$($remoteCert | convertto-json)"
        
                write-host "validation callback:issuers:$($issuers | out-string)" -ForegroundColor Cyan
                write-verbose  "validation callback:issuers:$($issuers | convertto-json)"
                return $remoteCert
            }
        }

        [SecurityCallback]$global:securityCallback = [SecurityCallback]::new()
        [net.servicePointManager]::ServerCertificateValidationCallback = [System.Net.Security.RemoteCertificateValidationCallback]($global:securityCallback.ValidationCallback)
    }
    else {
        add-type @"
        using System;
        using System.Net;
        using System.Security.Cryptography.X509Certificates;

        public class IDontCarePolicy : ICertificatePolicy {
                public IDontCarePolicy() {}
                public bool CheckValidationResult(ServicePoint sPoint, X509Certificate cert, WebRequest wRequest, int certProb) {
                Console.WriteLine(cert);
                Console.WriteLine(cert.Issuer);
                Console.WriteLine(cert.Subject);
                Console.WriteLine(cert.GetCertHashString());
                return true;
            }
        }
"@
        [System.Net.ServicePointManager]::CertificatePolicy = new-object IDontCarePolicy 
    }
}

main