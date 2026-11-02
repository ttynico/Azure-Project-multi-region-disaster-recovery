############################################
# Protected workload: two Ubuntu VMs in the primary region
############################################

resource "azurerm_network_interface" "vm" {
  for_each            = local.vms
  name                = "nic-${each.value.name}"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.primary.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = azurerm_public_ip.primary[each.key].id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each              = local.vms
  name                  = each.value.name
  computer_name         = each.value.name
  location              = azurerm_resource_group.primary.location
  resource_group_name   = azurerm_resource_group.primary.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    name                 = "osdisk-${each.value.name}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  # Ubuntu 22.04 LTS Gen2: on the ASR Azure-to-Azure supported OS list.
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Managed boot diagnostics: lets you see the serial console of a failed-over VM.
  boot_diagnostics {}

  custom_data = base64encode(templatefile("${path.module}/cloud-init/status-page.yaml", {
    tier = each.value.tier
  }))

  tags = merge(local.tags, { tier = each.value.tier, dr_protected = "true" })
}
