# Description: This script retrieves the security settings for Azure DevOps repositories for a selected organization, project, and team(s) and exports the data to a CSV file.
# Author: Alejandra Guillen

# Parameters:
# - repoStartsWith: The name of the repository to filter by. If not specified, all repositories will be listed.

# Prerequisites:
# - Install the Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli

# How to use:
# - Open a PowerShell command prompt.
# - Run the script and follow the prompts to select an organization and project.
# - The script will list all repositories in the selected project and prompt you to select one or more repositories.
# - The script will retrieve the security settings for the selected repositories and export the data to a CSV file.

# Example:
# - Run the script with the following command:
#   ./get-ado-repos-security-report.ps1

# Example with parameter:
# - Run the script with the following command to filter repositories by name:
#   ./get-ado-repos-security-report.ps1 -repoStartsWith "MyRepo" 

param(
    [string] $repoStartsWith = $null,
    [string] $directoryPath = ".\reports",
    [switch] $verbose,
    [switch] $writeToLogFile
)

$ErrorActionPreference = "Stop"

#region Importing Functions
Import-Module ../utils/functions.ps1 -Force
#endregion

# Get Azure Authentication headers 
$headers = Login-AzureCLI 

# Get the current user's profile
$currentProfile = Invoke-RestMethod -Uri "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.0" -Headers $headers -Method Get 

# Get all organizations current user is a member of
$allOrganizations = (Invoke-RestMethod -Uri "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$($currentProfile.id)&api-version=7.0" -Headers $headers -Method Get).value

# Prompt user to select an organization
Write-Host "`nSelect an organization:"
for ($i = 0; $i -lt $allOrganizations.Length; $i++) {
    Write-Host "$($i+1): $($allOrganizations[$i].accountName) - $($allOrganizations[$i].accountUri) "
}
[int]$orgIndex = Read-Host "Enter the number of the organization" -ErrorAction Stop
$organization = $allOrganizations[$orgIndex - 1]

$orgBaseUrl = $organization.accountUri.Replace("vssps.", "")
Write-Host -ForegroundColor Cyan "Organization: $($organization.accountName) - $orgBaseUrl"

# Retrieve Projects for the selected organization
$projects = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/projects?api-version=7.0" -Headers $headers -Method Get).value
# Prompt user to select a project
do {
    Write-Host "`nSelect a project:"
    for ($i = 0; $i -lt $projects.Length; $i++) {
        Write-Host "$($i+1): $($projects[$i].name) - $($projects[$i].id) "
    }
    [int]$projectIndex = Read-Host "Enter the number of the project"
} while ($projectIndex -eq $null -or $projectIndex -eq 0)
$project = $projects[$projectIndex - 1]

# Retreive Azure Repositories for the selected organization
$repos = (Invoke-RestMethod -Uri "$($orgBaseUrl)$($project.id)/_apis/git/repositories?api-version=7.2-preview.1" -Headers $headers -Method Get).value
#$repos | format-table -Property name, webUrl -AutoSize

if ([string]::IsNullOrEmpty($repoStartsWith)) {
    Write-Host "`nFilter repositories by name that starts with: $repoStartsWith"
    $repos = $repos | Where-Object { $_.name -like "$repoStartsWith*" }
} 

Write-Host "0: Select All"
for ($i = 0; $i -lt $repos.Length; $i++) {
    Write-Host "$($i+1): $($repos[$i].name)"
}
[array]$groupIndexes = (Read-Host "Enter the number(s) of the groups(s) comma separated" -ErrorAction Stop).Trim().Split(",")
if ($groupIndexes -contains "0") {
    $selectedRepos = $repos
}
else {
    $selectedRepos = $repos | Where-Object { $groupIndexes -contains ($repos.IndexOf($_) + 1) }
}

