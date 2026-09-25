// Agentic RAG — Azure Monitor health model (preview).
//
// Models one representative request path of an agentic research assistant:
//   researcher question -> agent -> { APIM gateway -> Azure OpenAI pool (2 regions),
//                                      Foundry IQ / Azure AI Search (retrieval),
//                                      Scholarly-papers MCP server (citations) }
//   -> a cited answer.
//
// Resource provider: Microsoft.CloudHealth/healthmodels. The model only READS
// platform metrics, Log Analytics, and Azure Resource Health of the target
// resources; it never changes the workload.
//
// NOTE: Microsoft.CloudHealth is a preview RP. Bicep emits BCP081 "types not
// available" warnings for its resources — expected; the template still deploys.

targetScope = 'resourceGroup'

@description('Location for the health model resource. Health models are only available in a subset of regions; the modeled resources can live anywhere.')
param location string = 'centralus'

@description('Name of the health model resource.')
param healthModelName string = 'agentic-rag-health'

@description('Resource ID of the APIM instance acting as the AI gateway / load balancer.')
param apimResourceId string

@description('Resource ID of the primary Azure OpenAI account.')
param aoaiPrimaryResourceId string

@description('Resource ID of the secondary Azure OpenAI account.')
param aoaiSecondaryResourceId string

@description('Resource ID of the Azure AI Search service (Foundry IQ knowledge base).')
param searchResourceId string

@description('Resource ID of the MCP server Container App.')
param mcpResourceId string

@description('Resource ID of the Log Analytics workspace receiving Azure OpenAI RequestResponse logs (for the 429 signal).')
param logAnalyticsWorkspaceResourceId string

@description('Optional email address for health-model alerts. Empty = alert-only (no receiver) action group.')
param alertEmail string = ''

@description('Deploy the 1-minute canary probe (Logic App) that keeps the availability signals populated on idle workloads.')
param deployProbe bool = true

@description('Primary Azure OpenAI Responses (v1) endpoint the canary probe calls (openai.azure.com host).')
param aoaiPrimaryOpenAiEndpoint string

@description('Secondary Azure OpenAI Responses (v1) endpoint the canary probe calls (openai.azure.com host).')
param aoaiSecondaryOpenAiEndpoint string

@description('Chat model/deployment the canary probe calls (must exist in both regions).')
param probeModel string = 'gpt-4.1-mini'

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
var apimMetricNamespace = 'Microsoft.ApiManagement/service'
var aoaiMetricNamespace = 'Microsoft.CognitiveServices/accounts'
var searchMetricNamespace = 'Microsoft.Search/searchServices'
var acaMetricNamespace = 'Microsoft.App/containerApps'
var authSettingName = 'default-auth'

// Built-in roles.
var monitoringReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var openAiUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

// 429/throttling detection per region — Azure OpenAI throttling returns HTTP 429 (a
// client error) which AzureOpenAIAvailabilityRate (5xx-based) does NOT count. A bare
// `summarize` returns a single 0 row when idle, so idle reads Healthy not Unknown.
var kql429Primary = 'AzureDiagnostics | where TimeGenerated > ago(5m) | where _ResourceId =~ "${aoaiPrimaryResourceId}" | where Category == "RequestResponse" | summarize throttled = countif(ResultSignature == "429")'
var kql429Secondary = 'AzureDiagnostics | where TimeGenerated > ago(5m) | where _ResourceId =~ "${aoaiSecondaryResourceId}" | where Category == "RequestResponse" | summarize throttled = countif(ResultSignature == "429")'

// Existing AOAI accounts — referenced to attach RequestResponse diagnostic logs + probe RBAC.
resource aoaiPrimaryAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(aoaiPrimaryResourceId, '/'))
}
resource aoaiSecondaryAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: last(split(aoaiSecondaryResourceId, '/'))
}

// Ship Azure OpenAI RequestResponse logs to the workspace so the 429 signal can query them.
resource diagPrimary 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'agentic-rag-rr'
  scope: aoaiPrimaryAccount
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [ { category: 'RequestResponse', enabled: true } ]
  }
}
resource diagSecondary 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'agentic-rag-rr'
  scope: aoaiSecondaryAccount
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [ { category: 'RequestResponse', enabled: true } ]
  }
}

