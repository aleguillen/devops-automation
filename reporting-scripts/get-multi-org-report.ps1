# Description: This script retrieves all the projects and agent pools from all the organizations the current user is a member of.
# Author: Alejandra Guillen

#region Functions
function Export-DataToCsv {
    param (
        [string] $path,
        [object] $inputObject,
        [switch] $append,
        [string] $delimiter = ","

    )
      
    # Prompt user to export the data to a CSV file
    $export = Read-Host "Do you want to export the data to a CSV file? (Y/N)"
    if ($export.ToLower() -eq "y") {
        if ([string]::IsNullOrEmpty($path)) {
            $path = Read-Host "Enter the path to the CSV file. Ex. C:\temp\output.csv"
        }
        else {
            Write-Host "Exporting data to $path"
        }

        if ($append) {
            $inputObject | Export-Csv -Path $path -Append -Delimiter $delimiter -NoTypeInformation
        }
        else {
            $inputObject | Export-Csv -Path $path -Delimiter $delimiter -NoTypeInformation
        }
        Write-Host "Data exported to $path"
    }
}
#endregion

# Prompt user if needs to login to Azure CLI
# Using Azure CLI to retrieve access account
# To Install Azure CLI see https://docs.microsoft.com/en-us/cli/azure/install-azure-cli

$login = Read-Host "Do you need to login to Azure CLI? (Y/N)"
if ($login.ToLower() -eq "y") {
    Write-Host "Login to Azure CLI"
    az login
}

# Retrieve the access token
$token = $(az account get-access-token --query accessToken --output tsv)

# Define Headers for the REST API request
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Get the current user's profile
$currentProfile = Invoke-RestMethod -Uri "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.0" -Headers $headers -Method Get 

# Get all organizations current user is a member of
$allOrganizations = (Invoke-RestMethod -Uri "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$($currentProfile.id)&api-version=7.0" -Headers $headers -Method Get).value

# Prompt user to select an organization
Write-Host "Select an organization:"
Write-Host "0: All organizations"
for ($i = 0; $i -lt $allOrganizations.Length; $i++) {
    Write-Host "$($i+1): $($allOrganizations[$i].accountName) - $($allOrganizations[$i].accountUri) "
}
Write-Host "0: All organizations"
[int]$orgIndex = Read-Host "Enter the number of the organization" -ErrorAction Stop
if ($orgIndex -eq 0) {
    $organizations = $allOrganizations
}
else {
    $organizations = @($allOrganizations[$orgIndex - 1])
}

# Prompt user to select if want to report agent pools or projects
Write-Host "Select the report to generate:"
Write-Host "1: Agent Pools"
Write-Host "2: Projects"
Write-Host "3: Both"
[int]$reportType = Read-Host "Enter the number of the report" -ErrorAction Stop


foreach ($organization in $organizations) {
    $orgBaseUrl = $organization.accountUri.Replace("vssps.", "")
    Write-Host "Organization: $($organization.accountName) - $orgBaseUrl"

    # Get Agent Pools Information
    if ($reportType -eq 1 -or $reportType -eq 3) {
        $agentPools = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/distributedtask/pools?api-version=7.0" -Headers $headers -Method Get).value
        Write-Host "Total Agent Pools: $($agentPools.Length)"
        $agentPools | ft id, name, size, isHosted, createdOn -AutoSize
        Export-DataToCsv -inputObject $agentPools
    
        $allPoolAgents = @()
        foreach ($agentPool in $agentPools) {
            Write-Host "Agent Pool: $($agentPool.name) | Auto Provision: $($agentPool.autoProvision)"
            $poolAgents = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/distributedtask/pools/$($agentPool.id)/agents?includeCapabilities=true&api-version=7.0" -Headers $headers -Method Get).value
        
            $poolAgents | foreach {
                $_ | Add-Member -MemberType NoteProperty -Name "poolName" -Value $agentPool.name
                $_ | Add-Member -MemberType NoteProperty -Name "poolAutoProvision" -Value $agentPool.autoProvision
                $_ | Add-Member -MemberType NoteProperty -Name "poolAutoUpdate" -Value $agentPool.autoProvision
                $_ | Add-Member -MemberType NoteProperty -Name "poolAutoSize" -Value $agentPool.autoProvision
                $_ | Add-Member -MemberType NoteProperty -Name "poolId" -Value $agentPool.id
                $_ | Add-Member -MemberType NoteProperty -Name "poolIsHosted" -Value $agentPool.isHosted
                $_ | Add-Member -MemberType NoteProperty -Name "poolIsLegacy" -Value $agentPool.isLegacy
                $_ | Add-Member -MemberType NoteProperty -Name "poolCreatedBy" -Value $agentPool.createdBy.displayName
                $_ | Add-Member -MemberType NoteProperty -Name "poolCreatedOn" -Value $agentPool.createdOn
                $_ | Add-Member -MemberType NoteProperty -Name "poolModifiedBy" -Value $agentPool.modifiedBy.displayName
                $_ | Add-Member -MemberType NoteProperty -Name "poolModifiedOn" -Value $agentPool.modifiedOn
                $_ | Add-Member -MemberType NoteProperty -Name "poolOwner" -Value $agentPool.owner.displayName
                $_ | Add-Member -MemberType NoteProperty -Name "poolStatus" -Value $agentPool.status
                $_ | Add-Member -MemberType NoteProperty -Name "poolSize" -Value $agentPool.size
                $_ | Add-Member -MemberType NoteProperty -Name "poolOptions" -Value $agentPool.options
                $_ | Add-Member -MemberType NoteProperty -Name "poolScope" -Value $agentPool.scope
            }

            $allPoolAgents += $poolAgents
        }
        Write-Host "Total Agents: $($allPoolAgents.Length)"
        $allPoolAgents | ft id, name, version, osDescription, enabled, provisioningState -AutoSize
        Export-DataToCsv -inputObject $allPoolAgents
    }
    # Get Projects Information
    if ($reportType -eq 2 -or $reportType -eq 3) {

       $projects = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/projects?api-version=7.0" -Headers $headers -Method Get).value
    
        foreach ($project in $projects) {
            $projectDetails = Invoke-RestMethod -Uri "$($project.url)?includeCapabilities=true&api-version=7.0" -Headers $headers -Method Get
            $projectProperties = (Invoke-RestMethod -Uri "$($project.url)/properties?api-version=7.0-preview.1" -Headers $headers -Method Get).value

            $project | Add-Member -MemberType NoteProperty -Name "capabilities" -Value $projectDetails.capabilities
            $project | Add-Member -MemberType NoteProperty -Name "defaultTeam" -Value $projectDetails.defaultTeam.name
            $project | Add-Member -MemberType NoteProperty -Name "process" -Value $projectDetails.capabilities.processTemplate.templateName
            $project | Add-Member -MemberType NoteProperty -Name "sourceControlType" -Value $projectDetails.capabilities.versioncontrol.sourceControlType
            $project | Add-Member -MemberType NoteProperty -Name "gitEnabled" -Value $projectDetails.capabilities.versioncontrol.gitEnabled
            $project | Add-Member -MemberType NoteProperty -Name "tfvcEnabled" -Value $projectDetails.capabilities.versioncontrol.tfvcEnabled
            $projectProperties | foreach {
                $project | Add-Member -MemberType NoteProperty -Name $_.name -Value $_.value
            }
        }

        Write-Host "Total Projects: $($projects.Length)"
        $projects | ft id, name, state, visibility, description -AutoSize
        Export-DataToCsv -inputObject $projects
    }
}