$securityNamespaceId = "2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87" # This is the Security Namespace for 'Git Repositories' - See: https://learn.microsoft.com/en-us/azure/devops/organizations/security/namespace-reference?view=azure-devops
$securityNamespace = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/securitynamespaces/$($securityNamespaceId)?api-version=7.2-preview.1" -Headers $headers -Method Get).value
#$securityNamespace.actions | format-table -Property bit, name, displayName -AutoSize 

$reposPermissions = @()
foreach ($repo in $selectedRepos) {

    Write-Log "Current security settings for $($repo.name):" -writeToLogFile:$writeToLogFile -verbose:$verbose
    $repoToken = "repoV2/$($repo.project.id)/$($repo.id)"
    $repoACLs = (Invoke-RestMethod -Uri "$($orgBaseUrl)_apis/accesscontrollists/$($securityNamespaceId)?token=$($repoToken)&includeExtendedInfo=true&recurse=true&api-version=7.2-preview.1" -Headers $headers -Method Get).value

    $repoACEs = @{}
    $repoACLs.acesDictionary | Get-Member -MemberType NoteProperty | ForEach-Object {
        $repoACEs[$_.Name] = $repoACLs.acesDictionary.$($_.Name)
    }

    $repoACEsList = @()
    foreach ($ace in $repoACEs.Values) {

        Write-Log "  Checking descriptor: $($ace.descriptor)" -writeToLogFile:$writeToLogFile -verbose:$verbose

        $identity = (Invoke-RestMethod -Uri "$($organization.accountUri)_apis/identities?descriptors=$($ace.descriptor)&api-version=7.2-preview.1" -Headers $headers -Method Get).value
        #$identity | ft providerDisplayName, descriptor
        
        Write-Log "    Display name: $($identity.providerDisplayName)" -writeToLogFile:$writeToLogFile -verbose:$verbose
        
        $allowActions = (Calculate-BitToActions -bit $ace.allow -actions $securityNamespace.actions)
        $denyActions = (Calculate-BitToActions -bit $ace.deny -actions $securityNamespace.actions)
        $effectiveAllowActions = (Calculate-BitToActions -bit $ace.extendedInfo.effectiveAllow -actions $securityNamespace.actions)
        $effectiveDenyActions = (Calculate-BitToActions -bit $ace.extendedInfo.effectiveDeny -actions $securityNamespace.actions)
        
        $permissions = Calculate-FinalPermissions -actions $securityNamespace.actions -allowActions $allowActions -denyActions $denyActions -effectiveAllowActions $effectiveAllowActions -effectiveDenyActions $effectiveDenyActions
        
        $permissions | Select-Object displayName, value | ForEach-Object { Write-Log "      $($_.displayName): $($_.value)" -writeToLogFile:$writeToLogFile -verbose:$verbose }

        $repoACEsList += [PSCustomObject]@{
            projectId = $project.id
            projectName = $project.name
            repositoryId = $repo.id
            repository = $repo.name
            repositoryUrl = $repo.webUrl
            descriptor = $ace.descriptor
            allow = $ace.allow
            deny = $ace.deny
            extendedInfo = $ace.extendedInfo
            displayName = $identity.providerDisplayName
            permissions = $permissions
            allowActions = $allowActions
            denyActions = $denyActions
            effectiveAllowActions = $effectiveAllowActions
            effectiveDenyActions = $effectiveDenyActions
        }
    }   

    $reposPermissions += $repoACEsList
}

$reposPermissionsReport = $reposPermissions | Select-Object projectName,repository,repositoryUrl, displayName, permissions 
foreach ($r in $reposPermissionsReport) { 
    foreach ($p in $r.permissions) { 
        $r | Add-Member -MemberType NoteProperty -Name $p.displayName -Value $p.value -Force
    }
}

$reposPermissionsReport = $reposPermissionsReport | Select-Object -Property * -ExcludeProperty permissions

$reposPermissionsReport | Select-Object -Property * -ExcludeProperty projectName,repositoryUrl | format-table  -AutoSize

Export-DataToCsv -inputObject $reposPermissionsReport -fileName "repositories-security-report" -directoryPath $directoryPath -forceCSVExport -delimiter "," 
