# Provider Configuration
provider "azurerm" {
  features {}
  subscription_id = "d0e30e9f-c517-420b-97af-46f24f3dc4fa"
  tenant_id       = "ee949117-6c2c-4b2c-bb35-affcb976f574"
}
 
# Create Resource Group in South Africa North
resource "azurerm_resource_group" "elk" {
  name     = "RSG-FALCORP-DEV"
  location = "South Africa North"
}
 
# Create Virtual Network
resource "azurerm_virtual_network" "elk_vnet" {
  name                = "elk-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.elk.location
  resource_group_name = azurerm_resource_group.elk.name
}
 
# Create Subnet
resource "azurerm_subnet" "elk_subnet" {
  name                 = "elk-subnet"
  resource_group_name  = azurerm_resource_group.elk.name
  virtual_network_name = azurerm_virtual_network.elk_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}
 
# Create Network Security Group and Rules
resource "azurerm_network_security_group" "elk_nsg" {
  name                = "elk-nsg"
  location            = azurerm_resource_group.elk.location
  resource_group_name = azurerm_resource_group.elk.name
 
  security_rule {
    name                       = "Allow-SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
 
  security_rule {
    name                       = "Allow-Elasticsearch"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9200"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
 
  security_rule {
    name                       = "Allow-Kibana"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5601"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
 
  # Allow Logstash
  security_rule {
    name                       = "Allow-Logstash"
    priority                   = 1004
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5044"  # Default Logstash Beats port
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
 
# Create Public IP Address
resource "azurerm_public_ip" "elk_public_ip" {
  name                = "elk-public-ip"
  location            = azurerm_resource_group.elk.location
  resource_group_name = azurerm_resource_group.elk.name
  allocation_method   = "Static"
}
 
# Create Network Interface
resource "azurerm_network_interface" "elk_nic" {
  name                = "elk-nic"
  location            = azurerm_resource_group.elk.location
  resource_group_name = azurerm_resource_group.elk.name
 
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.elk_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.elk_public_ip.id
  }
}
 
# Associate the Network Security Group with the NIC
resource "azurerm_network_interface_security_group_association" "elk_nic_nsg" {
  network_interface_id      = azurerm_network_interface.elk_nic.id
  network_security_group_id  = azurerm_network_security_group.elk_nsg.id
}
 
# Create Ubuntu 18.04 Virtual Machine and Install Elasticsearch and Kibana
resource "azurerm_virtual_machine" "elk_vm" {
  name                  = "elk-vm"
  location              = azurerm_resource_group.elk.location
  resource_group_name   = azurerm_resource_group.elk.name
  network_interface_ids = [azurerm_network_interface.elk_nic.id]
  vm_size               = "Standard_B2s"
 
  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
 
  storage_os_disk {
    name              = "elk-os-disk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
 
  os_profile {
    computer_name  = "elk-vm"
    admin_username = var.admin_username
    admin_password = var.admin_password
  }
 
  os_profile_linux_config {
    disable_password_authentication = false
  }
 
  tags = {
    environment = "development"
  }
 
  # Provisioner to install Elasticsearch and Kibana
  provisioner "remote-exec" {
    inline = [
      # Add Elastic’s signing key
      "wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -",
 
      # Install apt-transport-https
      "sudo apt-get update",
      "sudo apt-get install -y apt-transport-https",
 
      # Add Elastic's repository to sources.list.d
      "echo 'deb https://artifacts.elastic.co/packages/7.x/apt stable main' | sudo tee -a /etc/apt/sources.list.d/elastic-7.x.list",
 
      # Update repositories and install Elasticsearch
      "sudo apt-get update && sudo apt-get install -y elasticsearch",
 
      # Configure Elasticsearch for external access
      "sudo bash -c 'echo \"network.host: 0.0.0.0\" >> /etc/elasticsearch/elasticsearch.yml'",
      "sudo bash -c 'echo \"http.port: 9200\" >> /etc/elasticsearch/elasticsearch.yml'",
      "echo 'discovery.type: single-node' | sudo tee -a /etc/elasticsearch/elasticsearch.yml",
 
      # Start Elasticsearch
      "sudo service elasticsearch start",
 
      # Install Kibana
      "sudo apt-get install -y kibana",
 
      # Configure Kibana to connect to Elasticsearch
      "sudo bash -c 'echo \"server.host: 0.0.0.0\" >> /etc/kibana/kibana.yml'",
      "sudo bash -c 'echo \"elasticsearch.hosts: [\\\"http://${azurerm_public_ip.elk_public_ip.ip_address}:9200\\\"]\" >> /etc/kibana/kibana.yml'",
 
      # Enable and start Kibana
      "sudo systemctl enable kibana",
      "sudo service kibana start",
 
      # Health check for Kibana
      "until curl -s http://${azurerm_public_ip.elk_public_ip.ip_address}:5601; do sleep 5; done",
 
      # Install Logstash
      "sudo apt-get install -y logstash"
  ]
    connection {
      type     = "ssh"
      user     = var.admin_username
      password = var.admin_password
      host     = azurerm_public_ip.elk_public_ip.ip_address
      timeout  = "10m"
    }
  }
}
