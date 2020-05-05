param(
    [Parameter(Mandatory = $true)]
    [string] $StorageSinkContainer
)

<# 
Scripts provided are not supported under any Microsoft standard support program or service. 
The scripts are provided AS IS without warranty of any kind. Microsoft disclaims all implied warranties including, 
without limitation, any implied warranties of merchantability or of fitness for a particular purpose. The entire 
risk arising out of the use or performance of the scripts and documentation remains with you. In no event shall Microsoft, 
its authors, or anyone else involved in the creation, production, or delivery of the scripts be liable for any damages 
whatsoever (including, without limitation, damages for loss of business profits, business interruption, loss of business 
information, or other pecuniary loss) arising out of the use of or inability to use the scripts or documentation, even 
if Microsoft has been advised of the possibility of such damages.
#>

$ErrorActionPreference = "Stop"

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization-CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name "AzureOptimization-AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity|User
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}
else {
    if ($authenticationOption -eq "User")
    {
        $authenticationCredential = Get-AutomationVariable -Name  "AzureOptimization-AuthenticationCredential"
    }
}
$sqlserver = Get-AutomationVariable -Name  "AzureOptimization-SQLServerHostname"
$sqlserverCredential = Get-AutomationPSCredential -Name "AzureOptimization-SQLServerCredential"
$SqlUsername = $sqlserverCredential.UserName 
$SqlPass = $sqlserverCredential.GetNetworkCredential().Password 
$sqldatabase = Get-AutomationVariable -Name  "AzureOptimization-SQLServerDatabase" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($sqldatabase))
{
    $sqldatabase = "azureoptimization"
}
$workspaceId = Get-AutomationVariable -Name  "AzureOptimization-LogAnalyticsWorkspaceId"
$sharedKey = Get-AutomationVariable -Name  "AzureOptimization-LogAnalyticsWorkspaceKey"
$LogAnalyticsChunkSize = Get-AutomationVariable -Name  "AzureOptimization-LogAnalyticsChunkSize" -ErrorAction SilentlyContinue
if (-not($LogAnalyticsChunkSize -gt 0))
{
    $LogAnalyticsChunkSize = 10000
}
$lognamePrefix = Get-AutomationVariable -Name  "AzureOptimization-LogAnalyticsLogPrefix" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($lognamePrefix))
{
    $lognamePrefix = "AzureOptimization_"
}
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization-StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization-StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization-StorageSinkSubId"
$storageAccountSinkContainer = $StorageSinkContainer
$StorageBlobsChunkSize = Get-AutomationVariable -Name  "AzureOptimization-StorageBlobsChunkSize" -ErrorAction SilentlyContinue
if (-not($StorageBlobsChunkSize -gt 0))
{
    $StorageBlobsChunkSize = 1000
}

