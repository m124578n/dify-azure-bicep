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

@description('ACA infrastructure resource group name')
param acaInfraRGName string = 'rg-dify-aca-infra'

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
param acaAppMinCount int = 1

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
param postgresSkuName string = 'Standard_D2s_v3'

@description('PostgreSQL SKU tier')
param postgresSkuTier string = 'GeneralPurpose'

@description('PostgreSQL storage size in GB')
param postgresStorageGB int = 128

@description('Enable PostgreSQL high availability')
param postgresEnableHA bool = true

@description('Azure Managed Redis SKU (Balanced_B1, Balanced_B3, Balanced_B5, Balanced_B10)')
param redisSku string = 'Balanced_B1'

@description('API container CPU')
param apiCpu string = '2'

@description('API container memory')
param apiMemory string = '6Gi'

@description('Worker container CPU')
param workerCpu string = '1'

@description('Worker container memory')
param workerMemory string = '4Gi'

@description('Web container CPU')
param webCpu string = '1'

@description('Web container memory')
param webMemory string = '2Gi'

@description('Dify secret key')
@secure()
param difySecretKey string = 'dify-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U'

@description('Plugin daemon / server shared key')
@secure()
param pluginDaemonKey string = 'lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi'

@description('Inner API key for plugin integration')
@secure()
param innerApiKey string = '-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1'

@description('Sandbox API key')
@secure()
param sandboxApiKey string = 'dify-sandbox'

@description('Allowed origins for Web API CORS')
param webApiCorsAllowOrigins string = '*'

@description('Allowed origins for Console CORS')
param consoleCorsAllowOrigins string = '*'

@description('Nginx container CPU')
param nginxCpu string = '0.5'

@description('Nginx container memory')
param nginxMemory string = '1Gi'

@description('SSRF proxy container CPU')
param ssrfProxyCpu string = '0.5'

@description('SSRF proxy container memory')
param ssrfProxyMemory string = '1Gi'

@description('Sandbox container CPU')
param sandboxCpu string = '1'

@description('Sandbox container memory')
param sandboxMemory string = '3Gi'

@description('Plugin daemon container CPU')
param pluginCpu string = '1'

@description('Plugin daemon container memory')
param pluginMemory string = '3Gi'

@description('Nginx max replicas')
param nginxMaxReplicas int = 10

@description('API max replicas')
param apiMaxReplicas int = 10

@description('Worker max replicas')
param workerMaxReplicas int = 10

@description('Web max replicas')
param webMaxReplicas int = 10

@description('Plugin daemon max replicas')
param pluginMaxReplicas int = 10

@description('Sandbox max replicas')
param sandboxMaxReplicas int = 10

@description('SSRF proxy max replicas')
param ssrfProxyMaxReplicas int = 10

@description('Extra worker max replicas')
param extraWorkerMaxReplicas int = 5

@description('Nginx HTTP concurrent requests scale threshold')
param nginxConcurrentRequests string = '50'

@description('API TCP concurrent requests scale threshold')
param apiConcurrentRequests string = '70'

@description('Worker Redis queue length scale threshold')
param workerQueueLength string = '20'

@description('Web TCP concurrent requests scale threshold')
param webConcurrentRequests string = '50'

@description('Plugin daemon TCP concurrent requests scale threshold')
param pluginConcurrentRequests string = '20'

@description('Sandbox TCP concurrent requests scale threshold')
param sandboxConcurrentRequests string = '4'

@description('SSRF proxy TCP concurrent requests scale threshold')
param ssrfProxyConcurrentRequests string = '20'

@description('Extra worker Redis queue length scale threshold')
param extraWorkerQueueLength string = '20'

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
    redisSku: redisSku
  }
}

// Deploy ACA environment and apps
module acaModule './modules/aca-env.bicep' = {
  name: 'acaEnvDeploy'
params: {
    location: location
    acaInfraRGName: acaInfraRGName
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
    difySecretKey: difySecretKey
    pluginDaemonKey: pluginDaemonKey
    innerApiKey: innerApiKey
    sandboxApiKey: sandboxApiKey
    webApiCorsAllowOrigins: webApiCorsAllowOrigins
    consoleCorsAllowOrigins: consoleCorsAllowOrigins
    nginxCpu: nginxCpu
    nginxMemory: nginxMemory
    ssrfProxyCpu: ssrfProxyCpu
    ssrfProxyMemory: ssrfProxyMemory
    sandboxCpu: sandboxCpu
    sandboxMemory: sandboxMemory
    pluginCpu: pluginCpu
    pluginMemory: pluginMemory
    nginxMaxReplicas: nginxMaxReplicas
    apiMaxReplicas: apiMaxReplicas
    workerMaxReplicas: workerMaxReplicas
    webMaxReplicas: webMaxReplicas
    pluginMaxReplicas: pluginMaxReplicas
    sandboxMaxReplicas: sandboxMaxReplicas
    ssrfProxyMaxReplicas: ssrfProxyMaxReplicas
    extraWorkerMaxReplicas: extraWorkerMaxReplicas
    nginxConcurrentRequests: nginxConcurrentRequests
    apiConcurrentRequests: apiConcurrentRequests
    workerQueueLength: workerQueueLength
    webConcurrentRequests: webConcurrentRequests
    pluginConcurrentRequests: pluginConcurrentRequests
    sandboxConcurrentRequests: sandboxConcurrentRequests
    ssrfProxyConcurrentRequests: ssrfProxyConcurrentRequests
    extraWorkerQueueLength: extraWorkerQueueLength
  }
}

// Post-deployment output
output difyAppUrl string = acaModule.outputs.difyAppUrl