// ---------------------------------------------------------------------------
// Action group (target for health-model alerts)
// ---------------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'agentic-rag-ag'
  location: 'global'
  properties: {
    groupShortName: 'agRagHealth'
    enabled: true
    emailReceivers: empty(alertEmail) ? [] : [
      {
        name: 'oncall'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Health model (system-assigned identity used to read telemetry)
// ---------------------------------------------------------------------------
resource healthModel 'Microsoft.CloudHealth/healthmodels@2026-09-01-preview' = {
  name: healthModelName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {}
}

// Read access to metrics / logs / resource health of every modeled resource (RG scope).
resource monitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, healthModel.id, 'monitoring-reader')
  properties: {
    principalId: healthModel.identity.principalId
    roleDefinitionId: monitoringReaderRoleId
    principalType: 'ServicePrincipal'
  }
}

resource authSetting 'Microsoft.CloudHealth/healthmodels/authenticationsettings@2026-09-01-preview' = {
  parent: healthModel
  name: authSettingName
  properties: {
    authenticationKind: 'ManagedIdentity'
    managedIdentityName: 'SystemAssigned'
  }
}

// ---------------------------------------------------------------------------
// Entities
// ---------------------------------------------------------------------------

// Root — the customer commitment: "a researcher asks a question and gets a cited
// answer synthesized from the papers knowledge base, the scholarly web, and
// Semantic Scholar." Health rolls up here; alerts fire here.
resource rootEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-09-01-preview' = {
  parent: healthModel
  name: 'agentic-research-assistant'
  properties: {
    displayName: 'Agentic Research Assistant'
    canvasPosition: { x: 700, y: 60 }
    icon: { iconName: 'Globe' }
    healthObjective: json('99.9')
    impact: 'Standard'
    signalGroups: {
      dependencies: { aggregationType: 'WorstOf' }
    }
    alerts: {
      unhealthy: {
        severity: 'Sev1'
        description: 'Agentic Research Assistant is UNHEALTHY — researchers cannot reliably get grounded answers.'
        actionGroupIds: [ actionGroup.id ]
      }
      degraded: {
        severity: 'Sev2'
        description: 'Agentic Research Assistant is DEGRADED — still answering, but a dependency (a region, the knowledge base, or the tool server) is impaired.'
        actionGroupIds: [ actionGroup.id ]
      }
    }
  }
}

// APIM gateway / load balancer — single point of entry to the model (SPOF for the LLM path).
resource apimEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-09-01-preview' = {
  parent: healthModel
  name: 'apim-gateway'
  dependsOn: [ authSetting ]
  properties: {
    displayName: 'APIM AI Gateway'
    canvasPosition: { x: 300, y: 300 }
    icon: { iconName: 'ApiManagement' }
    impact: 'Standard'
    signalGroups: {
      // APIM Consumption tier isn't covered by Azure Resource Health (it reports Unknown -> a "?"
      // badge, with no metric signal to offset it). So the gateway's health is derived from the
      // backend pool it fronts. On a dedicated APIM SKU, add an azureResource block with
      // resourceHealth enabled (or an ApiManagementGatewayLogs 5xx Log Analytics signal).
      dependencies: { aggregationType: 'WorstOf' }
    }
  }
}

// Azure OpenAI backend pool — logical rollup of the two regional accounts.
// MinHealthy over an absolute count: 2 healthy -> Healthy, 1 -> Degraded, 0 -> Unhealthy.
resource poolEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-09-01-preview' = {
  parent: healthModel
  name: 'aoai-backend-pool'
  properties: {
    displayName: 'Azure OpenAI backend pool (multi-region)'
    canvasPosition: { x: 300, y: 560 }
    icon: { iconName: 'Cloud' }
    impact: 'Standard'
    signalGroups: {
      dependencies: {
        aggregationType: 'MinHealthy'
        unit: 'Absolute'
        degradedThreshold: json('1')
        unhealthyThreshold: json('0')
        ignoreUnknown: true
      }
    }
  }
}

