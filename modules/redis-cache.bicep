@description('Resource location')
param location string

@description('Redis name')
param redisName string

@description('Private link subnet ID')
param privateLinkSubnetId string

@description('Virtual network ID')
param vnetId string

@description('Azure Managed Redis SKU (Balanced_B1, Balanced_B3, Balanced_B5, Balanced_B10)')
param redisSku string = 'Balanced_B1'

// Private DNS zone
resource redisDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.azure.net'
  location: 'global'
}

// Virtual network link
resource redisVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'redis-dns-link'
  parent: redisDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// Azure Managed Redis instance
resource redisEnterprise 'Microsoft.Cache/redisEnterprise@2025-04-01' = {
  name: redisName
  location: location
  sku: {
    name: redisSku
  }
  properties: {
    minimumTlsVersion: '1.2'
  }
}

// Redis database (Azure Managed Redis only supports a single database, index 0)
resource redisDb 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' = {
  name: 'default'
  parent: redisEnterprise
  properties: {
    clientProtocol: 'Encrypted'
    evictionPolicy: 'AllKeysLRU'
    clusteringPolicy: 'EnterpriseCluster'
    port: 10000
  }
}

// Private endpoint
resource redisPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-redis'
  location: location
  properties: {
    subnet: {
      id: privateLinkSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-redis'
        properties: {
          privateLinkServiceId: redisEnterprise.id
          groupIds: [
            'redisEnterprise'
          ]
        }
      }
    ]
  }
}

// Private endpoint DNS group
resource privateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  name: 'pdz-redis'
  parent: redisPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: redisDnsZone.id
        }
      }
    ]
  }
}

// Output
output redisHostName string = redisEnterprise.properties.hostName
#disable-next-line outputs-should-not-contain-secrets
output redisPrimaryKey string = redisDb.listKeys().primaryKey
