// =====================================================================================
// VMSS with predictive autoscale — demo for scenario 19.
// Deploys a minimal Ubuntu VMSS (1 instance, B1s) with an autoscale setting that has
// reactive CPU-based rules and predictive autoscale enabled in "ForecastOnly" mode.
// =====================================================================================

@description('VMSS name.')
param name string

@description('Region.')
param location string

@description('VM SKU (kept tiny for a demo lab).')
param vmSize string = 'Standard_B1s'

@description('Admin username.')
param adminUsername string

@description('Admin password.')
@secure()
param adminPassword string

@description('Subnet resource ID for the VMSS instances.')
param subnetId string

@description('Resource tags.')
param tags object = {}

var useConfidentialVm = startsWith(toLower(vmSize), 'standard_ec') && (endsWith(toLower(vmSize), 'as_v5') || endsWith(toLower(vmSize), 'ads_v5'))

// ---------------------------------------------------------------------------------
// VMSS — Ubuntu 22.04, single instance, Flexible orchestration
// ---------------------------------------------------------------------------------
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: vmSize
    tier: 'Standard'
    capacity: 1
  }
  identity: { type: 'SystemAssigned' }
  properties: {
    overprovision: false
    upgradePolicy: { mode: 'Automatic' }
    virtualMachineProfile: union({
      osProfile: {
        computerNamePrefix: take(name, 9)
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
          offer: useConfidentialVm ? '0001-com-ubuntu-confidential-vm-jammy' : '0001-com-ubuntu-server-jammy'
          sku: useConfidentialVm ? '22_04-lts-cvm' : '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
            securityProfile: useConfidentialVm ? {
              securityEncryptionType: 'VMGuestStateOnly'
            } : null
          }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic-${name}'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig1'
                  properties: {
                    primary: true
                    subnet: { id: subnetId }
                  }
                }
              ]
            }
          }
        ]
      }
    }, useConfidentialVm ? {
        securityProfile: {
          securityType: 'ConfidentialVM'
          uefiSettings: {
            secureBootEnabled: true
            vTpmEnabled: true
          }
        }
      } : {})
    }
  }

// ---------------------------------------------------------------------------------
// Autoscale setting with reactive rules + predictive autoscale (ForecastOnly)
// ---------------------------------------------------------------------------------
resource autoscale 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: 'autoscale-${name}'
  location: location
  tags: tags
  properties: {
    name: 'autoscale-${name}'
    enabled: true
    targetResourceUri: vmss.id
    predictiveAutoscalePolicy: {
      scaleMode: 'ForecastOnly'
      scaleLookAheadTime: 'PT10M'
    }
    profiles: [
      {
        name: 'default'
        capacity: {
          minimum: '1'
          maximum: '5'
          default: '1'
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricNamespace: ''
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
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
              metricNamespace: ''
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
              cooldown: 'PT5M'
            }
          }
        ]
      }
    ]
  }
}

output vmssId string = vmss.id
output vmssName string = vmss.name
output autoscaleSettingName string = autoscale.name