// Primary Azure OpenAI region.
resource aoaiPrimaryEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-09-01-preview' = {
  parent: healthModel
  name: 'aoai-primary-eastus2'
  dependsOn: [ authSetting ]
  properties: {
    displayName: 'Azure OpenAI — Primary (East US 2)'
    canvasPosition: { x: 40, y: 820 }
    icon: { iconName: 'CognitiveServices' }
    impact: 'Standard'
    healthObjective: json('99.5')
    signalGroups: {
      azureResource: {
        authenticationSetting: authSettingName
        azureResourceId: aoaiPrimaryResourceId
        azureResourceKind: 'CognitiveServices'
        signals: [
          {
            signalKind: 'AzureResourceMetric'
            name: 'availability'
            displayName: 'Azure OpenAI availability rate (5xx-based)'
            refreshInterval: 'PT1M'
            dataUnit: 'Percent'
            metricNamespace: aoaiMetricNamespace
            metricName: 'AzureOpenAIAvailabilityRate'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              degradedRule: { operator: 'LessThan', threshold: json('99') }
              unhealthyRule: { operator: 'LessThan', threshold: json('95') }
            }
          }
          {
            signalKind: 'AzureResourceMetric'
            name: 'time-to-last-byte'
            displayName: 'Time to last byte (dynamic threshold)'
            refreshInterval: 'PT1M'
            dataUnit: 'MilliSeconds'
            metricNamespace: aoaiMetricNamespace
            metricName: 'AzureOpenAITTLTInMS'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              // Static latency guardrail — predictable from deploy time. A dynamic threshold is the
              // better production choice but needs a multi-day baseline before it reads reliably;
              // early on, one spike against a near-zero baseline reads as a false anomaly.
              degradedRule: { operator: 'GreaterThan', threshold: json('8000') }
              unhealthyRule: { operator: 'GreaterThan', threshold: json('30000') }
            }
          }
        ]
        resourceHealth: { enabled: 'Enabled' }
      }
      azureLogAnalytics: {
        authenticationSetting: authSettingName
        logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
        signals: [
          {
            signalKind: 'LogAnalyticsQuery'
            name: 'throttling-429'
            displayName: '429 throttling (rate-limited requests, 5 min)'
            refreshInterval: 'PT1M'
            dataUnit: 'Count'
            queryText: kql429Primary
            timeGrain: 'PT5M'
            valueColumnName: 'throttled'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: json('5') }
              unhealthyRule: { operator: 'GreaterThan', threshold: json('20') }
            }
          }
        ]
      }
    }
  }
}

// Secondary Azure OpenAI region.
resource aoaiSecondaryEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-09-01-preview' = {
  parent: healthModel
  name: 'aoai-secondary-westus'
  dependsOn: [ authSetting ]
  properties: {
    displayName: 'Azure OpenAI — Secondary (West US)'
    canvasPosition: { x: 620, y: 820 }
    icon: { iconName: 'CognitiveServices' }
    impact: 'Standard'
    healthObjective: json('99.5')
    signalGroups: {
      azureResource: {
        authenticationSetting: authSettingName
        azureResourceId: aoaiSecondaryResourceId
        azureResourceKind: 'CognitiveServices'
        signals: [
          {
            signalKind: 'AzureResourceMetric'
            name: 'availability'
            displayName: 'Azure OpenAI availability rate (5xx-based)'
            refreshInterval: 'PT1M'
            dataUnit: 'Percent'
            metricNamespace: aoaiMetricNamespace
            metricName: 'AzureOpenAIAvailabilityRate'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              degradedRule: { operator: 'LessThan', threshold: json('99') }
              unhealthyRule: { operator: 'LessThan', threshold: json('95') }
            }
          }
          {
            signalKind: 'AzureResourceMetric'
            name: 'time-to-last-byte'
            displayName: 'Time to last byte (dynamic threshold)'
            refreshInterval: 'PT1M'
            dataUnit: 'MilliSeconds'
            metricNamespace: aoaiMetricNamespace
            metricName: 'AzureOpenAITTLTInMS'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              // Static latency guardrail — predictable from deploy time. A dynamic threshold is the
              // better production choice but needs a multi-day baseline before it reads reliably;
              // early on, one spike against a near-zero baseline reads as a false anomaly.
              degradedRule: { operator: 'GreaterThan', threshold: json('8000') }
              unhealthyRule: { operator: 'GreaterThan', threshold: json('30000') }
            }
          }
        ]
        resourceHealth: { enabled: 'Enabled' }
      }
      azureLogAnalytics: {
        authenticationSetting: authSettingName
        logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
        signals: [
          {
            signalKind: 'LogAnalyticsQuery'
            name: 'throttling-429'
            displayName: '429 throttling (rate-limited requests, 5 min)'
            refreshInterval: 'PT1M'
            dataUnit: 'Count'
            queryText: kql429Secondary
            timeGrain: 'PT5M'
            valueColumnName: 'throttled'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: json('5') }
              unhealthyRule: { operator: 'GreaterThan', threshold: json('20') }
            }
          }
        ]
      }
    }
  }
}

