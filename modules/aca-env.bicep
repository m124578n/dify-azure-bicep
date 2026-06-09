@description('Resource location')
param location string

@description('ACA infrastructure resource group name')
param acaInfraRGName string

@description('ACA Log Analytics workspace name')
param acaLogaName string

@description('ACA environment name')
param acaEnvName string

@description('ACA subnet ID')
param acaSubnetId string

@description('Storage account name')
param storageAccountName string

@description('Storage account key')
@secure()
param storageAccountKey string

@description('Storage container name')
param storageContainerName string

@description('Redis host name')
param redisHostName string = ''

@description('Redis primary key')
@secure()
param redisPrimaryKey string = ''

@description('PostgreSQL server fully qualified domain name')
param postgresServerFqdn string

@description('PostgreSQL administrator login')
param postgresAdminLogin string

@description('PostgreSQL administrator password')
@secure()
param postgresAdminPassword string

@description('Postgres Dify database name')
param postgresDifyDbName string

@description('Postgres Vector database name')
param postgresVectorDbName string

@description('Nginx file share name')
param nginxShareName string

@description('SSRF proxy file share name')
param ssrfProxyShareName string

@description('Sandbox file share name')
param sandboxShareName string

@description('Plugin file share name')
param pluginStorageShareName string

@description('Whether to provide a custom certificate')
param isProvidedCert bool = false

@description('Certificate content (Base64 encoded)')
@secure()
param acaCertBase64Value string = ''

@description('Certificate password')
@secure()
param acaCertPassword string = ''

@description('Dify custom domain')
param acaDifyCustomerDomain string = ''

@description('ACA app minimum instance count')
param acaAppMinCount int = 0

@description('API container CPU')
param apiCpu string = '2'

@description('API container memory')
param apiMemory string = '4Gi'

@description('Worker container CPU')
param workerCpu string = '2'

@description('Worker container memory')
param workerMemory string = '4Gi'

@description('Web container CPU')
param webCpu string = '1'

@description('Web container memory')
param webMemory string = '2Gi'

@description('Dify API image')
param difyApiImage string

@description('Dify Sandbox image')
param difySandboxImage string

@description('Dify Web image')
param difyWebImage string

@description('Dify Plugin Daemon image')
param difyPluginDaemonImage string

@description('Blob endpoint')
param blobEndpoint string

@description('Dify secret key')
@secure()
param difySecretKey string

@description('Plugin daemon / server shared key')
@secure()
param pluginDaemonKey string

@description('Inner API key shared between api/worker and plugin daemon')
@secure()
param innerApiKey string

@description('Sandbox API key (CODE_EXECUTION_API_KEY / API_KEY)')
@secure()
param sandboxApiKey string

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
param sandboxCpu string = '0.5'

@description('Sandbox container memory')
param sandboxMemory string = '1Gi'

@description('Plugin daemon container CPU')
param pluginCpu string = '2'

@description('Plugin daemon container memory')
param pluginMemory string = '4Gi'

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
param apiConcurrentRequests string = '10'

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

// Create Log Analytics workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: acaLogaName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Create ACA environment
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: acaEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
    infrastructureResourceGroup: acaInfraRGName
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnetId
      internal: false
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      {
        name: 'D8'
        workloadProfileType: 'D8'
        minimumCount: 1
        maximumCount: 5
      }
    ]
  }
}

// Mount Nginx file share to ACA environment
resource nginxFileShare 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  name: 'nginxshare'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: nginxShareName
      accessMode: 'ReadWrite'
    }
  }
}

// Add certificate to ACA environment (conditional)
resource difyCerts 'Microsoft.App/managedEnvironments/certificates@2024-03-01' = if (isProvidedCert) {
  name: 'difycerts'
  parent: acaEnv
  location: location
  properties: {
    password: acaCertPassword
    value: acaCertBase64Value
  }
}

