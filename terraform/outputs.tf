output "url_frontend" {
  description = "Frontend publicado"
  value       = render_web_service.frontend.url
}

output "url_api" {
  description = "API REST publicada"
  value       = render_web_service.api.url
}

output "servicios" {
  description = "Ids de Render (los usan Ansible, el recolector de logs/métricas y los despliegues de Jenkins)"
  value = {
    gestor-api      = render_web_service.api.id
    gestor-frontend = render_web_service.frontend.id
    gestor-db       = render_postgres.db.id
  }
}

output "render_owner_id" {
  description = "Workspace de Render (lo usa el recolector de logs)"
  value       = var.render_owner_id
}

output "ip_admin" {
  description = "IP con acceso externo a PostgreSQL"
  value       = local.ip_admin
}

output "db_url_externa" {
  description = "Conexión externa a PostgreSQL (solo desde ip_admin, con SSL)"
  value       = render_postgres.db.connection_info.external_connection_string
  sensitive   = true
}

output "metricas_token" {
  description = "Token con el que Prometheus lee /actuator/prometheus"
  value       = random_password.metricas.result
  sensitive   = true
}
