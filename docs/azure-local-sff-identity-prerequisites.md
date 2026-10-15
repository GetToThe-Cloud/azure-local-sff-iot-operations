---
title: "Azure Local | Small Form Factor – Checking the Identity Prerequisites"
date: 2026-10-15
categories: [azure, azure-local, infrastructure]
tags: ["Azure", "Azure Local", "Small Form Factor", "RBAC", "PowerShell"]
excerpt: "Provisioning an Azure Local small form factor machine fails late when your permissions are wrong. This post walks through a PowerShell script that checks Azure RBAC, PIM eligibility, the Entra directory role and the operator security group up front, using only az login for tokens and plain REST calls to ARM and Microsoft Graph."
permalink: /azure-local-small-form-factor-checking-the-identity-prerequisites/
series: "Azure Local small form factor with Azure IoT Operations"
---

The first thing the small form factor preparation guide checks is not your hardware. It is you.

Azure Local small form factor is still in preview, and the provisioning flow assumes that the account you use already has the right Azure roles, the right Entra role, and a security group for the people who will operate the machine. If one of those is missing, you find out halfway through provisioning, not at the start.

So before the lab machine in this series gets provisioned, I wanted a single command that tells me whether my account is ready. The result is `Test-AzLocalSffPrereqs.ps1`: a read-only PowerShell script that checks the three identity prerequisites from the Microsoft documentation and returns a clear PASS, WARN or FAIL for each.

## What does Microsoft actually require?

The preparation article for small form factor lists the permission checks. For the subscription, you need one of two role combinations:

- **Owner**
- **Contributor** together with **Role Based Access Control Administrator**

The role assignment must be both **Active** and **Permanent**, and the permissions must apply to the resource group where you will provision the machines. If your assignment is not permanent, the docs point out that you might need to elevate temporarily before you run the deployment commands.

On the Entra side, you need at least the Directory Readers role at tenant level. Higher-privileged roles also satisfy the requirement.

Finally, provisioning uses a Microsoft Entra ID security group to authorize access to the provisioned machine and its Arc resources. You either create a new group or reuse an existing one, and you add the users who will manage, connect to or troubleshoot the machines.

None of this is complicated. It is just easy to get one detail wrong, especially the "active and permanent" part when your organization uses Privileged Identity Management.

## Why not just look in the portal?

You can check all of this in the portal: Access control (IAM) on the subscription, Roles and administrators in Entra ID, and the group blade.

The problem is that the portal answers one question per blade, and it does not tell you how the pieces combine. A Contributor assignment through a group, an RBAC Administrator role that is only eligible in PIM, and an operator group that turns out to be a Microsoft 365 group are three different blades and three different conclusions.

A script gives the same answer every time, can run before every provisioning attempt, and can fail a pipeline when something is missing.

## How the script works

The script uses the Azure CLI for one thing only: the login context and the access tokens. Every check after that is a direct REST call to Azure Resource Manager or Microsoft Graph. That keeps the dependencies small. There are no Az or Microsoft Graph PowerShell modules to install, and it runs in both Windows PowerShell 5.1 and PowerShell 7.

Run it after `az login`, against the subscription and resource group you are going to use:

```powershell
az login --tenant <tenant-id>

.\Test-AzLocalSffPrereqs.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroup 'rg-sff-lab' `
  -OperatorGroup 'sg-azlocal-sff-operators'
