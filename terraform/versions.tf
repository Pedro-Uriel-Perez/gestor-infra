terraform {
  required_version = ">= 1.17.0"

  required_providers {
    render = {
      source  = "render-oss/render"
      version = "~> 1.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
  }

  # El estado vive fuera del repositorio. Jenkins lo guarda en su volumen:
  #   terraform init -backend-config="path=/var/jenkins_home/terraform/gestor-infra.tfstate"
  backend "local" {}
}

# La llave de API se lee de la variable de entorno RENDER_API_KEY (credencial de Jenkins),
# nunca se escribe en el repositorio.
provider "render" {
  owner_id                   = var.render_owner_id
  wait_for_deploy_completion = true
}
