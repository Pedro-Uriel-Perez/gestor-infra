variable "render_owner_id" {
  description = "Workspace de Render donde se crean los recursos. Llega en TF_VAR_render_owner_id (archivo .env de Jenkins)"
  type        = string
}

variable "region" {
  description = "Región de Render. Ohio es la más cercana a México de las disponibles"
  type        = string
  default     = "ohio"
}

variable "plan" {
  description = "Plan de los servicios web y de la base de datos"
  type        = string
  default     = "free"
}

variable "rama" {
  description = "Rama de los repositorios que se despliega"
  type        = string
  default     = "main"
}

variable "repo_api" {
  description = "Repositorio del backend (API REST)"
  type        = string
  default     = "https://github.com/Pedro-Uriel-Perez/gestor-api"
}

variable "repo_frontend" {
  description = "Repositorio del frontend"
  type        = string
  default     = "https://github.com/Pedro-Uriel-Perez/gestor-frontend"
}

variable "ip_admin_cidr" {
  description = "IP (CIDR) que puede conectarse desde fuera a PostgreSQL. Vacío = la IP pública actual de quien ejecuta Terraform"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- Observabilidad (Grafana Cloud)
# Los valores llegan como TF_VAR_* desde los secretos de GitHub Actions; ninguno se versiona.

variable "grafana_url" {
  description = "URL del stack de Grafana Cloud (https://<stack>.grafana.net)"
  type        = string
}

variable "grafana_stack_slug" {
  description = "Nombre corto del stack de Grafana Cloud"
  type        = string
}

variable "otlp_endpoint" {
  description = "Gateway OTLP de Grafana Cloud (región us-east-2, la misma de Render)"
  type        = string
  default     = "https://otlp-gateway-prod-us-east-2.grafana.net/otlp"
}

variable "otlp_instance_id" {
  description = "Id de instancia del stack para autenticarse en el gateway OTLP"
  type        = string
}

variable "otlp_token" {
  description = "Token de Grafana Cloud (metrics/logs/traces:write, stacks:read) para OTLP y el monitoreo sintético"
  type        = string
  sensitive   = true
}

variable "correo_alertas" {
  description = "Correo que recibe las alertas"
  type        = string
  sensitive   = true
}

variable "sondas" {
  description = "Sondas públicas de Grafana Synthetic Monitoring que revisan las URLs desde fuera"
  type        = list(string)
  default     = ["Ohio", "NorthVirginia"]
}

variable "frecuencia_sonda_ms" {
  description = "Cada cuánto revisa cada sonda (el plan gratuito incluye 100 000 ejecuciones al mes)"
  type        = number
  default     = 180000
}
