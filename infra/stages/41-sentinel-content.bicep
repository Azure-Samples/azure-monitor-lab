targetScope = 'resourceGroup'

@description('Short prefix used to build resource names.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'amlab'

var suffix = uniqueString(resourceGroup().id)
var lawCentralName = 'law-${namePrefix}-central-${take(suffix, 5)}'

module analyticsRule '../modules/sentinel-rule.bicep' = {
  params: {
    workspaceName: lawCentralName
  }
}

output ruleName string = analyticsRule.outputs.ruleName
