# Monitoreo y observabilidad en Grafana Cloud, todo como código:
#   - Monitoreo sintético: sondas públicas que revisan las URLs de Render desde fuera (disponibilidad)
#   - Tablero "Gestor de Proyectos" (métricas, trazas y logs que envía el agente de OpenTelemetry)
#   - Reglas de alerta + aviso por correo
# Las aplicaciones envían trazas, métricas y logs por OTLP (variables OTEL_* en main.tf).

data "grafana_cloud_stack" "stack" {
  provider = grafana.cloud
  slug     = var.grafana_stack_slug
}

resource "grafana_synthetic_monitoring_installation" "sm" {
  provider              = grafana.cloud
  stack_id              = data.grafana_cloud_stack.stack.id
  metrics_publisher_key = var.otlp_token
}

data "grafana_synthetic_monitoring_probes" "sondas" {
  provider   = grafana.sm
  depends_on = [grafana_synthetic_monitoring_installation.sm]
}

# Cada sonda hace una petición HTTPS cada 3 minutos (2 URLs x 2 sondas ≈ 58 000 ejecuciones al mes,
# dentro de las 100 000 del plan gratuito). Al recibir tráfico, Render no duerme los servicios.
resource "grafana_synthetic_monitoring_check" "disponibilidad" {
  provider = grafana.sm
  for_each = {
    "gestor-api"      = "${render_web_service.api.url}/actuator/health"
    "gestor-frontend" = "${render_web_service.frontend.url}/login"
  }

  job       = "disponibilidad"
  target    = each.value
  enabled   = true
  frequency = var.frecuencia_sonda_ms
  timeout   = 15000
  probes    = [for p in var.sondas : data.grafana_synthetic_monitoring_probes.sondas.probes[p]]
  labels = {
    servicio = each.key
  }

  settings {
    http {
      method             = "GET"
      fail_if_not_ssl    = true
      valid_status_codes = [200]
    }
  }
}

resource "grafana_folder" "gestor" {
  title = "Gestor de Proyectos"
}

resource "grafana_dashboard" "gestor" {
  folder      = grafana_folder.gestor.uid
  config_json = file("${path.module}/tableros/gestor-cloud.json")
  overwrite   = true
}

# ---------------------------------------------------------------- Alertas
resource "grafana_contact_point" "correo" {
  name = "correo-gestor"

  email {
    addresses    = [var.correo_alertas]
    single_email = true
    subject      = "[Gestor de Proyectos] {{ .Status | toUpper }}: {{ .CommonLabels.alertname }}"
  }
}

resource "grafana_notification_policy" "politica" {
  contact_point   = grafana_contact_point.correo.name
  group_by        = ["alertname", "servicio", "service_name"]
  group_wait      = "30s"
  group_interval  = "2m"
  repeat_interval = "1h"
}

locals {
  prom = "grafanacloud-prom"
  # Filtro común: solo producción y sin las peticiones de monitoreo (/actuator)
  prod = "deployment_environment_name=\"produccion\""
  reglas = {
    ServicioNoDisponible = {
      expr        = "min by (instance, servicio) (probe_success{job=\"disponibilidad\"})"
      operador    = "lt"
      umbral      = 1
      para        = "3m"
      severidad   = "critica"
      resumen     = "{{ $labels.servicio }} no responde desde fuera"
      descripcion = "Las sondas de Grafana Synthetic Monitoring no reciben 200 de {{ $labels.instance }} desde hace 3 minutos."
    }
    TasaDeErrores5xxAlta = {
      expr        = "sum by (service_name) (rate(http_server_request_duration_seconds_count{${local.prod}, http_response_status_code=~\"5..\"}[5m])) / clamp_min(sum by (service_name) (rate(http_server_request_duration_seconds_count{${local.prod}}[5m])), 1e-9)"
      operador    = "gt"
      umbral      = 0.05
      para        = "2m"
      severidad   = "critica"
      resumen     = "{{ $labels.service_name }} responde con errores 5xx en más del 5 % de las peticiones"
      descripcion = "Tasa de errores 5xx por encima del 5 % durante 2 minutos."
    }
    LatenciaP95Alta = {
      expr        = "histogram_quantile(0.95, sum by (service_name, le) (rate(http_server_request_duration_seconds_bucket{${local.prod}, http_route!~\"/actuator.*\"}[5m])))"
      operador    = "gt"
      umbral      = 2
      para        = "5m"
      severidad   = "advertencia"
      resumen     = "La latencia p95 de {{ $labels.service_name }} supera 2 s"
      descripcion = "p95 del servidor por encima de 2 segundos durante 5 minutos."
    }
    HeapJVMAlto = {
      expr        = "sum by (service_name) (jvm_memory_used_bytes{${local.prod}, jvm_memory_type=\"heap\"}) / sum by (service_name) (jvm_memory_limit_bytes{${local.prod}, jvm_memory_type=\"heap\"})"
      operador    = "gt"
      umbral      = 0.9
      para        = "5m"
      severidad   = "advertencia"
      resumen     = "El heap de la JVM de {{ $labels.service_name }} está por encima del 90 %"
      descripcion = "Riesgo de reinicio por falta de memoria (el plan gratuito da 512 MB)."
    }
  }
}

resource "grafana_rule_group" "gestor" {
  name             = "gestor-proyectos"
  folder_uid       = grafana_folder.gestor.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.reglas
    content {
      name           = rule.key
      condition      = "C"
      for            = rule.value.para
      no_data_state  = "OK"
      exec_err_state = "Error"
      labels = {
        severidad = rule.value.severidad
      }
      annotations = {
        summary     = rule.value.resumen
        description = rule.value.descripcion
      }

      data {
        ref_id         = "A"
        datasource_uid = local.prom
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({ refId = "A", expr = rule.value.expr, instant = true })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "A"
          conditions = [{ evaluator = { type = rule.value.operador, params = [rule.value.umbral] } }]
        })
      }
    }
  }
}
