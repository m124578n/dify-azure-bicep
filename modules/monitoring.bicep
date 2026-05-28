@description('Resource group location')
param location string

@description('VMSS name for DCR association')
param vmssName string

@description('VMSS principal ID for Monitoring Metrics Publisher role')
param vmssPrincipalId string

@description('Alert email address (leave empty to skip alerts)')
param alertEmail string = ''

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-dify'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'dcr-dify-vmss'
  location: location
  properties: {
    dataSources: {
      syslog: [
        {
          name: 'syslog-all'
          streams: ['Microsoft-Syslog']
          facilityNames: ['daemon', 'kern', 'user', 'syslog', 'auth']
          logLevels: ['Debug', 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency']
        }
      ]
      performanceCounters: [
        {
          name: 'perf-basic'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Memory(*)\\Available MBytes'
            'Logical Disk(*)\\% Free Space'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspace.id
          name: 'law-destination'
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-Syslog']
        destinations: ['law-destination']
      }
      {
        streams: ['Microsoft-Perf']
        destinations: ['law-destination']
      }
    ]
  }
}

resource vmssRef 'Microsoft.Compute/virtualMachineScaleSets@2023-07-01' existing = {
  name: vmssName
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'dcra-dify-vmss'
  scope: vmssRef
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

var monitoringMetricsPublisherId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource metricsPublisherRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vmssRef.id, monitoringMetricsPublisherId, vmssPrincipalId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherId)
    principalId: vmssPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmail)) {
  name: 'ag-dify-ops'
  location: 'global'
  properties: {
    groupShortName: 'DifyOps'
    enabled: true
    emailReceivers: [
      {
        name: 'ops-email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(alertEmail)) {
  name: 'alert-vmss-cpu-high'
  location: 'global'
  properties: {
    description: 'VMSS average CPU exceeded 85% for 5 minutes'
    severity: 2
    enabled: true
    scopes: [vmssRef.id]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'cpu-high'
          criterionType: 'StaticThresholdCriterion'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 85
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

output workspaceId string = logAnalyticsWorkspace.id
output workspaceName string = logAnalyticsWorkspace.name
