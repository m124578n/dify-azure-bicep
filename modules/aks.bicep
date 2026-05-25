@description('Resource group location')
param location string

@description('AKS subnet ID (Azure CNI)')
param aksSubnetId string

@description('VM size for AKS nodes')
param nodeSize string = 'Standard_D4s_v3'

@description('Initial node count')
param nodeCount int = 2

@description('Minimum node count for auto-scaling')
param minNodeCount int = 2

@description('Maximum node count for auto-scaling')
param maxNodeCount int = 10

var rgNameHex = uniqueString(resourceGroup().id)

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: 'aks-dify-${rgNameHex}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: 'dify-${rgNameHex}'
    agentPoolProfiles: [
      {
        name: 'system'
        count: nodeCount
        vmSize: nodeSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'System'
        vnetSubnetID: aksSubnetId
        maxPods: 30
        enableAutoScaling: true
        minCount: minNodeCount
        maxCount: maxNodeCount
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
    }
  }
}

output aksClusterName string = aksCluster.name
output aksClusterId string = aksCluster.id
output aksPrincipalId string = aksCluster.identity.principalId
