# Description: This script contains utility functions used by other scripts
# Author: Alejandra Guillen

# Example:
#> .\reporting-scripts\get-multi-org-report.ps1

# Example with parameters:
#> .\reporting-scripts\get-multi-org-report.ps1 -forceCSVExport -directoryPath ".\reports"

Write-Host "Loading functions..."

function Login-AzureCLI {

    $login = Read-Host "`nDo you need to login to Azure CLI? (Y/N)"
    if ($login.ToLower() -eq "y") {
        Write-Host "Login to Azure CLI"
        az login
    }

    # Retrieve the access token
    $token = $(az account get-access-token --query accessToken --output tsv)

    # Define Headers for the REST API request
    $headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

    return $headers
}

# Export data to a CSV file
function Export-DataToCsv {
    
    param (
        [string] $fileName,
        [object] $inputObject,
        [switch] $append,
        [string] $delimiter = ",",
        [string] $directoryPath = ".\reports",
        [switch] $forceCSVExport

    )
      
    if (-not (Test-Path -Path $directoryPath)) {
        New-Item -ItemType Directory -Path $directoryPath
    }

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

# Security 
function Calculate-BitToActions {
    param (
        [int] $bit,
        [array] $actions
    )
    
    $actionListInBit = @()
    $orderDesc = $actions | Sort-Object -Property bit -Descending
    for ($i=0; $i -lt $orderDesc.Length; $i++) {
        if ($bit -ge $orderDesc[$i].bit) {
            $actionListInBit += $orderDesc[$i]
            $bit = $bit - $orderDesc[$i].bit
        }
    }

    return $actionListInBit
}

function Calculate-FinalPermissions {
    param (
        [array] $actions,
        [array] $allowActions,
        [array] $denyActions,
        [array] $effectiveAllowActions,
        [array] $effectiveDenyActions
    )
    
    $permissions = @()

    foreach ($action in $actions) {
        
        if ($effectiveAllowActions.bit -contains $action.bit) {
            $value = "Allow (Inherited)"
        }
        elseif ($effectiveDenyActions.bit -contains $action.bit) {
            $value = "Deny (Inherited)"
        }
        elseif ($allowActions.bit -contains $action.bit) {
            $value = "Allow"
        }
        elseif ($denyActions.bit -contains $action.bit) {
            $value = "Deny"
        }
        else {
            $value = "Not Set"
        }

        $permissions += [PSCustomObject]@{
            bit = $action.bit
            displayName = $action.displayName
            name = $action.name
            namespaceId = $action.namespaceId
            value = $value
        }
    }

    return ($permissions | Sort-Object -Property displayName)
}