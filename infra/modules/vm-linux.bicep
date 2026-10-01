@description('Linux VM name (max 64 chars; hostname max 63).')
param vmName string

@description('Region.')
param location string

@description('VM SKU.')
param vmSize string = 'Standard_B2s'

@description('Admin username.')
param adminUsername string

@description('Admin password.')
@secure()
param adminPassword string

@description('Subnet resource ID.')
param subnetId string

@description('Data Collection Rule for VM Insights.')
param dcrId string

@description('Optional additional DCR for OpenTelemetry metrics. Empty keeps classic VM Insights only.')
param otelDcrId string = ''

@description('Resource tags.')
param tags object = {}

resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-${vmName}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: subnetId }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
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
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vm.name}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: '2300'
    }
    timeZoneId: 'Romance Standard Time'
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

// Azure Monitor Agent
resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.30'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Network Watcher Agent — required by Connection Monitor probes from this VM.
resource nwAgent 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'NetworkWatcherAgentLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: 'NetworkWatcherAgentLinux'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [ ama ]
}

// NOTE: The Dependency Agent for Linux does not support Ubuntu 22.04.5+ kernels
// (https://aka.ms/ServiceMapTroubleshooting). VM Insights still works via AMA +
// the VM Insights DCR (perf counters, heartbeat, processes); the Service Map
// view is unavailable on Linux. Map is still demonstrated on the Windows VM.

// Associate the DCR with the VM
resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: vm
  name: 'vminsights-association'
  properties: {
    dataCollectionRuleId: dcrId
    description: 'Associate VM Insights DCR'
  }
  dependsOn: [ ama ]
}

resource otelDcra 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (!empty(otelDcrId)) {
  scope: vm
  name: 'vm-otel-metrics-association'
  properties: {
    dataCollectionRuleId: otelDcrId
    description: 'Default OpenTelemetry guest metrics to the Azure Monitor workspace.'
  }
  dependsOn: [ ama ]
}

output vmId string = vm.id
output vmName string = vm.name
output publicIp string = pip.properties.ipAddress
