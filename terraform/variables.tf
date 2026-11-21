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
