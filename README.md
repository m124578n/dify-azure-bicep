## dify-azure-bicep
Deploy [langgenius/dify](https://github.com/langgenius/dify), an LLM based chat bot app on Azure with Bicep.

> **Note**: This repository rewrites the contents of [dify-azure-terraform](https://github.com/nikawang/dify-azure-terraform) in Bicep and supports **Dify v1.10.1-fix.1**.

### Topology
Front-end access:
- nginx -> Azure Container Apps (Serverless)

Back-end components:
- web -> Azure Container Apps (Serverless)
- api -> Azure Container Apps (Serverless)
- worker -> Azure Container Apps (Serverless)
- sandbox -> Azure Container Apps (Serverless)
- ssrf_proxy -> Azure Container Apps (Serverless)
- db -> Azure Database for PostgreSQL
- vectordb -> Azure Database for PostgreSQL
- redis -> Azure Cache for Redis

Before you provision Dify, please check and set the variables in your parameters file.

### ⚠️ Security Notice

**IMPORTANT**: The parameters file contains sensitive information such as database passwords and certificate passwords.

Before deploying:

1. **Copy the example file**:
   ```bash
   cp parameters.example.json parameters.json
   ```

2. **Set secure passwords**: Edit `parameters.json` and replace the placeholder values with your own secure passwords:
   - `pgsqlPassword`: PostgreSQL database password (minimum 8 characters, must include uppercase, lowercase, and numbers)
   - `acaCertPassword`: Certificate password (only required if `isProvidedCert` is `true`)

3. **Do NOT commit** the `parameters.json` file to version control. It is already included in `.gitignore`.

**Password Requirements**:
- Use unique, strong passwords for each deployment
- Do not reuse passwords across environments
- Consider using a password manager to generate and store secure passwords

### Kick Start

```powershell
az login
az account set --subscription <subscription-id>

# Copy and configure parameters file
cp parameters.example.json parameters.json
# Edit parameters.json with your secure passwords and settings

# Deploy to dev environment (default)
./deploy.ps1

# Deploy to prod environment
./deploy.ps1 -Environment prod

# Skip Bicep deployment (resource group setup only)
./deploy.ps1 -SkipDeploy
```

The script automatically creates the resource group and the ACA infrastructure resource group before deployment.

### Deployment Parameters

#### Region

- **Parameter Name**: `location`
- **Type**: `string`
- **Default Value**: `japaneast`

### Network Parameters

#### VNET Address IP Prefix

- **Parameter Name**: `ipPrefix`
- **Type**: `string`
- **Default Value**: `10.99`

#### Storage Account

- **Parameter Name**: `storageAccountBase`
- **Type**: `string`
- **Default Value**: `acadifytest`

#### Storage Account Container

- **Parameter Name**: `storageAccountContainer`
- **Type**: `string`
- **Default Value**: `dfy`

### Redis

- **Parameter Name**: `redisNameBase`
- **Type**: `string`
- **Default Value**: `acadifyredis`

- **Parameter Name**: `redisCapacity`
- **Type**: `int`
- **Default Value**: `0` (250MB)
- **Note**: 0=250MB, 1=1GB, 2=6GB, 3=13GB

#### PostgreSQL Flexible Server

- **Parameter Name**: `psqlFlexibleBase`
- **Type**: `string`
- **Default Value**: `acadifypsql`

#### PostgreSQL User

- **Parameter Name**: `pgsqlUser`
- **Type**: `string`
- **Default Value**: `adminuser`

#### PostgreSQL Password

- **Parameter Name**: `pgsqlPassword`
- **Type**: `string` (secure)
- **Default Value**: *(empty — must be set)*
- **Note**: **Must be set before deployment.** Use a strong password with at least 8 characters including uppercase, lowercase, and numbers.

#### PostgreSQL SKU

- **Parameter Name**: `postgresSkuName`
- **Type**: `string`
- **Default Value**: `Standard_B1ms`

- **Parameter Name**: `postgresSkuTier`
- **Type**: `string`
- **Default Value**: `Burstable`

#### PostgreSQL Storage

- **Parameter Name**: `postgresStorageGB`
- **Type**: `int`
- **Default Value**: `32`

#### PostgreSQL High Availability

- **Parameter Name**: `postgresEnableHA`
- **Type**: `bool`
- **Default Value**: `false`

### ACA Environment Parameters

#### ACA Environment

- **Parameter Name**: `acaEnvName`
- **Type**: `string`
- **Default Value**: `dify-aca-env`

#### ACA Log Analytics Workspace

- **Parameter Name**: `acaLogaName`
- **Type**: `string`
- **Default Value**: `dify-loga`

#### ACA App Minimum Instance Count

- **Parameter Name**: `acaAppMinCount`
- **Type**: `int`
- **Default Value**: `0`

#### Enable ACA (Redis conditional deployment)

- **Parameter Name**: `isAcaEnabled`
- **Type**: `bool`
- **Default Value**: `false`
- **Note**: Set to `true` to deploy Azure Cache for Redis

#### IF BRING YOUR OWN CERTIFICATE

- **Parameter Name**: `isProvidedCert`
- **Type**: `bool`
- **Default Value**: `false`

##### ACA Certificate (if isProvidedCert is true)

- **Parameter Name**: `acaCertBase64Value`
- **Type**: `string` (secure)
- **Default Value**: *(empty)*

##### ACA Certificate Password (if isProvidedCert is true)

- **Parameter Name**: `acaCertPassword`
- **Type**: `string` (secure)
- **Default Value**: *(empty)*
- **Note**: Only required if `isProvidedCert` is `true`.

##### ACA Dify Custom Domain

- **Parameter Name**: `acaDifyCustomerDomain`
- **Type**: `string`
- **Default Value**: `dify.example.com`

#### Container Images

- **Parameter Name**: `difyApiImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-api:1.10.1-fix.1`

- **Parameter Name**: `difySandboxImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-sandbox:0.2.12`

- **Parameter Name**: `difyWebImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-web:1.10.1-fix.1`

- **Parameter Name**: `difyPluginDaemonImage`
- **Type**: `string`
- **Default Value**: `langgenius/dify-plugin-daemon:0.4.1-local`

#### Container Resources

| Parameter | Default | Description |
|-----------|---------|-------------|
| `apiCpu` | `2` | API container CPU cores |
| `apiMemory` | `4Gi` | API container memory |
| `workerCpu` | `2` | Worker container CPU cores |
| `workerMemory` | `4Gi` | Worker container memory |
| `webCpu` | `1` | Web container CPU cores |
| `webMemory` | `2Gi` | Web container memory |
