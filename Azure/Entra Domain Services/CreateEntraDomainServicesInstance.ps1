# For more details, refer to:
# https://learn.microsoft.com/en-us/entra/identity/domain-services/powershell-create-instance

# Change the following values to match your deployment.
$AaddsAdminUserUpn = "adminuser@your.domainname.com"
$ResourceGroupName = "yourResourceGroup"
$VnetName = "yourVnet"
$AzureLocation = "westus"
$AzureSubscriptionId = "yourSubscriptionId"
$ManagedDomainName = "your.domainname.com"

# Connect to your Microsoft Entra directory.
Connect-MgGraph -Scopes "Application.ReadWrite.All","Directory.ReadWrite.All"

# Login to your Azure subscription.
Connect-AzAccount
# For regional environments that require specific compliance (e.g., Azure China 21Vianet), use the Environment parameter:
# Connect-AzAccount -Environment AzureChinaCloud

# Create the service principal for Microsoft Entra Domain Services.
New-MgServicePrincipal -AppId "2565bd9d-da50-47d4-8b85-4c97f669dc36"

# First, retrieve the object of the 'AAD DC Administrators' group.
$GroupObject = Get-MgGroup -Filter "DisplayName eq 'AAD DC Administrators'"

# Create the delegated administration group for Microsoft Entra Domain Services if it doesn't already exist.
if (!$GroupObject) {
  $GroupObject = New-MgGroup -DisplayName "AAD DC Administrators" -Description "Delegated group to administer Microsoft Entra Domain Services" -SecurityEnabled:$true -MailEnabled:$false -MailNickName "AADDCAdministrators"
  } else {
  Write-Output "Admin group already exists."
}

# Now, retrieve the object ID of the user you'd like to add to the group.
$UserObjectId = Get-MgUser -Filter "UserPrincipalName eq '$AaddsAdminUserUpn'" | Select-Object Id

# Add the user to the 'AAD DC Administrators' group.
New-MgGroupMember -GroupId $GroupObject.Id -DirectoryObjectId $UserObjectId.Id

# Register the resource provider for Microsoft Entra Domain Services with Resource Manager.
Register-AzResourceProvider -ProviderNamespace Microsoft.AAD

# Create the resource group.
New-AzResourceGroup -Name $ResourceGroupName -Location $AzureLocation

# Create the dedicated subnet for Microsoft Entra Domain Services.
$SubnetName = "default"
$AaddsSubnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix 10.0.0.0/24

#$WorkloadSubnet = New-AzVirtualNetworkSubnetConfig -Name Workloads -AddressPrefix 10.0.1.0/24

# Create the virtual network in which you will enable Microsoft Entra Domain Services.
$Vnet=New-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Location $AzureLocation -Name $VnetName -AddressPrefix 10.0.0.0/16 -Subnet $AaddsSubnet
#,$WorkloadSubnet

$NSGName = "aadds-nsg"

# Create a rule to allow inbound TCP port 3389 traffic from Microsoft secure access workstations for troubleshooting
$nsg201 = New-AzNetworkSecurityRuleConfig -Name AllowRD -Access Allow -Protocol Tcp -Direction Inbound -Priority 201 -SourceAddressPrefix CorpNetSaw -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389

# Create a rule to allow TCP port 5986 traffic for PowerShell remote management
$nsg301 = New-AzNetworkSecurityRuleConfig -Name AllowPSRemoting -Access Allow -Protocol Tcp -Direction Inbound -Priority 301 -SourceAddressPrefix AzureActiveDirectoryDomainServices -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 5986

# Create the network security group and rules
$nsg = New-AzNetworkSecurityGroup -Name $NSGName -ResourceGroupName $ResourceGroupName -Location $AzureLocation -SecurityRules $nsg201,$nsg301

# Get the existing virtual network resource objects and information
$vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $ResourceGroupName
$subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet -Name $SubnetName
$addressPrefix = $subnet.AddressPrefix

# Associate the network security group with the virtual network subnet
Set-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet -AddressPrefix $addressPrefix -NetworkSecurityGroup $nsg
$vnet | Set-AzVirtualNetwork

# Enable Microsoft Entra Domain Services for the directory.
$replicaSetParams = @{
  Location = $AzureLocation
  SubnetId = "/subscriptions/$AzureSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/virtualNetworks/$VnetName/subnets/default"
}
$replicaSet = New-AzADDomainServiceReplicaSetObject @replicaSetParams

$domainServiceParams = @{
  Name = $ManagedDomainName
  ResourceGroupName = $ResourceGroupName
  DomainName = $ManagedDomainName
  ReplicaSet = $replicaSet
}

New-AzADDomainService @domainServiceParams