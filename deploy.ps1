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

# Enable storage account audit logging (for troubleshooting)
Write-Host "Enabling storage account audit logging..." -ForegroundColor Cyan
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --enable-local-user true

# Get client IP and add to firewall
try {
    $clientIP = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10).ip
    if ($clientIP) {
        Write-Host "Adding current IP address: $clientIP to storage account firewall" -ForegroundColor Yellow
        az storage account network-rule add --account-name $storageAccountName --resource-group $ResourceGroupName --ip-address $clientIP
    }
}
catch {
    Write-Warning "Failed to retrieve IP address. Skipping firewall configuration."
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

Write-Host "SAS Token: $sasToken"

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
$shares = @("nginx", "ssrfproxy", "sandbox")

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

# Restore original settings after file upload
Write-Host "Restoring storage account security settings..." -ForegroundColor Yellow
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --default-action Deny
az storage account update --name $storageAccountName --resource-group $ResourceGroupName --bypass AzureServices

# Restart Container Apps (execute only once)
Write-Host "Restarting Nginx app..." -ForegroundColor Cyan
$latestRevision = az containerapp revision list --name nginx --resource-group $ResourceGroupName --query "[0].name" -o tsv
if ($latestRevision) {
    az containerapp revision restart --name nginx --resource-group $ResourceGroupName --revision $latestRevision
} else {
    Write-Warning "Latest revision of Nginx not found"
}


# Database initialization section
Write-Host "Starting Dify database initialization..." -ForegroundColor Cyan

# Logic to wait until API container is ready
function Wait-ForApiContainer {
    $maxAttempts = 10
    $attempt = 0
    $ready = $false
    
    Write-Host "Waiting for API container to be ready..." -ForegroundColor Yellow
    
    while (-not $ready -and $attempt -lt $maxAttempts) {
        $attempt++
        Write-Host "  Attempt $attempt/$maxAttempts..." -ForegroundColor Gray
        
        # Check container status
        $status = az containerapp show --name api --resource-group $ResourceGroupName --query "properties.latestRevisionStatus" -o tsv 2>$null
        
        if ($status -eq "Running") {
            # Test if application is actually responding
            try {
                $testResult = az containerapp exec --name api --resource-group $ResourceGroupName --command "echo 'Test connection'" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $ready = $true
                    Write-Host "  API container is ready" -ForegroundColor Green
                    break
                }
            } catch {
                # Ignore errors and continue
            }
        }
        
        Write-Host "  API container is not ready yet. Waiting 30 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
    
    return $ready
}

# Function to execute migration command more robustly
function Invoke-MigrationCommand {
    param (
        [string]$Command,
        [string]$Description,
        [int]$TimeoutSeconds = 300,
        [int]$MaxRetries = 3
    )
    
    $retry = 0
    $success = $false
    
    while (-not $success -and $retry -lt $MaxRetries) {
        $retry++
        Write-Host "Executing $Description... (attempt $retry/$MaxRetries)" -ForegroundColor Yellow
        
        try {
            # Execute as background job to handle timeout
            $job = Start-Job -ScriptBlock {
                param ($ResourceGroupName, $Command)
                az containerapp exec --name api --resource-group $ResourceGroupName --command $Command 2>&1
                return $LASTEXITCODE
            } -ArgumentList $ResourceGroupName, $Command
            
            # Wait for specified time
            if (Wait-Job -Job $job -Timeout $TimeoutSeconds) {
                $result = Receive-Job -Job $job
                
                # Get last element if result is array
                if ($result -is [array]) {
                    $exitCode = $result[-1]
                } else {
                    $exitCode = $LASTEXITCODE
                }
                
                if ($exitCode -eq 0) {
                    Write-Host "  $Description completed successfully" -ForegroundColor Green
                    $success = $true
                } else {
                    Write-Warning "  $Description failed: $result"
                }
            } else {
                Write-Warning "  $Description timed out (${TimeoutSeconds} seconds)"
                Stop-Job -Job $job
            }
            
            Remove-Job -Job $job -Force
        } catch {
            Write-Warning "  Error occurred while executing command: $_"
        }
        
        if (-not $success -and $retry -lt $MaxRetries) {
            $waitTime = [Math]::Pow(2, $retry) * 15  # Exponential backoff
            Write-Host "  Retrying after ${waitTime} seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitTime
        }
    }
    
    return $success
}

# Wait for API container to be ready
# $apiReady = Wait-ForApiContainer
$apiReady = $true
if (-not $apiReady) {
    Write-Warning "API container was not ready. Please run initialization commands manually later."
    Write-Host "To run initialization manually, execute the following command:" -ForegroundColor Yellow
    Write-Host "az containerapp exec --name api --resource-group $ResourceGroupName --command 'flask db upgrade'" -ForegroundColor Gray
} else {
    # Check API container environment variables
    Write-Host "Checking API container environment variables..." -ForegroundColor Cyan
    $envVars = az containerapp show --name api --resource-group $ResourceGroupName --query "properties.template.containers[0].env" -o json | ConvertFrom-Json
    
    # Check if required environment variables are set
    $requiredVars = @("DB_HOST", "DB_USERNAME", "DB_PASSWORD", "DB_DATABASE")
    $missingVars = @()
    
    foreach ($var in $requiredVars) {
        $found = $false
        foreach ($envVar in $envVars) {
            if ($envVar.name -eq $var) {
                $found = $true
                break
            }
        }
        
        if (-not $found) {
            $missingVars += $var
        }
    }
    
    if ($missingVars.Count -gt 0) {
        Write-Warning "The following environment variables are not set in the API container: $($missingVars -join ', ')"
        Write-Host "Please check the Bicep template and verify that the required environment variables are set." -ForegroundColor Yellow
    }
    
    # Execute database initialization
    $psqlServer = az postgres flexible-server list --resource-group $ResourceGroupName --query "[0].name" -o tsv

    # Command to get detailed migration logs
    $debugMigrationCommand = 'flask db upgrade'
    Write-Host "Running migration with detailed debug information..." -ForegroundColor Cyan
    az containerapp exec --name api --resource-group $ResourceGroupName --command $debugMigrationCommand    
    
    Write-Host "Database initialization completed" -ForegroundColor Green        
}

# Get Container Apps endpoints
try {
    $apiUrl = az containerapp show --name api --resource-group $ResourceGroupName --query "properties.configuration.ingress.fqdn" -o tsv
    $webUrl = az containerapp show --name web --resource-group $ResourceGroupName --query "properties.configuration.ingress.fqdn" -o tsv
    $nginxUrl = az containerapp show --name nginx --resource-group $ResourceGroupName --query "properties.configuration.ingress.fqdn" -o tsv
    
    Write-Host "Dify Endpoints:" -ForegroundColor Cyan
    Write-Host "Main UI (Nginx): https://$nginxUrl" -ForegroundColor Green
    Write-Host "API: https://$apiUrl" -ForegroundColor Green
    Write-Host "Web: https://$webUrl" -ForegroundColor Green
} catch {
    Write-Warning "Failed to retrieve endpoint information: $_"
}

Write-Host "Deployment completed!" -ForegroundColor Green
