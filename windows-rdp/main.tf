terraform {
  required_version = ">= 1.0"

  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 0.17"
    }
  }
}

variable "agent_id" {
  type        = string
  description = "The ID of a Coder agent."
}

variable "resource_id" {
  type        = string
  description = "The ID of the primary Coder resource (e.g. VM)."
}

variable "admin_username" {
  type    = string
  default = "Administrator"
}

variable "admin_password" {
  type      = string
  default   = "coderRDP!"
  sensitive = true
}

resource "coder_script" "windows-rdp" {
  agent_id     = var.agent_id
  display_name = "windows-rdp"
  icon         = "https://svgur.com/i/158F.svg" # TODO: add to Coder icons
  script = <<EOF
  function Set-AdminPassword {
      param (
          [string]$adminPassword
      )
      # Set admin password
      Get-LocalUser -Name "${var.admin_username}" | Set-LocalUser -Password (ConvertTo-SecureString -AsPlainText $adminPassword -Force)
      # Enable admin user
      Get-LocalUser -Name "${var.admin_username}" | Enable-LocalUser
  }

  function Configure-RDP {
      # Enable RDP
      New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0 -PropertyType DWORD -Force
      # Disable NLA
      New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 0 -PropertyType DWORD -Force
      New-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "SecurityLayer" -Value 1 -PropertyType DWORD -Force
      # Enable RDP through Windows Firewall
      Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
  }

  function Install-DevolutionsGateway {
    # Define the module name and version
    $moduleName = "DevolutionsGateway"
    $moduleVersion = "2024.1.5"

    # This should cause Google Cloud to break (doing this on purpose)
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop
    Install-Module -Name $moduleName -RequiredVersion $moduleVersion -Force

    # Construct the module path for system-wide installation
    $moduleBasePath = "C:\Windows\system32\config\systemprofile\Documents\PowerShell\Modules\$moduleName\$moduleVersion"
    $modulePath = Join-Path -Path $moduleBasePath -ChildPath "$moduleName.psd1"

    # Import the module using the full path
    Import-Module $modulePath
    Install-DGatewayPackage

    # Configure Devolutions Gateway
    $Hostname = "localhost"
    $HttpListener = New-DGatewayListener 'http://*:7171' 'http://*:7171'
    $WebApp = New-DGatewayWebAppConfig -Enabled $true -Authentication None
    $ConfigParams = @{
      Hostname = $Hostname
      Listeners = @($HttpListener)
      WebApp = $WebApp
    }
    Set-DGatewayConfig @ConfigParams
    New-DGatewayProvisionerKeyPair -Force

    # Configure and start the Windows service
    Set-Service 'DevolutionsGateway' -StartupType 'Automatic'
    Start-Service 'DevolutionsGateway'
  }

  function Patch-Devolutions-HTML {
    $root = "C:\Program Files\Devolutions\Gateway\webapp\client"
    $devolutionsHtml = "$root\index.html"
    $patch = '<script defer id="coder-patch" src="coder.js"></script>'
    
    # Always copy the file in case we change it.
    @'
${templatefile("${path.module}/devolutions-patch.js", {
  CODER_USERNAME : var.admin_username,
  CODER_PASSWORD : var.admin_password,
})}
'@ | Set-Content "$root\coder.js"

    # Only inject the src if we have not before.
    $isPatched = Select-String -Path "$devolutionsHtml" -Pattern "$patch" -SimpleMatch
    if ($isPatched -eq $null) {
      (Get-Content $devolutionsHtml).Replace('</app-root>', "</app-root>$patch") | Set-Content $devolutionsHtml
    }
  }

  Set-AdminPassword -adminPassword "${var.admin_password}"
  Configure-RDP
  Install-DevolutionsGateway
  Patch-Devolutions-HTML

  EOF

run_on_start = true
}

resource "coder_app" "windows-rdp" {
  agent_id     = var.agent_id
  slug         = "web-rdp"
  display_name = "Web RDP"
  url          = "http://localhost:7171"
  icon         = "https://svgur.com/i/158F.svg"
  subdomain    = true

  healthcheck {
    url       = "http://localhost:7171"
    interval  = 5
    threshold = 15
  }
}

resource "coder_app" "rdp-docs" {
  agent_id     = var.agent_id
  display_name = "Local RDP"
  slug         = "rdp-docs"
  icon         = "https://raw.githubusercontent.com/matifali/logos/main/windows.svg"
  url          = "https://coder.com/docs/v2/latest/ides/remote-desktops#rdp-desktop"
  external     = true
}

# For some reason this is not rendering, commented out for now
# resource "coder_metadata" "rdp_details" {
#   resource_id = var.resource_id
#   daily_cost  = 0
#   item {
#     key   = "Host"
#     value = "localhost"
#   }
#   item {
#     key   = "Port"
#     value = "3389"
#   }
#   item {
#     key   = "Username"
#     value = "Administrator"
#   }
#   item {
#     key       = "Password"
#     value     = var.admin_password
#     sensitive = true
#   }
# }
