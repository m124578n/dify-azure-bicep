@description('Resource group location')
param location string

@description('Subnet ID for app VMSS')
param appSubnetId string

@description('Backend pool ID of the internal load balancer')
param internalLbBackendPoolId string

@description('Admin username for VMSS instances')
param adminUsername string

@description('SSH public key for the admin user')
param adminSshPublicKey string

@description('VM size for VMSS instances')
param vmSize string = 'Standard_D4s_v3'

@description('Initial instance count')
param instanceCount int = 2

@description('PostgreSQL server FQDN')
param postgresServerFqdn string

@description('PostgreSQL admin login')
param postgresAdminLogin string

@description('PostgreSQL admin password')
@secure()
param postgresAdminPassword string

@description('PostgreSQL database name for Dify')
param postgresDifyDbName string

@description('PostgreSQL database name for vector store')
param postgresVectorDbName string

@description('Redis host name')
param redisHostName string

@description('Redis primary key')
@secure()
param redisPrimaryKey string

@description('Storage account name')
param storageAccountName string

@description('Storage account key')
@secure()
param storageAccountKey string

@description('Storage container name')
param storageContainerName string

@description('Blob endpoint')
param blobEndpoint string

@description('Dify API image')
param difyApiImage string

@description('Dify sandbox image')
param difySandboxImage string

@description('Dify web image')
param difyWebImage string

@description('Dify plugin daemon image')
param difyPluginDaemonImage string

