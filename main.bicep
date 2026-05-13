targetScope = 'resourceGroup'

@description('Region to deploy')
param location string = 'japaneast'

@description('IP address prefix')
param ipPrefix string = '10.99'

@description('Storage account name base')
param storageAccountBase string = 'acadifytest'

@description('Storage account container name')
param storageAccountContainer string = 'dfy'

@description('Redis name base')
param redisNameBase string = 'acadifyredis'

@description('PostgreSQL name base')
param psqlFlexibleBase string = 'acadifypsql'

@description('PostgreSQL user name')
param pgsqlUser string = 'user'

@description('PostgreSQL password')
@secure()
param pgsqlPassword string = ''

@description('ACA environment name')
param acaEnvName string = 'dify-aca-env'

@description('ACA Log Analytics workspace name')
param acaLogaName string = 'dify-loga'

@description('Whether to provide a custom certificate')
param isProvidedCert bool = true

@description('Certificate content (Base64 encoded)')
@secure()
param acaCertBase64Value string = ''

@description('Certificate password')
@secure()
param acaCertPassword string = ''

@description('Dify custom domain')
param acaDifyCustomerDomain string = 'dify.example.com'

@description('Minimum instance count for ACA app')
param acaAppMinCount int = 0

@description('Whether to enable ACA')
param isAcaEnabled bool = false

@description('Dify API image')
param difyApiImage string = 'langgenius/dify-api:1.10.1-fix.1'

@description('Dify sandbox image')
param difySandboxImage string = 'langgenius/dify-sandbox:0.2.12'

@description('Dify web image')
param difyWebImage string = 'langgenius/dify-web:1.10.1-fix.1'

@description('Dify plugin daemon image')
param difyPluginDaemonImage string = 'langgenius/dify-plugin-daemon:0.4.1-local'

@description('PostgreSQL SKU name')
param postgresSkuName string = 'Standard_B1ms'

@description('PostgreSQL SKU tier')
param postgresSkuTier string = 'Burstable'

@description('PostgreSQL storage size in GB')
param postgresStorageGB int = 32

@description('Enable PostgreSQL high availability')
param postgresEnableHA bool = false

@description('Redis cache capacity (0=250MB, 1=1GB, 2=6GB, 3=13GB)')
param redisCapacity int = 0

@description('API container CPU')
param apiCpu string = '2'

@description('API container memory')
param apiMemory string = '4Gi'

@description('Worker container CPU')
param workerCpu string = '2'

@description('Worker container memory')
param workerMemory string = '4Gi'

@description('Web container CPU')
param webCpu string = '1'

@description('Web container memory')
param webMemory string = '2Gi'


// Generate hash for unique resource names
var rgNameHex = uniqueString(resourceGroup().id)

// Deploy network-related resources
module vnetModule './modules/vnet.bicep' = {
  name: 'vnetDeploy'
params: {
    location: location
    ipPrefix: ipPrefix
  }
}

// Deploy storage account and file share
module storageModule './modules/storage.bicep' = {
  name: 'storageDeploy'
params: {
    location: location
    storageAccountName: '${storageAccountBase}${rgNameHex}'
    containerName: storageAccountContainer
    privateLinkSubnetId: vnetModule.outputs.privateLinkSubnetId
    vnetId: vnetModule.outputs.vnetId
  }
}

// Deploy file shares
module nginxFileShareModule './modules/fileshare.bicep' = {
  name: 'nginxFileShareDeploy'
params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'nginx'
  }
}

module sandboxFileShareModule './modules/fileshare.bicep' = {
  name: 'sandboxFileShareDeploy'
params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'sandbox'
  }
}

module ssrfProxyFileShareModule './modules/fileshare.bicep' = {
  name: 'ssrfProxyFileShareDeploy'
params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'ssrfproxy'
  }
}

module pluginStorageFileShareModule './modules/fileshare.bicep' = {
  name: 'pluginStorageFileShareDeploy'
params: {
    storageAccountName: storageModule.outputs.storageAccountName
    shareName: 'pluginstorage'
  }
}

// Deploy PostgreSQL server
module postgresqlModule './modules/postgresql.bicep' = {
  name: 'postgresqlDeploy'
params: {
    location: location
    serverName: '${psqlFlexibleBase}${rgNameHex}'
    administratorLogin: pgsqlUser
    administratorLoginPassword: pgsqlPassword
    postgresSubnetId: vnetModule.outputs.postgresSubnetId
    vnetId: vnetModule.outputs.vnetId
    postgresSkuName: postgresSkuName
    postgresSkuTier: postgresSkuTier
    postgresStorageGB: postgresStorageGB
    postgresEnableHA: postgresEnableHA
  }
}

// Deploy Redis cache (conditional)
module redisModule './modules/redis-cache.bicep' = if (isAcaEnabled) {
  name: 'redisDeploy'
params: {
    location: location
    redisName: '${redisNameBase}${rgNameHex}'
    privateLinkSubnetId: vnetModule.outputs.privateLinkSubnetId
    vnetId: vnetModule.outputs.vnetId
    redisCapacity: redisCapacity
  }
}

// Deploy ACA environment and apps
module acaModule './modules/aca-env.bicep' = {
  name: 'acaEnvDeploy'
params: {
    location: location
    acaEnvName: acaEnvName
    acaLogaName: acaLogaName
    acaSubnetId: vnetModule.outputs.acaSubnetId
    isProvidedCert: isProvidedCert
    acaCertBase64Value: acaCertBase64Value
    acaCertPassword: acaCertPassword
    acaDifyCustomerDomain: acaDifyCustomerDomain
    acaAppMinCount: acaAppMinCount
    storageAccountName: storageModule.outputs.storageAccountName
    storageAccountKey: storageModule.outputs.storageAccountKey
    storageContainerName: storageAccountContainer
    nginxShareName: nginxFileShareModule.outputs.shareName
    sandboxShareName: sandboxFileShareModule.outputs.shareName
    ssrfProxyShareName: ssrfProxyFileShareModule.outputs.shareName
    pluginStorageShareName: pluginStorageFileShareModule.outputs.shareName
    postgresServerFqdn: postgresqlModule.outputs.serverFqdn
    postgresAdminLogin: pgsqlUser
    postgresAdminPassword: pgsqlPassword
    postgresDifyDbName: postgresqlModule.outputs.difyDbName
    postgresVectorDbName: postgresqlModule.outputs.vectorDbName
    redisHostName: redisModule.?outputs.redisHostName ?? ''
    redisPrimaryKey: redisModule.?outputs.redisPrimaryKey ?? ''
    difyApiImage: difyApiImage
    difySandboxImage: difySandboxImage
    difyWebImage: difyWebImage
    difyPluginDaemonImage: difyPluginDaemonImage
    blobEndpoint: storageModule.outputs.blobEndpoint
    apiCpu: apiCpu
    apiMemory: apiMemory
    workerCpu: workerCpu
    workerMemory: workerMemory
    webCpu: webCpu
    webMemory: webMemory
  }
}

// Post-deployment output
output difyAppUrl string = acaModule.outputs.difyAppUrl
