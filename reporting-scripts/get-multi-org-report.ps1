# Description: This script retrieves all the projects and agent pools from all the organizations the current user is a member of.
# Author: Alejandra Guillen

param(
    [switch] $forceCSVExport,
    
    [string] $directoryPath = ".\reports" 
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -Path $directoryPath)) {
    New-Item -ItemType Directory -Path $directoryPath
}

#region Functions
function Export-DataToCsv {
    param (
        [string] $fileName,
        [object] $inputObject,
        [switch] $append,
        [string] $delimiter = ","

    )
      
    # Prompt user to export the data to a CSV file
    if ($forceCSVExport) {
        $export = "Y"
    }
    else {
        $export = Read-Host "Do you want to export the data to a CSV file? (Y/N)"
    }
    
    if ($export.ToLower() -eq "y") {
        
        $filePath = $directoryPath + "\" + $fileName + "-" + (Get-Date).ToString("yyyy-MM-dd") + ".csv"

        if ($append) {
            $inputObject | Export-Csv -Path $filePath -Append -Delimiter $delimiter -NoTypeInformation
        }
        else {
            $inputObject | Export-Csv -Path $filePath -Delimiter $delimiter -NoTypeInformation
        }
        Write-Host -ForegroundColor Green "  [info] - Data exported to $filePath"
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
Write-Host "1: Projects"
Write-Host "2: Agent Pools"
Write-Host "0: Both"
[int]$reportType = Read-Host "Enter the number of the report" -ErrorAction Stop

foreach ($organization in $organizations) {
    $orgBaseUrl = $organization.accountUri.Replace("vssps.", "")
    Write-Host -ForegroundColor Cyan "Organization: $($organization.accountName) - $orgBaseUrl"
    try {
        $checkOrg = Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/projects?`$top=5&api-version=7.0" -Headers $headers -Method Get
    }
    catch {
        Write-Host -ForegroundColor Red "  [error] - Error retrieving organization details: $($_.Exception.Message)"
        continue
    }    

    # Get Projects Information
    if ($reportType -eq 1 -or $reportType -eq 0) {
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
             $projectProperties | ForEach-Object {
                 $project | Add-Member -MemberType NoteProperty -Name $_.name -Value $_.value
             }
             $project | Add-Member -MemberType NoteProperty -Name "organizationName" -Value $organization.accountName
             $project | Add-Member -MemberType NoteProperty -Name "organizationUrl" -Value $organization.accountUri
             $project | Add-Member -MemberType NoteProperty -Name "organizationId" -Value $organization.accountId
         }
 
         $organization | Add-Member -MemberType NoteProperty -Name "projects" -Value $projects
 
         Write-Host " - Projects:"
         $projects | Format-Table id, name, state, visibility, description -AutoSize
         if ($projects.Length -gt 0) {
             Export-DataToCsv -inputObject $projects -fileName "$($organization.accountName)-projects"
         }
         Write-Host  -ForegroundColor Blue " - Total Projects: $($projects.Length)"
     }

    # Get Agent Pools Information
    if ($reportType -eq 2 -or $reportType -eq 0) {
        $agentPools = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/distributedtask/pools?api-version=7.0" -Headers $headers -Method Get).value
        Write-Host " - Agent Pools: "
        $agentPools | Format-Table id, name, size, isHosted, createdOn -AutoSize
        if ($agentPools.Length -gt 0) {
            Export-DataToCsv -inputObject $agentPools -fileName "$($organization.accountName)-agent_pools"
        }
        Write-Host -ForegroundColor Blue " - Total Agent Pools: $($agentPools.Length)"
    
        $allPoolAgents = @()
        foreach ($agentPool in $agentPools) {
            $poolAgents = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/distributedtask/pools/$($agentPool.id)/agents?includeCapabilities=true&api-version=7.0" -Headers $headers -Method Get).value
        
            $poolAgents | ForEach-Object {
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
        
        $organization | Add-Member -MemberType NoteProperty -Name "agentPool" -Value $agentPools
        $organization | Add-Member -MemberType NoteProperty -Name "agents" -Value $allPoolAgents
        Write-Host " - Agents: "
        $allPoolAgents | Format-Table id, name, version, osDescription, enabled, provisioningState -AutoSize
        if ($allPoolAgents.Length -gt 0) {
            Export-DataToCsv -inputObject $allPoolAgents -fileName "$($organization.accountName)-agents"
        }
        Write-Host  -ForegroundColor Blue " - Total Agents: $($allPoolAgents.Length)"
    }
}

Write-Host " - Organizations:"
$organizations | Format-Table accountName,accountUri -AutoSize
if ($organizations.Length -gt 0) {
    Export-DataToCsv -inputObject $organizations -fileName "all-organizations"
}
Write-Host  -ForegroundColor Blue " - Total Organizations: $($organizations.Length)"


