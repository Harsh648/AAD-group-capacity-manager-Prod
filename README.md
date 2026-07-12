  # AAD-group-capacity-manager-Prod


> Automated Microsoft 365 License Balancing Solution using Azure Functions and Microsoft Graph API

[https://img.shields.io/badge/Azure-Functions-blue
https://img.shields.io/badge/PowerShell-7.x-blue
https://img.shields.io/badge/Microsoft-Graph-green
https://img.shields.io/badge/License-Internal-orange]
(https://img.shields.io/badge/Azure_Functions-Timer_Trigger-blue
https://img.shields.io/badge/PowerShell-7.4-blue
https://img.shields.io/badge/Microsoft_Graph-API-green
https://img.shields.io/badge/Azure-Functions-0078D4
https://img.shields.io/badge/Status-Production-success)

---

# Overview

ABFRL License Balancer is an Azure Function-based automation solution designed to manage Microsoft 365 license allocation across multiple Business Units (BUs).

The solution automatically:

- Maintains E1 license capacity limits.
- Moves overflow users from E1 groups to EOP1 groups.
- Promotes eligible users from EOP1 to E1 when capacity becomes available.
- Ensures fair and consistent license allocation based on user creation date.
- Executes periodically using Azure Function Timer Trigger.
- Uses Microsoft Graph PowerShell SDK for all Entra ID operations.

---

# Business Problem

Managing Microsoft 365 license allocation manually across multiple business units is challenging because:

- License counts are limited.
- User onboarding is continuous.
- Capacity must be maintained within budget constraints.
- Manual redistribution is error-prone.
- New users often consume expensive licenses before older assigned users are considered.

This solution automatically balances license assignments while maintaining configured capacity thresholds.

---

# Solution Architecture

```text
                      Azure Timer Trigger
                              |
                              v
                      ABFRL License Balancer
                              |
                              v
                    Microsoft Graph API
                              |
           ------------------------------------------------
           |                    |                         |
           v                    v                         v
         E1 Group            EOP1 Group               User Objects

Key Features

✅ Automated License Balancing

✅ Microsoft Graph Integration

✅ Azure Function Timer Trigger

✅ Retry Logic for Graph Calls

✅ User Creation Date Based Priority

✅ Multi-Business Unit Support

✅ Detailed Operational Logging

✅ Scalable Configuration Model

✅ Low Operational Overhead

Business Units Supported

Current implementation supports:

Business UnitABFRL Corporate
Ethnic Business
International Brands
Indivinity
Pantaloons
TCNS
Jaypore
TMRW & NautiNati
Sabyasachi
ShantanuNikhil
House Of Masaba
Tarun Tahiliani
Madura Fashion and Lifestyle
TEST-LICENSE-ASSIGNMENT

Technology Stack

Component	TechnologyCompute	Azure Functions
Runtime	PowerShell 7
Identity	Managed Identity / Service Principal
Directory Service	Microsoft Entra ID
API Layer	Microsoft Graph
Logging	Application Insights
Scheduling	Azure Timer Trigger
Functional Flow

Step 1 – Function Execution

Azure Timer Trigger starts execution according to configured schedule.

Example:

Every 5 minutes

Step 2 – Connect to Microsoft Graph

The function authenticates using Managed Identity or App Registration.

Connect-MgGraph


Log Example:

Connected to Microsoft Graph.

Step 3 – Load Business Unit Configuration

Configuration contains:

Business Unit Name
E1 Group ID
EOP1 Group ID
E1 Capacity
EOP1 Capacity


Example:

{
    "Name": "ABFRL Corporate",
    "E1Group": "6ae308d9-60db-46c1-add0-7477da770eea",
    "EOP1Group": "7264da80-5cf9-4ce4-9baa-735a62dc6257",
    "E1Cap": 5,
    "EOP1Cap": 5
}

Step 4 – Retrieve Group Members

The solution collects:

Current E1 Members
Current EOP1 Members


using:

Get-MgGroupMember

Step 5 – Evaluate E1 Capacity

Current Count:

Current E1 User Count


Configured:

E1 Cap


Decision:

E1 Count > E1 Cap ?

Step 6 – Overflow Handling

When E1 exceeds capacity:

Overflow Users
= E1 Count - E1 Capacity


Affected users are selected based on:

Newest Created Users


Action:

Remove from E1
Add to EOP1

Step 7 – Promotion Logic

When E1 has available capacity:

Available Slots
= E1 Cap - E1 Count


Users are selected from EOP1 based on:

Oldest Created Users


Action:

Remove from EOP1
Add to E1

Step 8 – Generate Summary

For every business unit:

Final E1 Count
Final EOP1 Count


Example:

================ SUMMARY =================

Business Unit : ABFRL Corporate

Final E1      : 5
Final EOP1    : 3

===========================================

User Prioritization Logic

Users are ordered using:

CreatedDateTime


Ascending order.

Example:

User A  -> Jan 2022
User B  -> Feb 2022
User C  -> Mar 2024
User D  -> Apr 2026


Priority:

User A
User B
User C
User D


Oldest users are retained or promoted first.

Core Functions
Connect-ToGraph

Authenticates against Microsoft Graph.

Responsibility
Initialize Graph connection
Validate permissions
Establish session
Invoke-WithRetry

Provides resiliency for transient Graph failures.

Handles
HTTP 429
Service throttling
Temporary network failures
Graph service interruptions
Get-GroupUserIds

Retrieves user members from a specific Entra group.

Input
GroupId

Output
User Object IDs

Get-UsersOrderedByCreation

Retrieves and sorts users.

Sorting Criteria
CreatedDateTime

Output
Oldest → Newest

Add-UserToGroup

Adds a user to a target security group.

Used for:

EOP1 → E1


and

E1 → EOP1


transitions.

Remove-UserFromGroup

Removes user membership from source group.

Logging

The solution provides detailed operational logs.

Example:

ABFRL License Balancer Started

Connected to Microsoft Graph.

Business Units Loaded : 14

PROCESSING BU : ABFRL Corporate

Current E1 User Count : 5

Available E1 Slots : 0

Current EOP1 Count : 2

SUMMARY

Final E1 : 5

Final EOP1 : 2

Sample Execution Flow
Start
 |
 v
Connect Graph
 |
 v
Load BU Configuration
 |
 v
Read E1 Users
 |
 v
Read EOP1 Users
 |
 v
Check E1 Capacity
 |
 +----Overflow?----YES----> Move E1 → EOP1
 |
 NO
 |
 v
Available Slots?
 |
 +----YES----------> Move EOP1 → E1
 |
 NO
 |
 v
Generate Summary
 |
 v
End

Required Microsoft Graph Permissions
Application Permissions
Group.Read.All

GroupMember.ReadWrite.All

User.Read.All

Directory.Read.All


Recommended:

Directory.ReadWrite.All


(if membership updates require it)

Azure Function Configuration

Example:

{
  "IsEncrypted": false,
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "powershell",
    "AzureWebJobsStorage": "<storage-account>"
  }
}

Monitoring
Azure Portal

Monitor:

Function Executions
Failures
Duration
Memory Consumption
Application Insights

Query execution logs:

traces
| order by timestamp desc

Common Troubleshooting
Current E1 User Count = 0

Possible causes:

Incorrect Group ID

Verify:

Get-MgGroup `
    -GroupId "<GroupId>"

Empty Group

Verify:

Get-MgGroupMember `
    -GroupId "<GroupId>" `
    -All

Nested Groups

Current implementation counts:

#microsoft.graph.user


If group contains child groups:

#microsoft.graph.group


Counts may appear as:

Current E1 User Count : 0


even when users exist indirectly.

Permission Issue

Verify Graph permissions:

Group.Read.All
GroupMember.ReadWrite.All

Operational Recommendations

✅ Maintain separate TEST business unit.

✅ Validate Group IDs before deployment.

✅ Review Application Insights regularly.

✅ Enable alerting for failed executions.

✅ Periodically validate license counts.

✅ Keep Microsoft.Graph PowerShell modules updated.

Security Considerations
Use Managed Identity whenever possible.
Avoid storing credentials in code.
Restrict Graph permissions using least privilege.
Monitor all membership changes through audit logs.
Use RBAC controls for Azure Function administration.
Future Enhancements
Dynamic capacity management
Configuration through Azure App Configuration
Capacity dashboards using Power BI
Email notifications
Teams notifications
Support for nested groups
Automatic anomaly detection
Self-healing retry workflows
Example Success Log
Business Units Processed : 14

Execution Time :
07/12/2026 09:40:14

Maintainers

ABFRL IT – Digital Workplace & Collaboration Team
Owner: Harsha V
Platform: Microsoft Azure
License: Internal Enterprise Use Only


This version is GitHub enterprise-grade, with architecture, flow diagrams, troubleshooting, security, monitoring, operational guidelines, and future roadmap sections suitable for production repositories and audit reviews.
