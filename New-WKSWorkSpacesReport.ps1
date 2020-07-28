<#
 * Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
 * SPDX-License-Identifier: MIT-0
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of this
 * software and associated documentation files (the "Software"), to deal in the Software
 * without restriction, including without limitation the rights to use, copy, modify,
 * merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 #>



# Prompting for a path to store logs with a default path provided and normalizes path with trailing \ if not present
$defaultreportpath = "C:\temp\"
if (!($reportpath = Read-Host "Path to store WorkSpaces creation log output: [$defaultreportpath]")) { $reportpath = $defaultreportpath }
if($reportpath -notmatch '\\$') {$reportpath = $reportpath + "\"}
If(!(test-path $reportpath)){$createfolder = New-Item -ItemType Directory -Path $reportpath}

# Define / list the regions that WorkSpaces are supported in
$WorkSpacesRegions = "us-east-1", `
"us-west-2",`
"ap-northeast-2",`
"ap-southeast-1",`
"ap-southeast-2",`
"ap-northeast-1",`
"ca-central-1",`
"eu-central-1",`
"eu-west-1",`
"eu-west-2",`
"sa-east-1"

Do {
    Write-Host "`n`n`nHere are the WorkSpaces supported regions:"
    $WorkSpacesRegions | sort
    $Region = Read-Host -Prompt 'Type the region identifier to use for provisioning'
    }
    While (-not ($WorkSpacesRegions | Where-Object {$_ -eq $Region}))
Write-host "Region" $Region "selected."    


#---------------------------------------------------------------------------------------------
# Prompting for number of days to set as a bar to determine inactivity
$defaultinactivedays = 60
Do {
    [regex] $daysregex = "^\d{1,3}$"
    if (!($inactivedays = Read-Host "Number of days used to determine inactive WorkSpaces (maximum 999): [$defaultinactivedays]")) { $inactivedays = $defaultinactivedays }
    } while ($inactivedays -inotmatch $daysregex)

    
# Convert captured data to integer
$inactivedays = [int]$inactivedays

if($inactivedays -ge 455) {"CloudWatch aggregates log data so you may need to modify the period queried per this link`
https://aws.amazon.com/about-aws/whats-new/2016/11/cloudwatch-extends-metrics-retention-and-new-user-interface/"}

$StartDate = (Get-Date).AddDays(-$inactivedays)
$EndDate = Get-Date


#---------------------------------------------------------------------------------------------
# Define CloudWatch dataset
$dimension1 = New-Object Amazon.CloudWatch.Model.Dimension
$dimension1.set_Name("WorkspaceId")

# Setting this to 1 day (60 seconds * 60 minutes * 24 hours in a day) to allow querying larger data points - see above link relating to CloudWatch metrics aggregation
$period = 86400


#---------------------------------------------------------------------------------------------

$report=@()
# Get all WorkSpaces in the specified region with the appropriate fields for the report
Try
{
    $WorkSpaces = Get-WKSWorkspace -Region $Region | Select-Object username, computername, workspaceid, ipaddress, directoryid, bundleid, subnetid, state, RootVolumeEncryptionEnabled, UserVolumeEncryptionEnabled, WorkspaceProperties
}
Catch
{
    $ErrorMessage = $_.Exception.Message
    $FailedItem = $_.Exception.ItemName
    Write-host $ErrorMessage
    Write-host $FailedItem
    Break
}    

$WorkSpacesCount = $WorkSpaces.count
Write-Host "Capturing info for $($WorkSpaces.count) WorkSpaces"


foreach ($WorkSpace in $WorkSpaces){
    # Loop through each WorkSpace capturing custom info from Active Directory and appending it to the variable that will be export to the specified log file
    Write-Host "Enumerating workspace $($WorkSpace.WorkspaceId) assigned to user $($WorkSpace.UserName)"
    $samlookup = $WorkSpace.username
    $computername = $WorkSpace.computername

    # An adhoc or inline query can be used for each of the AD User and Computer attributes but doing so up front for all attributes decreases report run time by nearly 50%
    # Query AD for all user attributes needed below
    Try
    {
        $ADUserInfo = get-aduser -filter {samaccountname -eq $samlookup} -properties Name, Enabled, Department, EmailAddress, Manager, MobilePhone | Select-Object *, @{label="ADUserManager";expression={(Get-ADUser $_.Manager -Properties DisplayName).DisplayName}}
    }
    Catch
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-host $ErrorMessage
        Write-host $FailedItem
        Break
    }
    
    # Query AD for all computer attributes needed below
    Try
    {
        $ADComputerInfo = get-adcomputer -filter {name -eq $computername} -properties Created, OperatingSystem
    }
    Catch
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-host $ErrorMessage
        Write-host $FailedItem
        Break
    }    
    
    # Query AWS for the connected state of the WorkSpace
    Try
    {
        $WorkSpaceConnectionInfo = Get-WKSWorkspacesConnectionStatus -Region $Region -WorkspaceId $WorkSpace.workspaceid
    }
    Catch
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-host $ErrorMessage
        Write-host $FailedItem
        Break
    }

    # Query AWS for the subnet info for the WorkSpace
    Try
    {
        $WorkSpaceSubnetInfo = Get-EC2Subnet -Region $Region -SubnetId $WorkSpace.SubnetId
    }
    Catch
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-host $ErrorMessage
        Write-host $FailedItem
        Break
    }    

    # Query CloudWatch to determine whether WorkSpace is inactive
    Try
    {
        $dimension1.set_Value($WorkSpace.WorkspaceId)
        $data = Get-CWMetricStatistics -Namespace "AWS/WorkSpaces" -MetricName "ConnectionSuccess" -UtcStartTime $StartDate -UtcEndTime $EndDate -Period $period -Statistics @("Maximum") -Dimensions @($dimension1)
        if(($data.datapoints.Maximum | sort -Unique | select -Last 1) -ge 1){
            # logins found
            $WorkSpaceUnused = $false
        }Else{
            # no logins found
            $WorkSpaceUnused = $true
        }
    }
    Catch
    {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-host $ErrorMessage
        Write-host $FailedItem
        Break
    }      


    # Build the report object with all required properties
    $obj = New-Object -TypeName PSObject -Property @{
        "UserName" = $WorkSpace.UserName
        "ADUserFullName" = $ADUserInfo.Name
        "ADUserDepartment" = $ADUserInfo.Department
        "ADUserEnabled" = $ADUserInfo.Enabled
        "ADUserEmailAddress" = $ADUserInfo.EmailAddress
        "ADUserManager" = $ADUserInfo.ADUserManager
        "ADUserMobilePhone" = $ADUserInfo.MobilePhone
        "ComputerName" = $WorkSpace.ComputerName
        "ADComputerCreated" = $ADComputerInfo.Created
        "ADComputerOperatingSystem" = $ADComputerInfo.OperatingSystem
        "WorkSpaceId" = $WorkSpace.WorkspaceId
        "ConnectionState" = $WorkSpaceConnectionInfo.ConnectionState
        "ConnectionStateCheckTimestamp" = $WorkSpaceConnectionInfo.ConnectionStateCheckTimestamp
        "LastKnownUserConnectionTimestamp" = $WorkSpaceConnectionInfo.LastKnownUserConnectionTimestamp
        "WorkSpaceUnusedForDefinedPeriod" = $WorkSpaceUnused
        "TagsJoin" = (Get-WKSTag -Region $Region -WorkspaceId $WorkSpace.workspaceid | Select-Object @{N='Tags';E={$_.Key,$_.Value -join ':'}}).tags  -join ";"
        "WorkSpaceState" = $WorkSpace.State
        "ComputeType" = $WorkSpace.WorkspaceProperties.ComputeTypeName
        "IpAddress" = $WorkSpace.IpAddress
        "Directory" = (get-dsdirectory -Region $Region -DirectoryID $WorkSpace.DirectoryId).alias
        "DirectoryId" = $WorkSpace.DirectoryId
        "Bundle" = (Get-WKSWorkspaceBundle -Region $Region -BundleId $WorkSpace.BundleId).Name
        "BundleId" = $WorkSpace.BundleId
        "SubnetLabel" =  $WorkSpaceSubnetInfo.Tag.Where({$_.Key -eq "Name"}).value
        "SubnetId" = $WorkSpace.SubnetId
        "SubnetAZ" = $WorkSpaceSubnetInfo.AvailabilityZone
        "SubnetAZId" = $WorkSpaceSubnetInfo.AvailabilityZoneId
        "SubnetAvailableIpAddressCount" = $WorkSpaceSubnetInfo.AvailableIpAddressCount
        "RootEncryption" = $WorkSpace.RootVolumeEncryptionEnabled
        "RootVolumeSizeGib" = $WorkSpace.WorkspaceProperties.RootVolumeSizeGib
        "UserEncryption" = $WorkSpace.UserVolumeEncryptionEnabled
        "UserVolumeSizeGib" = $WorkSpace.WorkspaceProperties.UserVolumeSizeGib
        "RunningMode" = $WorkSpace.WorkspaceProperties.RunningMode
        "TimeoutMinutes" = $WorkSpace.WorkspaceProperties.RunningModeAutoStopTimeoutInMinutes
        "Region" = $Region
        
    }
    
    # Append each WorkSpace to the report object so all objects can be written to disk at the same time
    $report += $obj | Select-Object username, `
    ADUserFullName, `
    ComputerName, `
    ADComputerCreated, `
    ADComputerOperatingSystem, `
    WorkSpaceId, `
    ConnectionState, `
    ConnectionStateCheckTimestamp, `
    LastKnownUserConnectionTimestamp, `
    WorkSpaceUnusedForDefinedPeriod, `
    WorkSpaceState, `
    ComputeType, `
    ipaddress, `
    Directory, `
    directoryid, `
    Bundle, `
    bundleid, `
    SubnetLabel, `
    SubnetId, `
    SubnetAZ, `
    SubnetAZId, `
    SubnetAvailableIpAddressCount, `
    RootEncryption, `
    RootVolumeSizeGib, `
    UserEncryption, `
    UserVolumeSizeGib, `
    RunningMode, `
    TimeoutMinutes, `
    ADUserDepartment, `
    ADUserEnabled, `
    ADUserEmailAddress, `
    ADUserManager, `
    ADUserMobilePhone, `
    Region, `
    TagsJoin
    # Decrement the count of WorkSpaces so the user sees a progress indicator
    $WorkSpacesCount--
    Write-Host "$($WorkSpacesCount) WorkSpaces remain"
}

# Write the report to disk
$report | Sort-Object UserName, Directory | Export-Csv  ($reportpath + "workspacesreport.csv") -notypeinformation -Append