// Change Nginx app resource definition
resource nginxApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'nginx'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'D8'
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
        customDomains: isProvidedCert ? [
          {
            name: acaDifyCustomerDomain
            certificateId: difyCerts.id
          }
        ] : []
      }
    }
    template: {
      containers: [
        {
          name: 'nginx'
          image: 'nginx:latest'
          resources: {
            cpu: json(nginxCpu)
            memory: nginxMemory
          }
          volumeMounts: [
            {
              volumeName: 'nginxconf'
              mountPath: '/custom-nginx' // Change mount point
            }
          ]
          command: [
            '/bin/bash'
            '-c'
            'rm -rf /etc/nginx/modules && cp -rf /custom-nginx/* /etc/nginx/ && nginx -g "daemon off;"'
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: nginxMaxReplicas
        rules: [
          {
            name: 'nginx'
            http: {
              metadata: {
                concurrentRequests: nginxConcurrentRequests
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'nginxconf'
          storageType: 'AzureFile'
          storageName: nginxFileShare.name
        }
      ]
    }
  }
}

// Mount SSRF proxy file share to ACA environment
resource ssrfProxyFileShare 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  name: 'ssrfproxyfileshare'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: ssrfProxyShareName
      accessMode: 'ReadWrite'
    }
  }
}

// Deploy SSRF proxy app
resource ssrfProxyApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ssrfproxy'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'D8'
    configuration: {
      ingress: {
        external: false
        targetPort: 3128
        transport: 'auto'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'ssrfproxy'
          image: 'ubuntu/squid:latest'
          resources: {
            cpu: json(ssrfProxyCpu)
            memory: ssrfProxyMemory
          }
          volumeMounts: [
            {
              volumeName: 'ssrfproxy'
              mountPath: '/etc/squid'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: ssrfProxyMaxReplicas
        rules: [
          {
            name: 'ssrfproxy'
            tcp: {
              metadata: {
                concurrentRequests: ssrfProxyConcurrentRequests
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'ssrfproxy'
          storageType: 'AzureFile'
          storageName: ssrfProxyFileShare.name
        }
      ]
    }
  }
}

// Mount Sandbox file share to ACA environment
resource sandboxFileShare 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  name: 'sandbox'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: sandboxShareName
      accessMode: 'ReadWrite'
    }
  }
}

