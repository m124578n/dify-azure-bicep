@description('Resource group location')
param location string

@description('Subnet ID for nginx VM')
param nginxSubnetId string

@description('Backend pool ID of the public load balancer')
param publicLbBackendPoolId string

@description('Static private IP of the internal load balancer')
param internalLbIp string

@description('Admin username for the VM')
param adminUsername string

@description('SSH public key for the admin user')
param adminSshPublicKey string

@description('VM size')
param vmSize string = 'Standard_B2s'

// NSG for nginx VM
resource nsgNginx 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: 'nsg-nginx'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-http'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'allow-https'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
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

// Cloud-init script for nginx VM
var cloudInitScript = '#!/bin/bash\nset -e\nexport DEBIAN_FRONTEND=noninteractive\napt-get update -qq\napt-get install -y nginx\n\n# Write nginx config\ncat > /etc/nginx/conf.d/dify.conf << \'NGINXEOF\'\nserver {\n    listen 80;\n    server_name _;\n\n    location /nginx-health {\n        return 200 \'healthy\';\n        add_header Content-Type text/plain;\n    }\n\n    location / {\n        proxy_pass http://${internalLbIp};\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_read_timeout 3600s;\n        proxy_connect_timeout 60s;\n        proxy_send_timeout 3600s;\n    }\n}\nNGINXEOF\n\n# Remove default site\nrm -f /etc/nginx/sites-enabled/default\n\n# Test and reload nginx\nnginx -t\nsystemctl enable nginx\nsystemctl restart nginx\n'

// NIC for nginx VM
resource nicNginx 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: 'nic-nginx'
  location: location
  properties: {
    networkSecurityGroup: {
      id: nsgNginx.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig-nginx'
        properties: {
          subnet: {
            id: nginxSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          loadBalancerBackendAddressPools: [
            {
              id: publicLbBackendPoolId
            }
          ]
        }
      }
    ]
  }
}

// Nginx VM
resource vmNginx 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: 'vm-nginx'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
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
      computerName: 'vm-nginx'
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
      networkInterfaces: [
        {
          id: nicNginx.id
        }
      ]
    }
  }
}

output nginxVmId string = vmNginx.id
