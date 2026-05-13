@description('Resource group location')
param location string

@description('IP prefix')
param ipPrefix string

// Create virtual network
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vnet-${location}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '${ipPrefix}.0.0/16'
      ]
    }
  }
}

// Private link subnet
resource privateLinkSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  name: 'PrivateLinkSubnet'
  parent: vnet
  properties: {
    addressPrefix: '${ipPrefix}.0.0/24'  // Changed to 10.99.0.0/24
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

// ACA subnet (/23 is equivalent to two consecutive /24)
resource acaSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  name: 'ACASubnet'
  parent: vnet
  properties: {
    addressPrefix: '${ipPrefix}.2.0/23'  // 10.99.2.0/23 (range of 10.99.2.0/24 + 10.99.3.0/24)
    delegations: [
      {
        name: 'aca-delegation'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
  }
  dependsOn: [
    privateLinkSubnet
  ]
}

// PostgreSQL subnet
resource postgresSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' = {
  name: 'PostgresSubnet'
  parent: vnet
  properties: {
    addressPrefix: '${ipPrefix}.4.0/24'  // Changed to 10.99.4.0/24 (changed to avoid overlap with ACASubnet)
    serviceEndpoints: [
      {
        service: 'Microsoft.Storage'
      }
    ]
    delegations: [
      {
        name: 'postgres-delegation'
        properties: {
          serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
        }
      }
    ]
  }
  dependsOn: [
    acaSubnet
  ]
}

// Output
output vnetId string = vnet.id
output vnetName string = vnet.name
output privateLinkSubnetId string = privateLinkSubnet.id
output acaSubnetId string = acaSubnet.id
output postgresSubnetId string = postgresSubnet.id