// Foundry IQ / Azure AI Search — the retrieval dependency (grounds the answer in the papers).
resource searchEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-09-01-preview' = {
  parent: healthModel
  name: 'foundry-iq-search'
  dependsOn: [ authSetting ]
  properties: {
    displayName: 'Foundry IQ knowledge base (Azure AI Search)'
    canvasPosition: { x: 820, y: 300 }
    icon: { iconName: 'Search' }
    impact: 'Standard'
    signalGroups: {
      azureResource: {
        authenticationSetting: authSettingName
        azureResourceId: searchResourceId
        azureResourceKind: 'Search'
        signals: [
          {
            signalKind: 'AzureResourceMetric'
            name: 'search-latency'
            displayName: 'Search query latency'
            refreshInterval: 'PT1M'
            dataUnit: 'Seconds'
            metricNamespace: searchMetricNamespace
            metricName: 'SearchLatency'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: json('1') }
              unhealthyRule: { operator: 'GreaterThan', threshold: json('5') }
            }
          }
          {
            signalKind: 'AzureResourceMetric'
            name: 'search-throttling'
            displayName: 'Throttled search queries'
            refreshInterval: 'PT1M'
            dataUnit: 'Percent'
            metricNamespace: searchMetricNamespace
            metricName: 'ThrottledSearchQueriesPercentage'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: json('5') }
              unhealthyRule: { operator: 'GreaterThan', threshold: json('20') }
            }
          }
        ]
        resourceHealth: { enabled: 'Enabled' }
      }
    }
  }
}

