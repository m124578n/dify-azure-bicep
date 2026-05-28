param (
    [string]$ResourceGroupName = "",
    [switch]$SkipDeploy,
    [ValidateSet("dev", "prod")]
    [string]$Environment = "dev"
)

$parametersFile = if ($Environment -eq "prod") { "./parameters.prod.json" } else { "./parameters.json" }
Write-Host "Environment: $Environment (using $parametersFile)" -ForegroundColor Cyan

# Set default resource group at the beginning of the script (after parameter declaration)
$env:AZURE_DEFAULTS_GROUP = $ResourceGroupName

# If resource group name is not specified, retrieve it from parameters file
if (Test-Path $parametersFile) {
    $params = Get-Content $parametersFile | ConvertFrom-Json
    $location = $params.parameters.location.value
    if ($ResourceGroupName -eq "") {
        $ResourceGroupName = $params.resourceGroupName
        if (-not $ResourceGroupName) {
            Write-Error "resourceGroupName is not set. Add it to $parametersFile or pass -ResourceGroupName."
            exit 1
        }
    }
    Write-Host "Resource Group Name: $ResourceGroupName"
    $env:AZURE_DEFAULTS_GROUP = $ResourceGroupName

    $pgsqlUser = $params.parameters.pgsqlUser.value
    $pgsqlPassword = $params.parameters.pgsqlPassword.value

} else {
    Write-Error "$parametersFile file not found. Please specify a resource group name."
    exit 1
}

# Check Azure CLI sign-in status
$loginStatus = az account show --query "name" -o tsv 2>$null
if (-not $loginStatus) {
    Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
    az login
}

# Deploy Bicep template if not skipping
if (-not $SkipDeploy) {
    # Ensure resource groups exist (skip creation if already exists)
    function Ensure-ResourceGroup {
        param ([string]$Name, [string]$Location)
        $exists = az group exists --name $Name
        if ($exists -eq "true") {
            Write-Host "Resource group '$Name' already exists, skipping creation." -ForegroundColor Gray
        } else {
            Write-Host "Creating resource group '$Name'..." -ForegroundColor Cyan
            az group create --name $Name --location $Location --output none
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to create resource group '$Name'. Please ask an admin to create it and grant you Contributor access."
                exit 1
            }
            Write-Host "Resource group '$Name' created." -ForegroundColor Green
        }
    }

    Ensure-ResourceGroup -Name $ResourceGroupName -Location $location

    Write-Host "Deploying Bicep template..." -ForegroundColor Cyan
    az deployment group create --resource-group $ResourceGroupName --template-file main.bicep --parameters $parametersFile

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Bicep deployment failed."
        exit 1
    }
}

# Check current Azure context
Write-Host "Checking Azure subscription information..." -ForegroundColor Cyan
$currentSubscription = az account show --query "name" -o tsv
Write-Host "Current subscription: $currentSubscription"

# Verify resource group exists
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "true") {
    Write-Host "Resource group found: $ResourceGroupName" -ForegroundColor Green
} else {
    Write-Error "Resource group does not exist: $ResourceGroupName"
    exit 1
}

# Retrieve storage account information (with more specific query)
Write-Host "Retrieving storage account information..." -ForegroundColor Cyan
$storageAccounts = az storage account list --resource-group $ResourceGroupName --query "[?starts_with(name, 'st')].name" -o tsv

if (-not $storageAccounts) {
    # Retry with alternative query
    $storageAccounts = az storage account list --resource-group $ResourceGroupName --query "[].name" -o tsv
    
    if (-not $storageAccounts) {
        Write-Error "No storage account found in resource group: $ResourceGroupName"
        exit 1
    }
}

# Use the first storage account if multiple exist
$storageAccountArray = $storageAccounts -split "\r?\n"
$storageAccountName = $storageAccountArray[0]
Write-Host "Storage account name: $storageAccountName"

# Retrieve storage account key
$storageAccountKey = (az storage account keys list --resource-group $ResourceGroupName --account-name $storageAccountName --query "[0].value" -o tsv)
if (-not $storageAccountKey) {
    Write-Error "Failed to retrieve storage account key"
    exit 1
}

