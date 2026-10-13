// Agentic RAG — base infrastructure (the workload the health model observes).
//
// Provisions the resources modeled by infra/health-model.bicep:
//   - 2x Azure OpenAI accounts (primary + secondary region) with a chat model
//     and (primary only) an embedding model
//   - Azure AI Search (Foundry IQ knowledge base) with AAD data-plane auth
//   - Log Analytics workspace (Azure OpenAI RequestResponse logs -> 429 signal)
//   - API Management (Consumption) acting as the AI gateway / load balancer
//   - Container Apps environment for the scholarly-papers MCP server
//
// Keyless throughout: system-assigned managed identities + RBAC (no keys in code).
// After this deploys, run (in order):
//   1. infra/configure_apim.py   — wire the APIM responses-HA API + backend pool
//   2. build + deploy the MCP image to the Container Apps environment
//   3. infra/ingest_papers.py    — create the Foundry IQ knowledge base
//   4. infra/deploy_health_model.py
//
// Values are parameterized; defaults match .env.example. Override per environment.

targetScope = 'resourceGroup'

@description('Prefix for all resource names.')
param namePrefix string = 'agrag'

@description('Primary region (Azure OpenAI primary + Log Analytics + APIM + Container Apps).')
param primaryLocation string = 'eastus2'

@description('Secondary Azure OpenAI region.')
param secondaryLocation string = 'westus'

@description('Azure AI Search region (choose one with Search capacity).')
param searchLocation string = 'centralus'

@description('Chat model deployed to both Azure OpenAI accounts.')
param chatModel string = 'gpt-4.1-mini'

@description('Chat model version.')
param chatModelVersion string = '2025-04-14'

@description('Embedding model deployed to the primary Azure OpenAI account.')
param embeddingModel string = 'text-embedding-3-large'

@description('Embedding model version.')
param embeddingModelVersion string = '1'

@description('GlobalStandard capacity (thousands of TPM) for each model deployment.')
param modelCapacity int = 50

@description('Publisher email for API Management.')
param apimPublisherEmail string

@description('Publisher name for API Management.')
param apimPublisherName string = 'Agentic RAG PoC'

var cognitiveServicesUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')

// ---------------------------------------------------------------------------
// Log Analytics
// ---------------------------------------------------------------------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: primaryLocation
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Azure OpenAI — primary (chat + embedding) and secondary (chat only)
// ---------------------------------------------------------------------------
resource aoaiPrimary 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${namePrefix}-aoai-${primaryLocation}'
  location: primaryLocation
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: '${namePrefix}-aoai-${primaryLocation}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

resource aoaiSecondary 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${namePrefix}-aoai-${secondaryLocation}'
  location: secondaryLocation
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: '${namePrefix}-aoai-${secondaryLocation}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: false
  }
}

// Chat deployment on the primary account.
resource chatPrimary 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoaiPrimary
  name: chatModel
  sku: { name: 'GlobalStandard', capacity: modelCapacity }
  properties: {
    model: { format: 'OpenAI', name: chatModel, version: chatModelVersion }
  }
}

// Embedding deployment on the primary account (must be serialized after the chat deployment).
resource embedPrimary 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoaiPrimary
  name: embeddingModel
  dependsOn: [ chatPrimary ]
  sku: { name: 'GlobalStandard', capacity: modelCapacity }
  properties: {
    model: { format: 'OpenAI', name: embeddingModel, version: embeddingModelVersion }
  }
}

// Chat deployment on the secondary account.
resource chatSecondary 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoaiSecondary
  name: chatModel
  sku: { name: 'GlobalStandard', capacity: modelCapacity }
  properties: {
    model: { format: 'OpenAI', name: chatModel, version: chatModelVersion }
  }
}

// ---------------------------------------------------------------------------
// Azure AI Search (Foundry IQ knowledge base) — AAD data-plane auth
// ---------------------------------------------------------------------------
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: '${namePrefix}-search'
  location: searchLocation
  sku: { name: 'basic' }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }
    semanticSearch: 'standard'
  }
}

// The Search managed identity embeds + synthesizes via the primary Azure OpenAI account (keyless).
resource searchToAoai 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoaiPrimary.id, search.id, 'cognitive-services-user')
  scope: aoaiPrimary
  properties: {
    principalId: search.identity.principalId
    roleDefinitionId: cognitiveServicesUserRoleId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// API Management (Consumption) — AI gateway. MI granted access to both accounts.
// The responses-HA API + backend pool are wired by infra/configure_apim.py.
// ---------------------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: '${namePrefix}-gateway'
  location: primaryLocation
  sku: { name: 'Consumption', capacity: 0 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
  }
}

resource apimToPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoaiPrimary.id, apim.id, 'cognitive-services-user')
  scope: aoaiPrimary
  properties: {
    principalId: apim.identity.principalId
    roleDefinitionId: cognitiveServicesUserRoleId
    principalType: 'ServicePrincipal'
  }
}
resource apimToSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoaiSecondary.id, apim.id, 'cognitive-services-user')
  scope: aoaiSecondary
  properties: {
    principalId: apim.identity.principalId
    roleDefinitionId: cognitiveServicesUserRoleId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Container Apps environment for the scholarly-papers MCP server.
// Build + deploy the image from mcp-server/ (az containerapp up) after this deploys.
// ---------------------------------------------------------------------------
resource acaEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-mcp-env'
  location: primaryLocation
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

output aoaiPrimaryResourceId string = aoaiPrimary.id
output aoaiSecondaryResourceId string = aoaiSecondary.id
output aoaiPrimaryOpenAiEndpoint string = '${aoaiPrimary.properties.endpoint}openai/v1'
output aoaiSecondaryOpenAiEndpoint string = '${aoaiSecondary.properties.endpoint}openai/v1'
output searchResourceId string = search.id
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output logAnalyticsWorkspaceResourceId string = logs.id
output apimResourceId string = apim.id
output apimGatewayUrl string = apim.properties.gatewayUrl
output acaEnvironmentId string = acaEnv.id
