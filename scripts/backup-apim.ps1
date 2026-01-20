#requires -Version 5.1
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# -------------------------
# CONFIG
# -------------------------
$prodRG      = "rg-prod-westeu-api-lbc-001"
$prodService = "apim-prod-westeu-apim-lbc-001"
$rootFolder  = "apim"

# Keep api-version consistent
$apiVersion  = "2022-08-01"

# -------------------------
# HELPERS
# -------------------------
function Ensure-Folder($path) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}

function Write-FileUtf8NoBom($path, $content) {
    # Avoid BOM weirdness and GitHub push-protection issues from encoding glitches
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
}

function Get-PolicyXmlFromArm($uri) {
    # Returns $null if no policy or not found
    try {
        $jsonText = az rest --method get --uri $uri --headers "Accept=application/json" --output json 2>$null
        if (-not $jsonText) { return $null }
        $obj = $jsonText | ConvertFrom-Json
        $xml = $obj.properties.value
        if ([string]::IsNullOrWhiteSpace($xml)) { return $null }
        return $xml
    } catch {
        return $null
    }
}

# -------------------------
# PRECHECKS
# -------------------------
$subId = (az account show --query id -o tsv)
if (-not $subId) { throw "Not logged into Azure CLI. Run: az login" }

Ensure-Folder $rootFolder
Ensure-Folder (Join-Path $rootFolder "apis")
Ensure-Folder (Join-Path $rootFolder "products")
Ensure-Folder (Join-Path $rootFolder "named-values")

Write-Host "Backing up APIM: $prodService in RG: $prodRG" -ForegroundColor Cyan

# -------------------------
# 1) APIs: OpenAPI + API policy + Operations policies
# -------------------------
$apiIds = az apim api list --resource-group $prodRG --service-name $prodService --query "[].name" -o tsv

foreach ($apiId in $apiIds) {
    Write-Host "API: $apiId" -ForegroundColor Yellow

    $apiFolder = Join-Path $rootFolder "apis\$apiId"
    Ensure-Folder $apiFolder

    # 1A) Export OpenAPI (file export has a weird naming behavior)
    # We export to the API folder and then rename the produced file to api-definition.json
    az apim api export `
      --resource-group $prodRG `
      --service-name $prodService `
      --api-id $apiId `
      --export-format OpenApiJsonFile `
      --file-path $apiFolder | Out-Null

    # Rename *_openapi+json.json => api-definition.json
    $exported = Get-ChildItem -Path $apiFolder -Filter "*_openapi+json.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exported) {
        Move-Item -Force $exported.FullName (Join-Path $apiFolder "api-definition.json")
    } else {
        # Some APIs may not export properly; leave a marker
        Write-FileUtf8NoBom (Join-Path $apiFolder "_export_warning.txt") "OpenAPI export did not produce *_openapi+json.json"
    }

    # 1B) API-level policy
    $apiPolicyUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$prodRG/providers/Microsoft.ApiManagement/service/$prodService/apis/$apiId/policies/policy?api-version=$apiVersion"
    $apiPolicyXml = Get-PolicyXmlFromArm $apiPolicyUri
    if ($apiPolicyXml) {
        Write-FileUtf8NoBom (Join-Path $apiFolder "policy.xml") $apiPolicyXml
    } else {
        Write-FileUtf8NoBom (Join-Path $apiFolder "policy.xml") "NO POLICY"
    }

    # 1C) Operation-level policies
    $ops = az apim api operation list `
        --resource-group $prodRG `
        --service-name $prodService `
        --api-id $apiId `
        --query "[].{Name:name, Url:urlTemplate, Method:method}" -o json | ConvertFrom-Json

    foreach ($op in $ops) {
        $opId = $op.Name
        $opPolicyUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$prodRG/providers/Microsoft.ApiManagement/service/$prodService/apis/$apiId/operations/$opId/policies/policy?api-version=$apiVersion"
        $opPolicyXml = Get-PolicyXmlFromArm $opPolicyUri

        if ($opPolicyXml) {
            $opFolder = Join-Path $apiFolder "operations\$opId"
            Ensure-Folder $opFolder
            Write-Host ("  OP policy: {0} {1}" -f $op.Method, $op.Url) -ForegroundColor Magenta
            Write-FileUtf8NoBom (Join-Path $opFolder "policy.xml") $opPolicyXml
        }
    }
}

# -------------------------
# 2) Products + Product policies (optional but good)
# -------------------------
$productIds = az apim product list --resource-group $prodRG --service-name $prodService --query "[].name" -o tsv

foreach ($productId in $productIds) {
    Write-Host "Product: $productId" -ForegroundColor DarkCyan
    $prodFolder = Join-Path $rootFolder "products\$productId"
    Ensure-Folder $prodFolder

    # Save product metadata (non-secret)
    $product = az apim product show --resource-group $prodRG --service-name $prodService --product-id $productId -o json
    Write-FileUtf8NoBom (Join-Path $prodFolder "product.json") $product

    # Product policy (if any)
    $prodPolicyUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$prodRG/providers/Microsoft.ApiManagement/service/$prodService/products/$productId/policies/policy?api-version=$apiVersion"
    $prodPolicyXml = Get-PolicyXmlFromArm $prodPolicyUri
    if ($prodPolicyXml) {
        Write-FileUtf8NoBom (Join-Path $prodFolder "policy.xml") $prodPolicyXml
    } else {
        Write-FileUtf8NoBom (Join-Path $prodFolder "policy.xml") "NO POLICY"
    }
}

# -------------------------
# 3) Named values (names only; do NOT export secrets)
# -------------------------
# This is safe: it lists names/metadata. Secret values are not returned.
$namedValues = az apim nv list --resource-group $prodRG --service-name $prodService -o json
Write-FileUtf8NoBom (Join-Path $rootFolder "named-values\named-values.json") $namedValues

Write-Host " APIM backup complete. Review changes, then git add/commit." -ForegroundColor Green
