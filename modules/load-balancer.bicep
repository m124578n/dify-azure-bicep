@description('Resource group location')
param location string

@description('Subnet ID for app VMSS')
param appSubnetId string

@description('Static private IP for internal load balancer frontend')
param internalLbPrivateIp string

// Public IP for the public load balancer
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: 'pip-dify-lb'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'dify-${uniqueString(resourceGroup().id)}'
    }
  }
}

// Public Load Balancer
resource publicLb 'Microsoft.Network/loadBalancers@2023-05-01' = {
  name: 'lb-dify-public'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend-public'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'pool-nginx'
      }
    ]
    probes: [
      {
        name: 'probe-http'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/nginx-health'
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-http'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', 'lb-dify-public', 'frontend-public')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'lb-dify-public', 'pool-nginx')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', 'lb-dify-public', 'probe-http')
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
        }
      }
      {
        name: 'rule-https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', 'lb-dify-public', 'frontend-public')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'lb-dify-public', 'pool-nginx')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', 'lb-dify-public', 'probe-http')
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// Internal Load Balancer
resource internalLb 'Microsoft.Network/loadBalancers@2023-05-01' = {
  name: 'lb-dify-internal'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend-internal'
        properties: {
          subnet: {
            id: appSubnetId
          }
          privateIPAddress: internalLbPrivateIp
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'pool-vmss'
      }
    ]
    probes: [
      {
        name: 'probe-tcp'
        properties: {
          protocol: 'Tcp'
          port: 80
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-http'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', 'lb-dify-internal', 'frontend-internal')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'lb-dify-internal', 'pool-vmss')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', 'lb-dify-internal', 'probe-tcp')
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

output publicLbId string = publicLb.id
output publicLbBackendPoolId string = resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'lb-dify-public', 'pool-nginx')
output publicIpAddress string = publicIp.properties.ipAddress
output publicIpFqdn string = publicIp.properties.dnsSettings.fqdn
output internalLbId string = internalLb.id
output internalLbBackendPoolId string = resourceId('Microsoft.Network/loadBalancers/backendAddressPools', 'lb-dify-internal', 'pool-vmss')
output internalLbPrivateIp string = internalLbPrivateIp
