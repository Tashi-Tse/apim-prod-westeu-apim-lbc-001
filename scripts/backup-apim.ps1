# Backup APIM APIs + API policies + Operation policies (PROD)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Always run from repo root (script lives in /scripts)
Set-Location (Split-Path $PSScriptRoot -Parent)

# ----- CONFIG -----
$prodRG      = "rg-prod-westeu-api-lbc-001"
$prodService = "apim-prod-westeu-apim-lbc-001"
$rootFolder  = "apim"
$apiVersion  = "2022-08-01"
$subId       = (az account show --query id -o tsv)

function Ensure-Folder([string]$p) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
}

Ensure-Folder $rootFolder
Ensure-Folder (Join-Path $rootFolder "apis")

Write-Host "Backing up APIM: $prodService in RG: $prodRG" -ForegroundColor Cyan

# Get APIs
$apiIds = az apim api list --resource-group $prodRG --service-name $prodService --query "[].name" -o tsv

foreach ($apiId in $apiIds) {
    Write-Host "API: $apiId" -ForegroundColor Yellow

    $apiFolder = Join-Path $rootFolder "apis\$apiId"
    Ensure-Folder $apiFolder

    # 1) Export OpenAPI to folder (az CLI decides filename)
    az apim api export `
      --resource-group $prodRG `
      --service-name $prodService `
      --api-id $apiId `
      --export-format OpenApiJsonFile `
      --file-path $apiFolder | Out-Null

    # Rename *_openapi+json.json -> api-definition.json
    $exported = Get-ChildItem -Path $apiFolder -Filter "*_openapi+json.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exported) {
        Move-Item -Force $exported.FullName (Join-Path $apiFolder "api-definition.json")
    }

    # 2) API policy via ARM
    $apiPolicyUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$prodRG/providers/Microsoft.ApiManagement/service/$prodService/apis/$apiId/policies/policy?api-version=$apiVersion"

    try {
        $policyJson = az rest --method get --uri $apiPolicyUri --headers "Accept=application/json" --output json 2>$null
        if ($policyJson) {
            $policyObj = $policyJson | ConvertFrom-Json
            $xml = $policyObj.properties.value
            if ([string]::IsNullOrWhiteSpace($xml)) { $xml = "NO POLICY" }
        } else {
            $xml = "NO POLICY"
        }
    } catch {
        $xml = "NO POLICY"
    }

    $xml | Out-File -FilePath (Join-Path $apiFolder "policy.xml") -Encoding utf8

    # 3) Operation policies
    $ops = az apim api operation list `
        --resource-group $prodRG `
        --service-name $prodService `
        --api-id $apiId `
        --query "[].{Name:name, Url:urlTemplate, Method:method}" -o json | ConvertFrom-Json

    foreach ($op in $ops) {
        $opId = $op.Name
        $opPolicyUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$prodRG/providers/Microsoft.ApiManagement/service/$prodService/apis/$apiId/operations/$opId/policies/policy?api-version=$apiVersion"

        try {
            $opPolicyJson = az rest --method get --uri $opPolicyUri --headers "Accept=application/json" --output json 2>$null
            if (-not $opPolicyJson) { continue }
            $opPolicyObj = $opPolicyJson | ConvertFrom-Json
            $opXml = $opPolicyObj.properties.value
            if ([string]::IsNullOrWhiteSpace($opXml)) { continue }

            $opFolder = Join-Path $apiFolder "operations\$opId"
            Ensure-Folder $opFolder

            Write-Host ("  OP policy: {0} {1}" -f $op.Method, $op.Url) -ForegroundColor Magenta
            $opXml | Out-File -FilePath (Join-Path $opFolder "policy.xml") -Encoding utf8
        } catch {
            # most operations have no policy => ignore
        }
    }
}

Write-Host "Backup complete (APIs + API policies + operation policies)." -ForegroundColor Green
