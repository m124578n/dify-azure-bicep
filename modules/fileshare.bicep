param storageAccountName string
param shareName string
param quota int = 50

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: storageAccountName
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2022-05-01' = {
  name: 'default'
  parent: storageAccount
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2022-05-01' = {
  name: shareName
  parent: fileService
  properties: {
    shareQuota: quota
  }
}

// File upload to file share is not directly supported in Bicep,
// so it must be executed with a post-deployment script or Azure CLI command

output shareName string = fileShare.name
output shareId string = fileShare.id
