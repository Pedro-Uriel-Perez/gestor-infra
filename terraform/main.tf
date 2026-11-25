# Infraestructura del Gestor de Proyectos en Render:
#   proyecto "gestor-proyectos" (entorno produccion)
#     ├─ gestor-db        PostgreSQL 18
#     ├─ gestor-api       API REST (Docker, repo gestor-api)       → se conecta a gestor-db por la red interna
#     └─ gestor-frontend  Frontend web (Docker, repo gestor-frontend) → consume gestor-api por HTTPS

resource "render_project" "gestor" {
  name = "gestor-proyectos"
  environments = {
    produccion = {
      name             = "produccion"
      protected_status = "unprotected"
    }
  }
}

# IP pública de quien ejecuta Terraform (Jenkins en el equipo del administrador): es la única
# que puede conectarse a PostgreSQL desde fuera de Render (Ansible carga y verifica la base).
# Se consulta a un servicio de AWS porque Render corre en AWS y el proveedor de internet del
# equipo sale con una IP distinta hacia AWS que hacia otros sitios (incidencia INC-07).
data "http" "mi_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  entorno_id = render_project.gestor.environments["produccion"].id
  ip_admin   = var.ip_admin_cidr != "" ? var.ip_admin_cidr : "${chomp(data.http.mi_ip.response_body)}/32"
}

resource "render_postgres" "db" {
  name           = "gestor-db"
  plan           = var.plan
  region         = var.region
  version        = "18"
  database_name  = "dbgestor"
  database_user  = "gestor"
  environment_id = local.entorno_id

  ip_allow_list = [{
    cidr_block  = local.ip_admin
    description = "Administracion (Jenkins / Ansible)"
  }]
}

# Token que comparten las aplicaciones y Prometheus para proteger /actuator/prometheus
resource "random_password" "metricas" {
  length  = 40
  special = false
}

locals {
  # postgresql://usuario:clave@host[:puerto]/base → piezas para el JDBC de Spring Boot
  db = regex(
    "^postgres(?:ql)?://(?P<usuario>[^:]+):(?P<clave>[^@]+)@(?P<host>[^/:]+)(?::(?P<puerto>\\d+))?/(?P<base>.+)$",
    render_postgres.db.connection_info.internal_connection_string
  )
}

# OpenTelemetry (agente Java incluido en las imágenes): trazas, métricas y logs → Grafana Cloud.
# Las variables van en un grupo de entorno vinculado a los dos servicios: actualizar un servicio
# web gratuito con el proveedor de Render falla ("maintenance mode can only be configured for
# non-free tier services"), mientras que el grupo se actualiza sin tocar los servicios (INC-17).
# El nombre de cada servicio (OTEL_SERVICE_NAME) ya viene en su Dockerfile.
# El encabezado lleva "%20" en lugar del espacio porque el agente decodifica los valores.
resource "render_env_group" "otel" {
  name           = "otel-grafana-cloud"
  environment_id = local.entorno_id
  env_vars = {
    OTEL_SDK_DISABLED           = { value = "false" }
    OTEL_EXPORTER_OTLP_ENDPOINT = { value = var.otlp_endpoint }
    OTEL_EXPORTER_OTLP_PROTOCOL = { value = "http/protobuf" }
    OTEL_EXPORTER_OTLP_HEADERS  = { value = "Authorization=Basic%20${base64encode("${var.otlp_instance_id}:${var.otlp_token}")}" }
    OTEL_RESOURCE_ATTRIBUTES    = { value = "deployment.environment.name=produccion,service.namespace=gestor-proyectos" }
    OTEL_METRIC_EXPORT_INTERVAL = { value = "30000" }
  }
}

resource "render_env_group_link" "otel" {
  env_group_id = render_env_group.otel.id
  service_ids  = [render_web_service.api.id, render_web_service.frontend.id]
}

resource "render_web_service" "api" {
  name              = "gestor-api"
  plan              = var.plan
  region            = var.region
  environment_id    = local.entorno_id
  health_check_path = "/actuator/health/liveness"

  runtime_source = {
    docker = {
      repo_url        = var.repo_api
      branch          = var.rama
      context         = "."
      dockerfile_path = "./Dockerfile"
      # Render no despliega solo con cada commit: despliega el pipeline (GitHub Actions)
      # cuando pasan las pruebas, el Quality Gate, Trivy y Semgrep.
      auto_deploy = false
    }
  }

  env_vars = {
    DB_URL         = { value = "jdbc:postgresql://${local.db.host}:${coalesce(local.db.puerto, "5432")}/${local.db.base}?stringtype=unspecified" }
    DB_USER        = { value = local.db.usuario }
    DB_PASSWORD    = { value = local.db.clave }
    METRICAS_TOKEN = { value = random_password.metricas.result }
    SQL_EN_LOGS    = { value = "false" }
  }

  # Render rechaza actualizar servicios web gratuitos con este proveedor ("maintenance mode can only
  # be configured for non-free tier services"): las variables se fijan al crear el servicio y los
  # cambios posteriores van en grupos de entorno (render_env_group). Sin esto, cambiar la IP
  # autorizada de la base recalcula la conexión y fuerza una actualización que falla (INC-17).
  lifecycle {
    ignore_changes = [env_vars]
  }
}

resource "render_web_service" "frontend" {
  name              = "gestor-frontend"
  plan              = var.plan
  region            = var.region
  environment_id    = local.entorno_id
  health_check_path = "/actuator/health/liveness"

  runtime_source = {
    docker = {
      repo_url        = var.repo_frontend
      branch          = var.rama
      context         = "."
      dockerfile_path = "./Dockerfile"
      auto_deploy     = false
    }
  }

  env_vars = {
    API_URL        = { value = render_web_service.api.url }
    METRICAS_TOKEN = { value = random_password.metricas.result }
  }

  # Render rechaza actualizar servicios web gratuitos con este proveedor ("maintenance mode can only
  # be configured for non-free tier services"): las variables se fijan al crear el servicio y los
  # cambios posteriores van en grupos de entorno (render_env_group). Sin esto, cambiar la IP
  # autorizada de la base recalcula la conexión y fuerza una actualización que falla (INC-17).
  lifecycle {
    ignore_changes = [env_vars]
  }
}