// NSG for app VMSS
resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-app'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-http-vnet'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'allow-ssh-vnet'
        properties: {
          priority: 200
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'deny-all'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Cloud-init script assembled as Bicep string vars
var cloudInitPart1 = '#!/bin/bash\nset -e\nexport DEBIAN_FRONTEND=noninteractive\napt-get update -qq\napt-get install -y docker.io docker-compose-v2 cifs-utils\nsystemctl enable docker && systemctl start docker\nmkdir -p /mnt/nginx /mnt/sandbox /mnt/ssrfproxy /mnt/pluginstorage /opt/dify\n\n# Mount Azure Files\nfor SHARE in nginx sandbox ssrfproxy pluginstorage; do\n  mount -t cifs //${storageAccountName}.file.core.windows.net/\${SHARE} /mnt/\${SHARE} \\\n    -o "username=${storageAccountName},password=${storageAccountKey},vers=3.0,serverino,dir_mode=0755,file_mode=0644" || echo "Warning: Failed to mount \${SHARE}"\n  echo "//${storageAccountName}.file.core.windows.net/\${SHARE} /mnt/\${SHARE} cifs username=${storageAccountName},password=${storageAccountKey},vers=3.0,serverino,dir_mode=0755,file_mode=0644,_netdev 0 0" >> /etc/fstab\ndone\n\n'

var cloudInitEnvFile = 'cat > /opt/dify/.env << \'ENVEOF\'\nLOG_LEVEL=INFO\nSECRET_KEY=dify-9f73s3ljTXVcMT3Blb3ljTqtsKiGHXVcMT3BlbkFJLK7U\nCONSOLE_WEB_URL=\nINIT_PASSWORD=\nCONSOLE_API_URL=\nSERVICE_API_URL=\nAPP_WEB_URL=\nFILES_URL=\nFILES_ACCESS_TIMEOUT=300\nMIGRATION_ENABLED=true\nDB_USERNAME=${postgresAdminLogin}\nDB_PASSWORD=${postgresAdminPassword}\nDB_HOST=${postgresServerFqdn}\nDB_PORT=5432\nDB_DATABASE=${postgresDifyDbName}\nWEB_API_CORS_ALLOW_ORIGINS=*\nCONSOLE_CORS_ALLOW_ORIGINS=*\nREDIS_HOST=${redisHostName}\nREDIS_PORT=6379\nREDIS_PASSWORD=${redisPrimaryKey}\nREDIS_USE_SSL=false\nREDIS_DB=0\nCELERY_BROKER_URL=redis://:${redisPrimaryKey}@${redisHostName}:6379/1\nSTORAGE_TYPE=azure-blob\nAZURE_BLOB_ACCOUNT_NAME=${storageAccountName}\nAZURE_BLOB_ACCOUNT_KEY=${storageAccountKey}\nAZURE_BLOB_ACCOUNT_URL=${blobEndpoint}\nAZURE_BLOB_CONTAINER_NAME=${storageContainerName}\nVECTOR_STORE=pgvector\nPGVECTOR_HOST=${postgresServerFqdn}\nPGVECTOR_PORT=5432\nPGVECTOR_USER=${postgresAdminLogin}\nPGVECTOR_PASSWORD=${postgresAdminPassword}\nPGVECTOR_DATABASE=${postgresVectorDbName}\nCODE_EXECUTION_API_KEY=dify-sandbox\nCODE_EXECUTION_ENDPOINT=http://sandbox:8194\nCODE_MAX_NUMBER=9223372036854775807\nCODE_MIN_NUMBER=-9223372036854775808\nCODE_MAX_STRING_LENGTH=80000\nTEMPLATE_TRANSFORM_MAX_LENGTH=80000\nCODE_MAX_OBJECT_ARRAY_LENGTH=30\nCODE_MAX_STRING_ARRAY_LENGTH=30\nCODE_MAX_NUMBER_ARRAY_LENGTH=1000\nINDEXING_MAX_SEGMENTATION_TOKENS_LENGTH=1000\nPLUGIN_DAEMON_URL=http://plugin:5002\nPLUGIN_DAEMON_KEY=lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi\nINNER_API_KEY_FOR_PLUGIN=-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1\nGIN_MODE=release\nSERVER_PORT=5002\nSERVER_KEY=lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi\nPLATFORM=local\nDIFY_INNER_API_KEY=-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1\nDIFY_INNER_API_URL=http://api:5001\nPLUGIN_STORAGE_TYPE=local\nPLUGIN_WORKING_PATH=cwd\nPLUGIN_INSTALLED_PATH=plugin\nDB_SSL_MODE=require\nPLUGIN_WEBHOOK_ENABLED=true\nPLUGIN_REMOTE_INSTALLING_ENABLED=false\nAPI_KEY=dify-sandbox\nWORKER_TIMEOUT=15\nENABLE_NETWORK=true\nHTTP_PROXY=http://ssrf_proxy:3128\nHTTPS_PROXY=http://ssrf_proxy:3128\nSANDBOX_PORT=8194\nENVEOF\n\n'

var cloudInitDockerCompose = 'cat > /opt/dify/docker-compose.yml << \'COMPEOF\'\nservices:\n  nginx:\n    image: nginx:stable\n    ports:\n      - "80:80"\n    volumes:\n      - /mnt/nginx:/nginx-share:ro\n    command: ["/bin/sh", "-c", "cp /nginx-share/conf.d/default.conf /etc/nginx/conf.d/default.conf && cp /nginx-share/proxy.conf /etc/nginx/proxy.conf && nginx -g \'daemon off;\'"]\n    depends_on:\n      - api\n      - web\n    restart: always\n\n  api:\n    image: ${difyApiImage}\n    env_file: /opt/dify/.env\n    environment:\n      - MODE=api\n    restart: always\n\n  worker:\n    image: ${difyApiImage}\n    env_file: /opt/dify/.env\n    environment:\n      - MODE=worker\n    restart: always\n\n  web:\n    image: ${difyWebImage}\n    env_file: /opt/dify/.env\n    environment:\n      - MARKETPLACE_API_URL=https://marketplace.dify.ai\n      - MARKETPLACE_URL=https://marketplace.dify.ai\n    restart: always\n\n  sandbox:\n    image: ${difySandboxImage}\n    env_file: /opt/dify/.env\n    volumes:\n      - /mnt/sandbox:/dependencies\n    cap_add:\n      - SYS_ADMIN\n    security_opt:\n      - seccomp:unconfined\n    restart: always\n\n  ssrf_proxy:\n    image: ubuntu/squid:latest\n    volumes:\n      - /mnt/ssrfproxy:/etc/squid:ro\n    restart: always\n\n  plugin:\n    image: ${difyPluginDaemonImage}\n    env_file: /opt/dify/.env\n    volumes:\n      - /mnt/pluginstorage:/app/storage\n    restart: always\nCOMPEOF\n\n'

var cloudInitFinish = 'cd /opt/dify\ndocker compose pull --quiet 2>/dev/null || true\ndocker compose up -d\n\ncat > /etc/systemd/system/dify.service << \'SVCEOF\'\n[Unit]\nDescription=Dify Application Stack\nAfter=docker.service network-online.target remote-fs.target\nRequires=docker.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nWorkingDirectory=/opt/dify\nExecStart=/usr/bin/docker compose up -d\nExecStop=/usr/bin/docker compose down\nTimeoutStartSec=600\n\n[Install]\nWantedBy=multi-user.target\nSVCEOF\n\nsystemctl daemon-reload\nsystemctl enable dify\n'

var cloudInitScript = '${cloudInitPart1}${cloudInitEnvFile}${cloudInitDockerCompose}${cloudInitFinish}'

// VM Scale Set
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-07-01' = {
  name: 'vmss-dify'
  location: location
  sku: {
    name: vmSize
    tier: 'Standard'
    capacity: instanceCount
  }
  properties: {
    orchestrationMode: 'Uniform'
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
        }
      }
      osProfile: {
        computerNamePrefix: 'vmss-dify'
        adminUsername: adminUsername
        customData: base64(cloudInitScript)
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: adminSshPublicKey
              }
            ]
          }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic-vmss-dify'
            properties: {
              primary: true
              networkSecurityGroup: {
                id: nsgApp.id
              }
              ipConfigurations: [
                {
                  name: 'ipconfig-vmss'
                  properties: {
                    subnet: {
                      id: appSubnetId
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: internalLbBackendPoolId
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      extensionProfile: {
        extensions: [
          {
            name: 'health'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthLinux'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
              settings: {
                protocol: 'tcp'
                port: 80
              }
            }
          }
        ]
      }
    }
  }
}

// Autoscale settings
resource autoscale 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: 'autoscale-vmss-dify'
  location: location
  properties: {
    enabled: true
    targetResourceUri: vmss.id
    profiles: [
      {
        name: 'default'
        capacity: {
          minimum: '2'
          maximum: '10'
          default: string(instanceCount)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT10M'
            }
          }
        ]
      }
    ]
  }
}

output vmssId string = vmss.id
output vmssName string = vmss.name
