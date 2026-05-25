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

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('SSH public key for admin user')
param adminSshPublicKey string

@description('VM size for VMSS instances')
param vmSize string = 'Standard_D4s_v3'

@description('VM size for nginx VM')
param nginxVmSize string = 'Standard_B2s'

@description('Initial VMSS instance count')
param vmssInstanceCount int = 2


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

// Deploy load balancers
module lbModule './modules/load-balancer.bicep' = {
  name: 'lbDeploy'
  params: {
    location: location
    nginxSubnetId: vnetModule.outputs.nginxSubnetId
    appSubnetId: vnetModule.outputs.appSubnetId
    internalLbPrivateIp: '${ipPrefix}.2.4'
  }
}

// Deploy nginx VM
module nginxVmModule './modules/nginx-vm.bicep' = {
  name: 'nginxVmDeploy'
  params: {
    location: location
    nginxSubnetId: vnetModule.outputs.nginxSubnetId
    publicLbBackendPoolId: lbModule.outputs.publicLbBackendPoolId
    internalLbIp: lbModule.outputs.internalLbPrivateIp
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    vmSize: nginxVmSize
  }
}

// Deploy VM Scale Set
module vmssModule './modules/vmss.bicep' = {
  name: 'vmssDeploy'
  params: {
    location: location
    appSubnetId: vnetModule.outputs.appSubnetId
    internalLbBackendPoolId: lbModule.outputs.internalLbBackendPoolId
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    vmSize: vmSize
    instanceCount: vmssInstanceCount
    postgresServerFqdn: postgresqlModule.outputs.serverFqdn
    postgresAdminLogin: pgsqlUser
    postgresAdminPassword: pgsqlPassword
    postgresDifyDbName: postgresqlModule.outputs.difyDbName
    postgresVectorDbName: postgresqlModule.outputs.vectorDbName
    redisHostName: redisModule.outputs.redisHostName
    redisPrimaryKey: redisModule.outputs.redisPrimaryKey
    storageAccountName: storageModule.outputs.storageAccountName
    storageAccountKey: storageModule.outputs.storageAccountKey
    storageContainerName: storageAccountContainer
    blobEndpoint: storageModule.outputs.blobEndpoint
    difyApiImage: difyApiImage
    difySandboxImage: difySandboxImage
    difyWebImage: difyWebImage
    difyPluginDaemonImage: difyPluginDaemonImage
  }
}

// Post-deployment output
output difyPublicIp string = lbModule.outputs.publicIpAddress
output difyFqdn string = lbModule.outputs.publicIpFqdn