# Temporarily enable public access for file upload (storage is Disabled by default)
Write-Host "Temporarily enabling storage account public access for file upload..." -ForegroundColor Yellow
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --public-network-access Enabled --default-action Deny --output none

# Get client IP and add to firewall
$clientIP = $null
try {
    $clientIP = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
    if ($clientIP) {
        Write-Host "Adding current IP $clientIP to storage firewall..." -ForegroundColor Yellow
        az storage account network-rule add --account-name $storageAccountName --resource-group $ResourceGroupName --ip-address $clientIP --output none
        Start-Sleep -Seconds 10
    }
}
catch {
    Write-Warning "Failed to retrieve client IP. Storage firewall rule not added - upload may fail if not in VNet."
}

# Fix SAS token generation
try {
    # Treat SAS token as string when storing in variable
    $end = (Get-Date).AddHours(24).ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # Use Out-String to retrieve SAS token for storing in variable
    $sasResult = (az storage account generate-sas --account-name $storageAccountName --services f --resource-types sco --permissions acdlrw --expiry $end --https-only --output tsv | Out-String).Trim()
    
    if ([string]::IsNullOrWhiteSpace($sasResult)) {
        throw "SAS token is empty"
    }
    
    # Save SAS token as variable (use directly instead of environment variable)
    $sasToken = "?$sasResult"
    Write-Host "SAS token generated (valid for 24 hours)" -ForegroundColor Green
    
    # Set flag to use as alternative
    $useSasEnv = $true
} catch {
    Write-Warning "Error occurred during SAS token generation: $_"
    
    # Alternative authentication method: Use storage account key
    Write-Host "Attempting alternative authentication method using storage account key..." -ForegroundColor Yellow
    $storageKey = $storageAccountKey
    $useSasEnv = $false
    $sasToken = $null
}

# Check for azcopy existence and install if needed
$azcopyPath = $null
try {
    $azcopyPath = (Get-Command azcopy -ErrorAction SilentlyContinue).Source
} catch {
    # azcopy not found
}

if (-not $azcopyPath) {
    # Check if already downloaded to temp directory
    $tempDir = Join-Path $env:TEMP "azcopy"
    $cachedExe = Get-ChildItem -Path $tempDir -Filter "azcopy.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cachedExe) {
        $azcopyPath = $cachedExe.FullName
        Write-Host "Using cached azcopy: $azcopyPath" -ForegroundColor Gray
    } else {
        Write-Host "azcopy not found. Downloading..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        $azcopyZip = Join-Path $tempDir "azcopy.zip"
        $downloadUrl = "https://aka.ms/downloadazcopy-v10-windows"

        Write-Host "  Downloading azcopy..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $downloadUrl -OutFile $azcopyZip -UseBasicParsing

        # Extract
        Write-Host "  Extracting azcopy..." -ForegroundColor Cyan
        Expand-Archive -Path $azcopyZip -DestinationPath $tempDir -Force

        $azcopyExe = Get-ChildItem -Path $tempDir -Filter "azcopy.exe" -Recurse | Select-Object -First 1
        if ($azcopyExe) {
            $azcopyPath = $azcopyExe.FullName
            Write-Host "  Using azcopy: $azcopyPath" -ForegroundColor Green
        } else {
            Write-Warning "Failed to install azcopy. Falling back to az storage file upload."
            $azcopyPath = $null
        }
    }
}

if ($azcopyPath) {
    Write-Host "Using azcopy to upload files: $azcopyPath" -ForegroundColor Green
}

# Upload files to file shares
$shares = @("nginx", "ssrfproxy", "sandbox", "pluginstorage")
$useAzCli = $false