$Timestampfield = "Timestamp" 
$LogAnalyticsIngestControlTable = "LogAnalyticsIngestControl"

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity
        break
    }
    "User" { 
        $cred = Get-AutomationPSCredential –Name $authenticationCredential
	    Connect-AzAccount -Credential $cred
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

#region Functions

# Function to create the authorization signature
Function Build-OMSSignature ($workspaceId, $sharedKey, $date, $contentLength, $method, $contentType, $resource) {
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $workspaceId, $encodedHash
    return $authorization
}

# Function to create and post the request
Function Post-OMSData($workspaceId, $sharedKey, $body, $logType) {
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-OMSSignature `
        -workspaceId $workspaceId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -fileName $fileName `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $workspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $OMSheaders = @{
        "Authorization"        = $signature;
        "Log-Type"             = $logType;
        "x-ms-date"            = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    Try {

        $response = Invoke-WebRequest -Uri $uri -Method POST  -ContentType $contentType -Headers $OMSheaders -Body $body -UseBasicParsing -TimeoutSec 1000
    }
    catch {
        $_.Message
        if ($_.Exception.Response.StatusCode.Value__ -eq 401) {            
            "REAUTHENTICATING"

            $response = Invoke-WebRequest -Uri $uri -Method POST  -ContentType $contentType -Headers $OMSheaders -Body $body -UseBasicParsing -TimeoutSec 1000
        }
    }

    write-output $response.StatusCode
    return $response.StatusCode
    
}
#endregion Functions



# get reference to storage sink
Write-Output "Getting blobs list from $storageAccountSink storage account ($storageAccountSinkContainer container)..."
Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

$allblobs = @()

$continuationToken = $null
do
{
    $blobs = Get-AzStorageBlob -Container $storageAccountSinkContainer -MaxCount $StorageBlobsChunkSize -ContinuationToken $continuationToken -Context $sa.Context | Sort-Object -Property LastModified
    if ($blobs.Count -le 0) { break }
    $allblobs += $blobs
    $continuationToken = $blobs[$blobs.Count -1].ContinuationToken;
}
While ($null -ne $continuationToken)

$newProcessedTime = $null

foreach ($blob in $allblobs) {

    $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;User ID=$SqlUsername;Password=$SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=30;") 
    $Conn.Open() 
    $Cmd=new-object system.Data.SqlClient.SqlCommand
    $Cmd.Connection = $Conn
    $Cmd.CommandTimeout=120 
    $Cmd.CommandText = "SELECT * FROM [dbo].[$LogAnalyticsIngestControlTable] WHERE StorageContainerName = '$storageAccountSinkContainer'"

    $sqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
    $sqlAdapter.SelectCommand = $Cmd
    $controlRows = New-Object System.Data.DataTable
    $sqlAdapter.Fill($controlRows)
    $controlRow = $controlRows[0]

    $lastProcessedLine = $controlRow.LastProcessedLine
    $lastProcessedDateTime = $controlRow.LastProcessedDateTime.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
    $newProcessedTime = $blob.LastModified.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'")
    if ($lastProcessedDateTime -lt $newProcessedTime) {
        Write-Output "About to process $($blob.Name)..."
        Get-AzStorageBlobContent -CloudBlob $blob.ICloudBlob -Context $sa.Context -Force
        $csvObject = Import-Csv $blob.Name

        $logname = $lognamePrefix + $controlRow.LogAnalyticsSuffix
        $linesProcessed = 0
        $csvObjectSplitted = @()
        for ($i = 0; $i -lt $csvObject.count; $i += $LogAnalyticsChunkSize) {
            $csvObjectSplitted += , @($csvObject[$i..($i + ($LogAnalyticsChunkSize - 1))]);
        }
        for ($i = 0; $i -lt $csvObjectSplitted.Count; $i++) {
            $currentObjectLines = $csvObjectSplitted[$i].Count
            if ($lastProcessedLine -lt $linesProcessed) {				
			    $jsonObject = ConvertTo-Json -InputObject $csvObjectSplitted[$i]                
                $res = Post-OMSData -workspaceId $workspaceId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonObject)) -logType $logname
                If ($res -ge 200 -and $res -lt 300) {
                    Write-Output "Succesfully uploaded $currentObjectLines $($controlTable.LogAnalyticsSuffix) rows to Log Analytics"    
                    $linesProcessed += $currentObjectLines
                    if ($i -eq ($csvObjectSplitted.Count - 1)) {
                        $lastProcessedLine = -1    
                    }
                    else {
                        $lastProcessedLine = $linesProcessed - 1   
                    }
                    
                    $updatedLastProcessedLine = $lastProcessedLine
                    $updatedLastProcessedDateTime = $lastProcessedDateTime
                    if ($i -eq ($csvObjectSplitted.Count - 1)) {
                        $updatedLastProcessedDateTime = $newProcessedTime
                    }
                    Write-Output "Updating last processed time / line to $($updatedLastProcessedDateTime) / $updatedLastProcessedLine"
                    $sqlStatement = "UPDATE [$LogAnalyticsIngestControlTable] SET LastProcessedLine = $updatedLastProcessedLine, LastProcessedDateTime = '$updatedLastProcessedDateTime' WHERE StorageContainerName = '$storageAccountSinkContainer'"
                    $Cmd=new-object system.Data.SqlClient.SqlCommand
                    $Cmd.Connection = $Conn
                    $Cmd.CommandText = $sqlStatement
                    $Cmd.CommandTimeout=120 
                    $Cmd.ExecuteReader()
                }
                Else {
                    $linesProcessed += $currentObjectLines
                    Write-Warning "Failed to upload $currentObjectLines $($controlTable.LogAnalyticsSuffix) rows"
                    throw
                }
            }
            else {
                $linesProcessed += $currentObjectLines  
            }            
        }
    }
    $Conn.Close()    
    $Conn.Dispose()            
}