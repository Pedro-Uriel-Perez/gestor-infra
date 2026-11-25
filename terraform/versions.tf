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
    grafana = {
      source  = "grafana/grafana"
      version = "4.53.0"
    }
  }

  # Estado remoto en PostgreSQL (Neon, plan gratuito), con bloqueo para que dos ejecuciones no
  # modifiquen la infraestructura a la vez. La cadena de conexión llega en la variable de entorno
  # PG_CONN_STR (secreto de GitHub Actions), nunca se escribe en el repositorio.
  backend "pg" {
    schema_name = "gestor_infra"
  }
}

# La llave de API se lee de la variable de entorno RENDER_API_KEY (secreto de GitHub Actions),
# nunca se escribe en el repositorio.
provider "render" {
  owner_id                   = var.render_owner_id
  wait_for_deploy_completion = true
}

# Grafana del stack (tablero, carpeta y alertas). El token de la service account llega en la
# variable de entorno GRAFANA_AUTH (secreto de GitHub Actions).
provider "grafana" {
  url = var.grafana_url
}

# API de Grafana Cloud: datos del stack e instalación del monitoreo sintético
provider "grafana" {
  alias                     = "cloud"
  cloud_access_policy_token = var.otlp_token
}

# Monitoreo sintético: usa el token que entrega su instalación
provider "grafana" {
  alias           = "sm"
  sm_url          = grafana_synthetic_monitoring_installation.sm.stack_sm_api_url
  sm_access_token = grafana_synthetic_monitoring_installation.sm.sm_access_token
}