foreach ($share in $shares) {
    Write-Host "Processing file share '$share'..." -ForegroundColor Cyan
    
    # Check if file share exists, create if it doesn't
    if ($useSasEnv) {
        # Use SAS token
        $shareExists = az storage share exists --account-name $storageAccountName --name $share --sas-token "`"$sasToken`"" --query "exists" -o tsv
        if ($shareExists -ne "true") {
            Write-Host "  Creating file share '$share'..."
            az storage share create --account-name $storageAccountName --name $share --sas-token "`"$sasToken`""
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to create file share '$share'. Continuing process."
            }
        }
    } else {
        # Use storage key
        $shareExists = az storage share exists --account-name $storageAccountName --name $share --account-key $storageKey --query "exists" -o tsv
        if ($shareExists -ne "true") {
            Write-Host "  Creating file share '$share'..."
            az storage share create --account-name $storageAccountName --name $share --account-key $storageKey
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to create file share '$share'. Continuing process."
            }
        }
    }
    
    # Upload files directly from mountfiles directory
    $sourcePath = "./mountfiles/$share"
    if (Test-Path $sourcePath) {
        Write-Host "Uploading configuration files..." -ForegroundColor Cyan
        
        # Use azcopy if available
        if ($azcopyPath) {
            Write-Host "  Batch uploading using azcopy..." -ForegroundColor Cyan
            
            # Use SAS token or storage key
            if ($useSasEnv) {
                $destUrl = "https://$storageAccountName.file.core.windows.net/$share$sasToken"
            } else {
                # Generate SAS token from storage key
                $tempSasToken = (az storage share generate-sas --account-name $storageAccountName --name $share --permissions rwdl --expiry (Get-Date).AddHours(1).ToString("yyyy-MM-ddTHH:mm:ssZ") --account-key $storageAccountKey --output tsv)
                $destUrl = "https://$storageAccountName.file.core.windows.net/$share`?$tempSasToken"
            }
            
            # azcopyで再帰的にアップロード
            $azcopyArgs = @(
                "copy",
                "$sourcePath/*",
                $destUrl,
                "--recursive=true",
                "--overwrite=true",
                "--log-level=WARNING"
            )
            
            & $azcopyPath $azcopyArgs
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Upload completed with azcopy" -ForegroundColor Green
            } else {
                Write-Warning "  Upload with azcopy failed. Falling back to az CLI."
                # Set fallback flag
                $useAzCli = $true
            }
        } else {
            # Use az CLI if azcopy is not available
            $useAzCli = $true
        }
        
        # Upload using az CLI (fallback)
        if ($useAzCli) {
        
        # Convert to absolute path
        $sourcePathAbsolute = (Resolve-Path $sourcePath).Path
        
        # Get list of directories and files
        $customDirs = @()
        Get-ChildItem -Path $sourcePathAbsolute -Recurse -Directory | ForEach-Object {
            # Get relative path from source directory (without path separator)
            $relativePath = $_.FullName.Substring($sourcePathAbsolute.Length).TrimStart('\', '/')
            if ($relativePath) {
                $customDirs += $relativePath
            }
        }
        
        # Sort directories in hierarchical order and create (parent → child order)
        $customDirs = $customDirs | Sort-Object { $_.Split('\\').Count }
        foreach ($dir in $customDirs) {
            $dirPath = $dir -replace "\\\\", "/"
            try {
                if ($useSasEnv) {
                    az storage directory create --account-name $storageAccountName --share-name $share --name $dirPath --sas-token "`"$sasToken`"" --output none 2>$null
                } else {
                    az storage directory create --account-name $storageAccountName --share-name $share --name $dirPath --account-key $storageKey --output none 2>$null
                }
                Write-Host "  Created directory: $dirPath"
            } catch {
                Write-Host "  Skipped directory creation (already exists): $dirPath" -ForegroundColor Gray
            }
        }
        
        # Upload filess
        Get-ChildItem -Path $sourcePathAbsolute -Recurse -File | ForEach-Object {
            # Get relative path from source directory (without path separator)
            $relativePath = $_.FullName.Substring($sourcePathAbsolute.Length).TrimStart('\\', '/')
            $targetPath = $relativePath -replace "\\\\", "/"
            
            # Get parent directory path of file
            $parentDir = Split-Path -Path $targetPath -Parent
            
            # Attempt to create only if parent directory exists and is not empty
            if ($parentDir -and $parentDir -ne "" -and $parentDir -ne ".") {
                $parentDir = $parentDir -replace "\\\\", "/"
                # Verify parent directory exists
                try {
                    if ($useSasEnv) {
                        az storage directory create --account-name $storageAccountName --share-name $share --name $parentDir --sas-token "`"$sasToken`"" --output none 2>$null
                    } else {
                        az storage directory create --account-name $storageAccountName --share-name $share --name $parentDir --account-key $storageKey --output none 2>$null
                    }
                } catch {
                    # Ignore if directory already exists
                }
            }
            
            # Upload processing 
            $uploadSuccess = $false
            $maxRetries = 3
            $retryCount = 0
            
            while (-not $uploadSuccess -and $retryCount -lt $maxRetries) {
                try {
                    if ($useSasEnv) {
                        $result = az storage file upload --account-name $storageAccountName --share-name $share --source $_.FullName --path $targetPath --sas-token "`"$sasToken`"" --no-progress 2>&1
                    } else {
                        $result = az storage file upload --account-name $storageAccountName --share-name $share --source $_.FullName --path $targetPath --account-key $storageAccountKey --no-progress 2>&1
                    }
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  Uploaded file: $targetPath"
                        $uploadSuccess = $true
                    } else {
                        $retryCount++
                        if ($retryCount -lt $maxRetries) {
                            Write-Host "    Retrying... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                            Start-Sleep -Seconds 2
                        } else {
                            Write-Warning "Error uploading file '$targetPath': $result"
                        }
                    }
                } catch {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Write-Host "    Retrying... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    } else {
                        Write-Warning "Exception while uploading file '$targetPath': $_"
                    }
                }
            }
        }
        # End of az CLI upload section
        }
    } else {
        Write-Host "Warning: $sourcePath directory not found. Skipping files for this share." -ForegroundColor Yellow
    }
}

# Restore storage account security settings after file upload
Write-Host "Restoring storage account security settings..." -ForegroundColor Yellow
if ($clientIP) {
    az storage account network-rule remove --account-name $storageAccountName --resource-group $ResourceGroupName --ip-address $clientIP --output none
}
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --public-network-access Disabled --output none
Write-Host "Storage account locked down." -ForegroundColor Green

# Show VMSS status
Write-Host "Checking VMSS status..." -ForegroundColor Cyan
$vmssName = az vmss list --resource-group $ResourceGroupName --query "[0].name" -o tsv
if ($vmssName) {
    Write-Host "VMSS: $vmssName" -ForegroundColor Green
    az vmss list-instances --resource-group $ResourceGroupName --name $vmssName `
        --query "[].{Instance:instanceId, State:provisioningState, Power:powerState}" -o table
} else {
    Write-Warning "No VMSS found in resource group $ResourceGroupName"
}

Write-Host ""
Write-Host "NOTE: DB migration runs automatically via MIGRATION_ENABLED=true in cloud-init." -ForegroundColor Yellow
Write-Host "      Allow 3-5 minutes for cloud-init to complete on first boot." -ForegroundColor Yellow

# Get endpoint from public LB
Write-Host ""
Write-Host "Dify Endpoints:" -ForegroundColor Cyan
try {
    $publicIp   = az network public-ip show --resource-group $ResourceGroupName --name pip-dify-lb --query "ipAddress" -o tsv
    $publicFqdn = az network public-ip show --resource-group $ResourceGroupName --name pip-dify-lb --query "dnsSettings.fqdn" -o tsv
    if ($publicFqdn) {
        Write-Host "Main URL: http://$publicFqdn" -ForegroundColor Green
    }
    if ($publicIp) {
        Write-Host "IP:       http://$publicIp" -ForegroundColor Green
    }
} catch {
    Write-Warning "Failed to retrieve endpoint: $_"
}

Write-Host "Deployment completed!" -ForegroundColor Green