```

`-SubscriptionId` is mandatory and has to be a valid subscription GUID, so the script never silently checks whatever subscription happens to be the default in your az context. `-ResourceGroup` is optional. When you leave it out, or when the resource group does not exist yet, the RBAC check runs at subscription level. `-OperatorGroup` accepts a display name or an object ID.

![Terminal output of Test-AzLocalSffPrereqs.ps1 in the lab: the account, subscription, tenant and scope header, the per-role state lines, the three results and the summary table](placeholder)

### Check 1: Azure RBAC, including PIM

The first check lists the role assignments that apply to your account at the target scope. The `assignedTo()` filter does the heavy lifting here, because it also returns assignments you receive through group membership, transitively:

```powershell
$assignments = @(@(Invoke-Paged -Token $armToken `
    -Uri "$arm$targetScope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$principalId')") |
    Where-Object { Test-ScopeApplies $_.properties.scope $targetScope })
```

`Test-ScopeApplies` keeps only assignments at the target scope or above it, so a Contributor role on the subscription counts for the resource group, but a role on another resource group does not.

An assignment alone does not tell you whether it is permanent. For that, the script reads the PIM schedule instances for the same scope. A permanent assignment shows up with `assignmentType` set to `Assigned` and no `endDateTime`:

```powershell
$perm = @($inst | Where-Object { $_.properties.assignmentType -eq 'Assigned' -and -not $_.properties.endDateTime })
```

Anything with an end date is an activation or a time-bound assignment. The script also reads the eligibility schedule instances, so a role that is only eligible and not yet activated is reported as such instead of silently missing.

That results in four outcomes:

- **PASS**: Owner, or Contributor plus Role Based Access Control Administrator, both permanent.
- **WARN**: the right roles are active but time-bound, so they work until the activation expires. Also a warning for Contributor plus User Access Administrator, which gives comparable rights but is not the documented combination.
- **FAIL**: no qualifying roles, with a hint listing any roles that are eligible in PIM and only need activation.
- **FAIL** as well when the script cannot read role assignments at all, because that almost always means there is no active role on that scope.

### Check 2: the Entra directory role

The second check asks Microsoft Graph which directory roles your account holds, again transitively, so roles assigned through a role-assignable group count:

```powershell
$dirRoles = @(Invoke-Paged -Token $graphToken -Uri "$g/$principalPath/transitiveMemberOf/microsoft.graph.directoryRole?`$select=displayName")
```

The result is compared with a list of accepted roles: Directory Readers and roles with more rights, such as Global Reader, Directory Writers and Application Administrator. The docs name Cloud Administrator as an example of a higher role; the closest Entra built-in role is Cloud Application Administrator, so that is the name in the list. The list is a parameter, `-AcceptedDirectoryRoles`, so you can adjust it to your own tenant policy.

When no accepted role is active, the script tries to read the PIM eligibility for directory roles. That call needs Graph permissions an az CLI token does not always carry, so it fails quietly and the check falls back to a plain FAIL. That is a deliberate choice. A check that crashes is worse than a check that says less.

### Check 3: the operator security group

The last check looks up the group, by object ID or by display name, and verifies three things: it exists, `securityEnabled` is true, and it has members. Members are counted transitively, so nested groups work.

It also checks whether you are a member yourself:

```powershell
$memberCheck = Invoke-RestMethod -ErrorAction Stop -Method Post -Headers $graphHeaders -ContentType 'application/json' `
    -Uri "$g/$principalPath/checkMemberGroups" -Body (@{ groupIds = @($grp.id) } | ConvertTo-Json)
```

Not being a member is a warning, not a failure. You can provision a machine for a team you are not part of. But in a lab where you are the only operator, forgetting to add yourself is exactly the mistake you only notice when you try to connect.

Two edge cases are handled explicitly. When more than one group has the same display name, the script lists the object IDs and asks you to pass one of them. When the group is a security-enabled Microsoft 365 group, it passes, but the result says so.

## Using it in a pipeline

The script exits with code 1 when any check fails and 0 otherwise, warnings included. That makes it easy to put in front of a provisioning step:

```powershell
.\Test-AzLocalSffPrereqs.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroup 'rg-sff-lab' `
  -OperatorGroup 'sg-azlocal-sff-operators'

if ($LASTEXITCODE -ne 0) {
    throw 'Azure Local SFF prerequisites not met, provisioning stopped.'
}
```

The summary table is written with a fixed width, so it also stays readable in a pipeline log or a scheduled task transcript.

## What this script does not check

It checks identity, nothing else. It does not register the machine provisioning feature or the resource providers, and it does not validate your hardware, network or the maintenance environment. Those are separate steps in the preparation article.

It also does not change anything. No role is assigned and no group is created. Every call is a read, apart from `checkMemberGroups`, which is a POST that only evaluates membership.

And it checks the account you are logged in with. If provisioning runs under a service principal, log in as that service principal before you run it. The script detects a service principal login and looks it up accordingly.

Sources:

- [Prepare to deploy Azure Local on small form factor devices (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-prepare-to-deploy)
- [List Azure role assignments using the REST API](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-list-rest)
- [Security features for small form factor deployments of Azure Local (preview)](https://learn.microsoft.com/azure/azure-local/small-form-factor/small-form-factor-security)

## I think

Identity is the least visible prerequisite and the most annoying one to discover late. A provisioning run that stops on a missing role costs you time and a second attempt. A script that takes ten seconds costs you almost nothing.

Is my role permanent, or only activated for the next few hours? Does the Entra role come from a direct assignment or from a group? Is the operator group really a security group, and am I in it? Those are the questions to answer before you provision, not after.

Run it before every provisioning attempt in your own lab, adjust the accepted role list to your tenant, and let me know what it caught for you. In the next part the machine itself gets provisioned.

## Download contents

The script is available in the GitHub repository for this series:

- `scripts/Test-AzLocalSffPrereqs.ps1`: the prerequisite check described in this post

https://github.com/GetToThe-Cloud/azure-local-sff-iot-operations

Small form factor is a preview feature. Test everything in a lab subscription before you rely on it for anything else.
