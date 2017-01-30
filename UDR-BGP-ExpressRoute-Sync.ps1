<#
    .SYNOPSIS
        This Azure Automation runbook automates syncing of the BGP/ExpressRoutes routing entries into the UDR route table. 

    .DESCRIPTION
        The runbook implements a solution for scheduled power management of Azure virtual machines in combination with tags
        on virtual machines or resource groups which define a shutdown schedule. Each time it runs, the runbook looks for all
        virtual machines or resource groups with a tag named "AutoShutdownSchedule" having a value defining the schedule, 
        e.g. "10PM -> 6AM". It then checks the current time against each schedule entry, ensuring that VMs with tags or in tagged groups 
        are shut down or started to conform to the defined schedule.

        This is a PowerShell runbook. It requires the AzureRM.Network and AzureRM.profile modues to be installed.

        This runbook requires the "Azure" module which are present by default in Azure Automation accounts. This runbook also requires 
        the "AzureRM.profile" and "AzureRM.Network" modules which need to be added into the Azure Automation account.

    .PARAMETER NGF_VM_IFC_Name
        The name of the interface that has the routing information towards BGP/ExpressRoute

    .PARAMETER NGF_VM_IFC_RG
        The Resource Group containing the network interface references in NGF_VM_IFC_Name

    .PARAMETER NGF_VM_IP
        The private IP address of the Barracuda NextGen Firewall. This will be used to route the traffic to 

    .PARAMETER RT_Name
        The name of the route table that needs to be updated. Traffic from the atteched subnets needs to be send to the Barracuda NextGen Firewall 

    .PARAMETER RT_RG
        The Resource Group containing the route table

    .PARAMETER Simulate
        If $true, the runbook will not perform any power actions and will only simulate evaluating the tagged schedules. Use this
        to test your runbook to see what it will do when run normally (Simulate = $false).

    .NOTES
        AUTHOR: Barracuda Networks - Joeri Van Hoof (jvanhoof@barracuda.com)
        LASTEDIT: 30 January 2016
#>

param(
    [parameter(Mandatory=$true)]
    [String] $NGF_VM_IFC_Name = "JVH5-NIC-LNX",
    [parameter(Mandatory=$true)]
    [String] $NGF_VM_IFC_RG = "JVH5-RG",
    [parameter(Mandatory=$true)]
    [String] $NGF_VM_IP = "172.16.136.4",
    [parameter(Mandatory=$true)]
    [String] $RT_Name = "JVH11RTWEB",
    [parameter(Mandatory=$true)]
    [String] $RT_RG = "JVH11",
    [parameter(Mandatory=$false)]
    [bool] $Simulate = $false
)

$VERSION = "1.0"

$src = @{}
$dst = @{}

# Variable to track if we need to save any changes
$Update = 0

function Get-RouteName($addressPrefix) {
    $ip = $addressPrefix.Split('/');
    $ip2 = ($ip[0].Split('.') | foreach {"{0:000}" -f [int]$_}) -join ''
    return "R" + $ip2 + "M" + $ip[1]
}

$connectionName = "AzureRunAsConnection"
try {
    # Get the connection "AzureRunAsConnection "
    $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

    "Logging in to Azure..."
    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
} catch {
    if (!$servicePrincipalConnection) {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

try {
    # Reading the NGF subnet routetable. This routetable contains the BGP/ExpressRoutes that need to be duplicated
    $RT1 = Get-AzureRmEffectiveRouteTable -NetworkInterfaceName $NGF_VM_IFC_Name -ResourceGroupName $NGF_VM_IFC_RG
    foreach ($element in $RT1) {
        if( $element.NextHopType.CompareTo("VirtualNetworkGateway") -eq 0 ) {
            $src.add($element.AddressPrefix.Item(0), $element.Name)
        }
    }

    # Reading the route table that needs updating
    $RT2 = Get-AzureRmRouteTable -Name $RT_Name -ResourceGroupName $RT_RG
    foreach ($element in $RT2.Routes) {
        if( $element.NextHopType.CompareTo("VirtualAppliance") -eq 0 ) {
            $dst.Add($element.AddressPrefix, $element.Name)
        }
    }

    # Add missing routes to the route Table.
    foreach($element in $src.Keys) {
        if($dst.Keys -notcontains $element) {
            $routename = $src.Get_Item($element)
            if( !$routename ) {
                $routename = Get-RouteName($element)
            }
            Write-Host "Adding route $element with name $routename to routetable $RT_Name"
            $Update = 1
            if(!$Simulate) {
                Add-AzureRmRouteConfig -Name $routename -AddressPrefix $element -NextHopType VirtualAppliance -NextHopIpAddress $NGF_VM_IP -RouteTable $RT2
            }
        }
    }

    # Remove routes that are no longer in the BGP/ExpressRoute list
    # Caveat: Any route in the route table that doesn't have the naming convention given by this script will not be deleted.
    foreach($element in $dst.Keys) {
        if($src.Keys -notcontains $element) {
            $routename = $dst.Get_Item($element)
            $routename = Get-RouteName($element)
            if( $routename -eq $dst.Get_Item($element) ) {
                Write-Host "Removing route $element with name $routename to routetable $RT_Name"
                $Update = 1
                if(!$Simulate) {
                    Remove-AzureRmRouteConfig -Name $routename -RouteTable $RT2
                }
            }
        }
    }

    # only if there are updates to the routes an update is pushed to the routetable
    if( $Update ) {
        Write-Host "Saving routetable $RT_Name"
        if(!$Simulate) {
            Set-AzureRmRouteTable -RouteTable $RT2
        } else {
            echo $RT2
        }
    }

} catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}

