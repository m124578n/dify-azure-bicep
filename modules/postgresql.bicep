@description('Resource location')
param location string

@description('PostgreSQL server name')
param serverName string

@description('PostgreSQL administrator login')
param administratorLogin string

@description('PostgreSQL administrator password')
@secure()
param administratorLoginPassword string

@description('PostgreSQL subnet ID')
param postgresSubnetId string

@description('Virtual network ID')
param vnetId string

@description('PostgreSQL SKU name')
param postgresSkuName string = 'Standard_B1ms'

@description('PostgreSQL SKU tier')
param postgresSkuTier string = 'Burstable'

@description('PostgreSQL storage size in GB')
param postgresStorageGB int = 32

@description('Enable high availability')
param postgresEnableHA bool = false

// Private DNS zone
resource postgresDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
}

// Virtual network link
resource postgresVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'postgres-dns-link'
  parent: postgresDnsZone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

// PostgreSQL Flexible Server
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2022-12-01' = {
  name: serverName
  location: location
  sku: {
    name: postgresSkuName
    tier: postgresSkuTier
  }
  properties: {
    version: '14'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    storage: {
      storageSizeGB: postgresStorageGB
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: postgresSubnetId
      privateDnsZoneArmResourceId: postgresDnsZone.id
    }
    highAvailability: {
      mode: postgresEnableHA ? 'ZoneRedundant' : 'Disabled'
    }
  }
}

// Dify database
resource difyDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2022-12-01' = {
  name: 'dify'
  parent: postgresServer
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Vector database
resource vectorDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2022-12-01' = {
  name: 'vector'
  parent: postgresServer
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// PGVector extension configuration
resource pgVectorConfig 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2022-12-01' = {
  name: 'azure.extensions'
  parent: postgresServer
  dependsOn: [
    difyDatabase
    vectorDatabase
  ]
  properties: {
    value: 'uuid-ossp,vector'
    source: 'user-override'
  }
}

// Output
output serverFqdn string = postgresServer.properties.fullyQualifiedDomainName
output difyDbName string = difyDatabase.name
output vectorDbName string = vectorDatabase.name
