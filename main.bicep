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

@description('VM size for AKS nodes')
param aksNodeSize string = 'Standard_D4s_v3'

@description('Initial AKS node count')
param aksNodeCount int = 2

@description('Minimum AKS node count for auto-scaling')
param aksMinNodeCount int = 2

@description('Maximum AKS node count for auto-scaling')
param aksMaxNodeCount int = 10


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

// Deploy Redis cache
module redisModule './modules/redis-cache.bicep' = {
  name: 'redisDeploy'
  params: {
    location: location
    redisName: '${redisNameBase}${rgNameHex}'
    privateLinkSubnetId: vnetModule.outputs.privateLinkSubnetId
    vnetId: vnetModule.outputs.vnetId
    redisCapacity: redisCapacity
  }
}

// Deploy AKS cluster
module aksModule './modules/aks.bicep' = {
  name: 'aksDeploy'
  params: {
    location: location
    aksSubnetId: vnetModule.outputs.aksSubnetId
    nodeSize: aksNodeSize
    nodeCount: aksNodeCount
    minNodeCount: aksMinNodeCount
    maxNodeCount: aksMaxNodeCount
  }
}

// Post-deployment output
output aksClusterName string = aksModule.outputs.aksClusterName
output postgresServerFqdn string = postgresqlModule.outputs.serverFqdn
output redisHostName string = redisModule.outputs.redisHostName
output storageAccountName string = storageModule.outputs.storageAccountName
output blobEndpoint string = storageModule.outputs.blobEndpoint