// Scholarly-papers MCP server — the tool dependency (citations / cross-checks).
// Impact = Limited: if the MCP server is unhealthy the agent still answers from the
// knowledge base + web, so the workload is DEGRADED (never made Unhealthy by the tool).
resource mcpEntity 'Microsoft.CloudHealth/healthmodels/entities@2026-09-01-preview' = {
  parent: healthModel
  name: 'mcp-server'
  dependsOn: [ authSetting ]
  properties: {
    displayName: 'Scholarly-papers MCP server'
    canvasPosition: { x: 1320, y: 300 }
    icon: { iconName: 'ContainerApp' }
    impact: 'Limited'
    signalGroups: {
      azureResource: {
        authenticationSetting: authSettingName
        azureResourceId: mcpResourceId
        azureResourceKind: 'ContainerApp'
        signals: [
          {
            signalKind: 'AzureResourceMetric'
            name: 'replica-availability'
            displayName: 'Running replicas'
            refreshInterval: 'PT1M'
            dataUnit: 'Count'
            metricNamespace: acaMetricNamespace
            metricName: 'Replicas'
            timeGrain: 'PT5M'
            aggregationType: 'Average'
            evaluationRules: {
              unhealthyRule: { operator: 'LessThan', threshold: json('1') }
            }
          }
          {
            signalKind: 'AzureResourceMetric'
            name: 'restarts'
            displayName: 'Container restarts'
            refreshInterval: 'PT1M'
            dataUnit: 'Count'
            metricNamespace: acaMetricNamespace
            metricName: 'RestartCount'
            timeGrain: 'PT5M'
            aggregationType: 'Maximum'
            evaluationRules: {
              degradedRule: { operator: 'GreaterThan', threshold: json('2') }
              unhealthyRule: { operator: 'GreaterThan', threshold: json('5') }
            }
          }
        ]
        // Container Apps aren't supported by Azure Resource Health — keep it explicitly Disabled
        // so it doesn't surface as a red "unknown" error badge on the entity.
        resourceHealth: { enabled: 'Disabled' }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Relationships (parent DEPENDS ON child; health propagates child -> parent)
// ---------------------------------------------------------------------------
resource relModelRoot 'Microsoft.CloudHealth/healthmodels/relationships@2026-09-01-preview' = {
  parent: healthModel
  name: 'model-root-to-service'
  dependsOn: [ rootEntity ]
  properties: {
    displayName: 'Model root rolls up the research assistant'
    parentEntityName: healthModelName
    childEntityName: rootEntity.name
  }
}
resource relRootApim 'Microsoft.CloudHealth/healthmodels/relationships@2026-09-01-preview' = {
  parent: healthModel
  name: 'root-to-apim'
  properties: {
    displayName: 'Assistant depends on the APIM gateway (LLM)'
    parentEntityName: rootEntity.name
    childEntityName: apimEntity.name
  }
}
resource relApimPool 'Microsoft.CloudHealth/healthmodels/relationships@2026-09-01-preview' = {
  parent: healthModel
  name: 'apim-to-pool'
  properties: {
    displayName: 'APIM gateway depends on the Azure OpenAI backend pool'
    parentEntityName: apimEntity.name
    childEntityName: poolEntity.name
  }
}
resource relPoolPrimary 'Microsoft.CloudHealth/healthmodels/relationships@2026-09-01-preview' = {
  parent: healthModel
  name: 'pool-to-primary'
  properties: {
    displayName: 'Backend pool includes the primary region'
    parentEntityName: poolEntity.name
    childEntityName: aoaiPrimaryEntity.name
  }
}
resource relPoolSecondary 'Microsoft.CloudHealth/healthmodels/relationships@2026-09-01-preview' = {
  parent: healthModel
  name: 'pool-to-secondary'
  properties: {
    displayName: 'Backend pool includes the secondary region'
    parentEntityName: poolEntity.name
    childEntityName: aoaiSecondaryEntity.name
  }
}
resource relRootSearch 'Microsoft.CloudHealth/healthmodels/relationships@2026-09-01-preview' = {
  parent: healthModel
  name: 'root-to-search'
  properties: {
    displayName: 'Assistant depends on Foundry IQ retrieval'
    parentEntityName: rootEntity.name
    childEntityName: searchEntity.name
  }
}
resource relRootMcp 'Microsoft.CloudHealth/healthmodels/relationships@2026-09-01-preview' = {
  parent: healthModel
  name: 'root-to-mcp'
  properties: {
    displayName: 'Assistant uses the MCP tool server (enhancement)'
    parentEntityName: rootEntity.name
    childEntityName: mcpEntity.name
  }
}

// ---------------------------------------------------------------------------
// Canary probe (optional) — 1-minute Logic App keeping AzureOpenAIAvailabilityRate
// + Time-to-Last-Byte populated so idle regions read Healthy, not Unknown.
// ---------------------------------------------------------------------------
resource probe 'Microsoft.Logic/workflows@2019-05-01' = if (deployProbe) {
  name: 'agentic-rag-probe'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {
        everyMinute: {
          type: 'Recurrence'
          recurrence: { frequency: 'Minute', interval: 1 }
        }
      }
      actions: {
        pingPrimary: {
          type: 'Http'
          runAfter: {}
          inputs: {
            method: 'POST'
            uri: '${aoaiPrimaryOpenAiEndpoint}/responses'
            headers: { 'Content-Type': 'application/json' }
            body: { model: probeModel, input: 'health-model canary ping', max_output_tokens: 16 }
            authentication: { type: 'ManagedServiceIdentity', audience: 'https://cognitiveservices.azure.com' }
          }
        }
        pingSecondary: {
          type: 'Http'
          runAfter: {}
          inputs: {
            method: 'POST'
            uri: '${aoaiSecondaryOpenAiEndpoint}/responses'
            headers: { 'Content-Type': 'application/json' }
            body: { model: probeModel, input: 'health-model canary ping', max_output_tokens: 16 }
            authentication: { type: 'ManagedServiceIdentity', audience: 'https://cognitiveservices.azure.com' }
          }
        }
      }
    }
  }
}

resource probeRolePrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployProbe) {
  name: guid(aoaiPrimaryResourceId, 'agentic-rag-probe', 'openai-user')
  scope: aoaiPrimaryAccount
  properties: {
    principalId: probe.identity.principalId
    roleDefinitionId: openAiUserRoleId
    principalType: 'ServicePrincipal'
  }
}
resource probeRoleSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployProbe) {
  name: guid(aoaiSecondaryResourceId, 'agentic-rag-probe', 'openai-user')
  scope: aoaiSecondaryAccount
  properties: {
    principalId: probe.identity.principalId
    roleDefinitionId: openAiUserRoleId
    principalType: 'ServicePrincipal'
  }
}

output healthModelName string = healthModel.name
output healthModelId string = healthModel.id
output healthModelPrincipalId string = healthModel.identity.principalId
output actionGroupId string = actionGroup.id