// Deploy Sandbox app
resource sandboxApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'sandbox'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'D8'
    configuration: {
      ingress: {
        external: false
        targetPort: 8194
        exposedPort: 8194
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difySandboxImage
          resources: {
            cpu: json(sandboxCpu)
            memory: sandboxMemory
          }
          env: [
            {
              name: 'API_KEY'
              value: sandboxApiKey
            }
            {
              name: 'GIN_MODE'
              value: 'release'
            }
            {
              name: 'WORKER_TIMEOUT'
              value: '15'
            }
            {
              name: 'ENABLE_NETWORK'
              value: 'true'
            }
            {
              name: 'HTTP_PROXY'
              value: 'http://ssrfproxy:3128'
            }
            {
              name: 'HTTPS_PROXY'
              value: 'http://ssrfproxy:3128'
            }
            {
              name: 'SANDBOX_PORT'
              value: '8194'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'sandbox'
              mountPath: '/dependencies'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: sandboxMaxReplicas
        rules: [
          {
            name: 'sandbox'
            tcp: {
              metadata: {
                concurrentRequests: sandboxConcurrentRequests
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'sandbox'
          storageType: 'AzureFile'
          storageName: sandboxFileShare.name
        }
      ]
    }
  }
}

// Deploy Worker app
resource workerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'worker'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'D8'
    configuration: {
      secrets: [
        {
          name: 'redis-password'
          value: redisPrimaryKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyApiImage
          resources: {
            cpu: json(workerCpu)
            memory: workerMemory
          }
          env: [
            {
              name: 'MODE'
              value: 'worker'
            }
            {
              name: 'LOG_LEVEL'
              value: 'INFO'
            }
            {
              name: 'SECRET_KEY'
              value: difySecretKey
            }
            {
              name: 'DB_USERNAME'
              value: postgresAdminLogin
            }
            {
              name: 'DB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'DB_PORT'
              value: '6432'
            }
            {
              name: 'DB_DATABASE'
              value: postgresDifyDbName
            }
            {
              name: 'REDIS_HOST'
              value: redisHostName
            }
            {
              name: 'REDIS_PORT'
              value: '10000'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'true'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'rediss://:${redisPrimaryKey}@${redisHostName}:10000/0'
            }
            {
              name: 'STORAGE_TYPE'
              value: 'azure-blob'
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_NAME'
              value: storageAccountName
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_KEY'
              value: storageAccountKey
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_URL'
              value: blobEndpoint
            }
            {
              name: 'AZURE_BLOB_CONTAINER_NAME'
              value: storageContainerName
            }
            {
              name: 'VECTOR_STORE'
              value: 'pgvector'
            }
            {
              name: 'PGVECTOR_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'PGVECTOR_PORT'
              value: '6432'
            }
            {
              name: 'PGVECTOR_USER'
              value: postgresAdminLogin
            }
            {
              name: 'PGVECTOR_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'PGVECTOR_DATABASE'
              value: postgresVectorDbName
            }
            {
              name: 'INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH'
              value: '1000'
            }
            {
              name: 'PLUGIN_DAEMON_URL'
              value: 'http://plugin:5002'
            }
            {
              name: 'PLUGIN_DAEMON_KEY'
              value: pluginDaemonKey
            }
            {
              name: 'INNER_API_KEY_FOR_PLUGIN'
              value: innerApiKey
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: workerMaxReplicas
        rules: [
          {
            name: 'worker-celery-queue'
            custom: {
              type: 'redis'
              metadata: {
                address: '${redisHostName}:10000'
                listName: 'celery'
                listLength: workerQueueLength
                databaseIndex: '0'
                useTLS: 'true'
              }
              auth: [
                {
                  secretRef: 'redis-password'
                  triggerParameter: 'password'
                }
              ]
            }
          }
        ]
      }
    }
  }
}

// Deploy API app
resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'api'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'D8'
    configuration: {
      ingress: {
        external: false
        targetPort: 5001
        exposedPort: 5001
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyApiImage
          resources: {
            cpu: json(apiCpu)
            memory: apiMemory
          }
          env: [
            {
              name: 'MODE'
              value: 'api'
            }
            {
              name: 'LOG_LEVEL'
              value: 'INFO'
            }
            {
              name: 'SECRET_KEY'
              value: difySecretKey
            }
            {
              name: 'CONSOLE_WEB_URL'
              value: ''
            }
            {
              name: 'INIT_PASSWORD'
              value: ''
            }
            {
              name: 'CONSOLE_API_URL'
              value: ''
            }
            {
              name: 'SERVICE_API_URL'
              value: ''
            }
            {
              name: 'APP_WEB_URL'
              value: ''
            }
            {
              name: 'FILES_URL'
              value: ''
            }
            {
              name: 'FILES_ACCESS_TIMEOUT'
              value: '300'
            }
            {
              name: 'MIGRATION_ENABLED'
              value: 'true'
            }
            {
              name: 'SERVER_WORKER_AMOUNT'
              value: '2'
            }
            {
              name: 'SENTRY_DSN'
              value: ''
            }
            {
              name: 'SENTRY_TRACES_SAMPLE_RATE'
              value: '1.0'
            }
            {
              name: 'SENTRY_PROFILES_SAMPLE_RATE'
              value: '1.0'
            }
            {
              name: 'DB_USERNAME'
              value: postgresAdminLogin
            }
            {
              name: 'DB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'DB_PORT'
              value: '6432'
            }
            {
              name: 'DB_DATABASE'
              value: postgresDifyDbName
            }
            {
              name: 'WEB_API_CORS_ALLOW_ORIGINS'
              value: webApiCorsAllowOrigins
            }
            {
              name: 'CONSOLE_CORS_ALLOW_ORIGINS'
              value: consoleCorsAllowOrigins
            }
            {
              name: 'REDIS_HOST'
              value: redisHostName
            }
            {
              name: 'REDIS_PORT'
              value: '10000'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'true'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'rediss://:${redisPrimaryKey}@${redisHostName}:10000/0'
            }
            {
              name: 'STORAGE_TYPE'
              value: 'azure-blob'
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_NAME'
              value: storageAccountName
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_KEY'
              value: storageAccountKey
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_URL'
              value: blobEndpoint
            }
            {
              name: 'AZURE_BLOB_CONTAINER_NAME'
              value: storageContainerName
            }
            {
              name: 'VECTOR_STORE'
              value: 'pgvector'
            }
            {
              name: 'PGVECTOR_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'PGVECTOR_PORT'
              value: '6432'
            }
            {
              name: 'PGVECTOR_USER'
              value: postgresAdminLogin
            }
            {
              name: 'PGVECTOR_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'PGVECTOR_DATABASE'
              value: postgresVectorDbName
            }
            {
              name: 'CODE_EXECUTION_API_KEY'
              value: sandboxApiKey
            }
            {
              name: 'CODE_EXECUTION_ENDPOINT'
              value: 'http://sandbox:8194'
            }
            {
              name: 'CODE_MAX_NUMBER'
              value: '9223372036854775807'
            }
            {
              name: 'CODE_MIN_NUMBER'
              value: '-9223372036854775808'
            }
            {
              name: 'CODE_MAX_STRING_LENGTH'
              value: '80000'
            }
            {
              name: 'TEMPLATE_TRANSFORM_MAX_LENGTH'
              value: '80000'
            }
            {
              name: 'CODE_MAX_OBJECT_ARRAY_LENGTH'
              value: '30'
            }
            {
              name: 'CODE_MAX_STRING_ARRAY_LENGTH'
              value: '30'
            }
            {
              name: 'CODE_MAX_NUMBER_ARRAY_LENGTH'
              value: '1000'
            }
            {
              name: 'INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH'
              value: '1000'
            }
            {
              name: 'PLUGIN_DAEMON_URL'
              value: 'http://plugin:5002'
            }
            {
              name: 'PLUGIN_DAEMON_KEY'
              value: pluginDaemonKey
            }
            {
              name: 'INNER_API_KEY_FOR_PLUGIN'
              value: innerApiKey
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: apiMaxReplicas
        rules: [
          {
            name: 'api'
            tcp: {
              metadata: {
                concurrentRequests: apiConcurrentRequests
              }
            }
          }
        ]
      }
    }
  }
}

// Mount Plugin file share to ACA environment
resource pluginstorageFileShare 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  name: 'pluginstoragefileshare'
  parent: acaEnv
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: pluginStorageShareName
      accessMode: 'ReadWrite'
    }
  }
}

// Deploy Plugin daemon app
resource pluginDaemonApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'plugin'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'D8'
    configuration: {
      ingress: {
        external: false
        targetPort: 5002
        exposedPort: 5002
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyPluginDaemonImage
          resources: {
            cpu: json(pluginCpu)
            memory: pluginMemory
          }
          volumeMounts: [
            {
              volumeName: 'pluginstorage'
              mountPath: '/app/storage'
            }
          ]
          env: [
            {
              name: 'GIN_MODE'
              value: 'release'
            }
            {
              name: 'SERVER_PORT'
              value: '5002'
            }
            {
              name: 'SERVER_KEY'
              value: pluginDaemonKey
            }
            {
              name: 'PLATFORM'
              value: 'local'
            }
            {
              name: 'DIFY_INNER_API_KEY'
              value: innerApiKey
            }
            {
              name: 'DIFY_INNER_API_URL'
              value: 'http://api:5001'
            }
            {
              name: 'DB_USERNAME'
              value: postgresAdminLogin
            }
            {
              name: 'DB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'DB_PORT'
              value: '6432'
            }
            {
              name: 'DB_DATABASE'
              value: postgresDifyDbName
            }
            {
              name: 'REDIS_HOST'
              value: redisHostName
            }
            {
              name: 'REDIS_PORT'
              value: '10000'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'true'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'rediss://:${redisPrimaryKey}@${redisHostName}:10000/0'
            }
            {
              name: 'PLUGIN_STORAGE_TYPE'
              value: 'local'
            }
            {
              name: 'PLUGIN_WORKING_PATH'
              value: 'cwd'
            }
            {
              name: 'PLUGIN_INSTALLED_PATH'
              value: 'plugin'
            }
            {
              name: 'DB_SSL_MODE'
              value: 'require'
            }
            {
              name: 'PLUGIN_WEBHOOK_ENABLED'
              value: 'true'
            }
            {
              name: 'PLUGIN_REMOTE_INSTALLING_ENABLED'
              value: 'false'
            }
            {
              name: 'PLUGIN_REMOTE_INSTALLING_HOST'
              value: '127.0.0.1'
            }
            {
              name: 'PLUGIN_REMOTE_INSTALLING_PORT'
              value: '5003'
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: pluginMaxReplicas
        rules: [
          {
            name: 'plugin'
            tcp: {
              metadata: {
                concurrentRequests: pluginConcurrentRequests
              }
            }
          }
        ]
      }
      volumes: [
        {
          name: 'pluginstorage'
          storageType: 'AzureFile'
          storageName: pluginstorageFileShare.name
        }
      ]
    }
  }
}

// Deploy Web app
resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'web'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'D8'
    configuration: {
      ingress: {
        external: false
        targetPort: 3000
        exposedPort: 3000
        transport: 'tcp'
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyWebImage
          resources: {
            cpu: json(webCpu)
            memory: webMemory
          }
          env: [
            {
              name: 'CONSOLE_API_URL'
              value: ''
            }
            {
              name: 'APP_API_URL'
              value: ''
            }
            {
              name: 'SENTRY_DSN'
              value: ''
            }
            {
              name: 'MARKETPLACE_API_URL'
              value: 'https://marketplace.dify.ai'
            }
            {
              name: 'MARKETPLACE_URL'
              value: 'https://marketplace.dify.ai'            
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: webMaxReplicas
        rules: [
          {
            name: 'web'
            tcp: {
              metadata: {
                concurrentRequests: webConcurrentRequests
              }
            }
          }
        ]
      }
    }
  }
}

// Deploy Extra Worker app
resource extraWorkerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'extra-worker'
  location: location
  properties: {
    environmentId: acaEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      secrets: [
        {
          name: 'redis-password'
          value: redisPrimaryKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'langgenius'
          image: difyApiImage
          resources: {
            cpu: json(workerCpu)
            memory: workerMemory
          }
          env: [
            {
              name: 'MODE'
              value: 'worker'
            }
            {
              name: 'LOG_LEVEL'
              value: 'INFO'
            }
            {
              name: 'SECRET_KEY'
              value: difySecretKey
            }
            {
              name: 'DB_USERNAME'
              value: postgresAdminLogin
            }
            {
              name: 'DB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'DB_PORT'
              value: '6432'
            }
            {
              name: 'DB_DATABASE'
              value: postgresDifyDbName
            }
            {
              name: 'REDIS_HOST'
              value: redisHostName
            }
            {
              name: 'REDIS_PORT'
              value: '10000'
            }
            {
              name: 'REDIS_PASSWORD'
              value: redisPrimaryKey
            }
            {
              name: 'REDIS_USE_SSL'
              value: 'true'
            }
            {
              name: 'REDIS_DB'
              value: '0'
            }
            {
              name: 'CELERY_BROKER_URL'
              value: empty(redisHostName) ? '' : 'rediss://:${redisPrimaryKey}@${redisHostName}:10000/0'
            }
            {
              name: 'STORAGE_TYPE'
              value: 'azure-blob'
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_NAME'
              value: storageAccountName
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_KEY'
              value: storageAccountKey
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_URL'
              value: blobEndpoint
            }
            {
              name: 'AZURE_BLOB_CONTAINER_NAME'
              value: storageContainerName
            }
            {
              name: 'VECTOR_STORE'
              value: 'pgvector'
            }
            {
              name: 'PGVECTOR_HOST'
              value: postgresServerFqdn
            }
            {
              name: 'PGVECTOR_PORT'
              value: '6432'
            }
            {
              name: 'PGVECTOR_USER'
              value: postgresAdminLogin
            }
            {
              name: 'PGVECTOR_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'PGVECTOR_DATABASE'
              value: postgresVectorDbName
            }
            {
              name: 'INDEXING_MAX_SEGMENTATION_TOKENS_LENGTH'
              value: '1000'
            }
            {
              name: 'PLUGIN_DAEMON_URL'
              value: 'http://plugin:5002'
            }
            {
              name: 'PLUGIN_DAEMON_KEY'
              value: pluginDaemonKey
            }
            {
              name: 'INNER_API_KEY_FOR_PLUGIN'
              value: innerApiKey
            }
          ]
        }
      ]
      scale: {
        minReplicas: acaAppMinCount
        maxReplicas: extraWorkerMaxReplicas
        rules: [
          {
            name: 'redis-celery-queue'
            custom: {
              type: 'redis'
              metadata: {
                address: '${redisHostName}:10000'
                listName: 'celery'
                listLength: extraWorkerQueueLength
                databaseIndex: '0'
                useTLS: 'true'
              }
              auth: [
                {
                  secretRef: 'redis-password'
                  triggerParameter: 'password'
                }
              ]
            }
          }
        ]
      }
    }
  }
}

// Deployment output
output difyAppUrl string = nginxApp.properties.configuration.ingress.fqdn
