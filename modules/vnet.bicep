@description('Resource group location')
param location string

@description('IP prefix')
param ipPrefix string

resource natGatewayPip 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-nat-gateway'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-05-01' = {
  name: 'nat-gateway-app'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      { id: natGatewayPip.id }
    ]
    idleTimeoutInMinutes: 4
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: 'vnet-${location}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '${ipPrefix}.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'PrivateLinkSubnet'
        properties: {
          addressPrefix: '${ipPrefix}.0.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'NginxSubnet'
        properties: {
          addressPrefix: '${ipPrefix}.1.0/24'
        }
      }
      {
        name: 'AppSubnet'
        properties: {
          addressPrefix: '${ipPrefix}.2.0/23'
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: 'PostgresSubnet'
        properties: {
          addressPrefix: '${ipPrefix}.4.0/24'
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
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output privateLinkSubnetId string = vnet.properties.subnets[0].id
output nginxSubnetId string = vnet.properties.subnets[1].id
output appSubnetId string = vnet.properties.subnets[2].id
output postgresSubnetId string = vnet.properties.subnets[3].id
