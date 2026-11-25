# gestor-infra

[![Infraestructura](https://github.com/Pedro-Uriel-Perez/gestor-infra/actions/workflows/infra.yml/badge.svg)](https://github.com/Pedro-Uriel-Perez/gestor-infra/actions/workflows/infra.yml)
[![Rendimiento](https://github.com/Pedro-Uriel-Perez/gestor-infra/actions/workflows/rendimiento.yml/badge.svg)](https://github.com/Pedro-Uriel-Perez/gestor-infra/actions/workflows/rendimiento.yml)

Infraestructura como código del **Gestor de Proyectos**: despliegue en la nube (Render), configuración,
monitoreo/observabilidad (Grafana Cloud) y pruebas de rendimiento (k6). Todo corre en la nube.

| Repositorio | Contenido |
|---|---|
| [gestor-api](https://github.com/Pedro-Uriel-Perez/gestor-api) | API REST (Java 21 / Spring Boot 3), scripts SQL, pipelines CI/CD y de base de datos |
| [gestor-frontend](https://github.com/Pedro-Uriel-Perez/gestor-frontend) | Frontend web (Java 21 / Spring Boot 3 + Thymeleaf) y su pipeline CI/CD |
| **gestor-infra** (este) | Terraform, Ansible, monitoreo como código y pruebas de carga |

## Arquitectura (todo en la nube)

```
 GitHub ──► GitHub Actions
              ├─ gestor-api / gestor-frontend: pruebas + JaCoCo → SonarQube Cloud (Quality Gate)
              │                                → Trivy → Semgrep (SAST) → despliegue en Render
              ├─ gestor-api / basedatos: SQLFluff → migración → integridad BD-01..BD-10 → pruebas
              ├─ gestor-infra / infra: fmt/validate + ansible-lint + Trivy → terraform plan/apply → Ansible
              └─ gestor-infra / rendimiento: k6 ──(OTLP)──┐
                                                          ▼
 Render (Ohio)                                   Grafana Cloud (us-east-2)
   gestor-frontend ─HTTPS─► gestor-api ─► gestor-db   ◄─ OTLP: trazas, métricas y logs (agente OpenTelemetry)
        ▲                                             ◄─ Synthetic Monitoring (sondas Ohio y Virginia)
        └──────────── usuarios                        ─► tablero, alertas → correo
 Estado de Terraform: PostgreSQL en Neon (backend "pg", con bloqueo)
```

## Qué automatiza cada herramienta

| Herramienta | Alcance | Archivos |
|---|---|---|
| **Terraform** (`render-oss/render`, `grafana/grafana`) | **Aprovisionamiento**: proyecto, PostgreSQL 18, servicios Docker de la API y del frontend, variables (conexión a la base, URL de la API, token de métricas, grupo `otel-grafana-cloud`), IP autorizada; en Grafana Cloud: monitoreo sintético, carpeta, tablero, reglas de alerta, aviso por correo y política de notificación | `terraform/` |
| **Ansible** | **Configuración**: carga idempotente del esquema y los datos (scripts de `gestor-api/sql/postgres`), verificación de integridad y pruebas de humo de los servicios integrados | `ansible/` |
| **k6** | Prueba de carga controlada (latencia p95/p99, throughput, errores) con métricas en vivo en Grafana Cloud | `rendimiento/carga.js` |
| **GitHub Actions** | Ejecuta todo: `infra.yml` (validar → plan → apply → Ansible) y `rendimiento.yml` (k6) | `.github/workflows/` |

Render es una plataforma administrada (PaaS): no hay servidores que configurar por SSH. Terraform cubre el
aprovisionamiento de Render y de Grafana Cloud; Ansible, la configuración de los datos y la verificación.

## Ejecución
- **Infraestructura:** cada push a `main` que cambie `terraform/` o `ansible/` ejecuta `infra.yml`; también se puede
  lanzar a mano desde *Actions → Infraestructura → Run workflow*.
- **Rendimiento:** *Actions → Rendimiento (k6) → Run workflow* (10, 20 o 40 usuarios). El reporte HTML y el resumen
  quedan en los artefactos de la ejecución.

### Secretos del repositorio (GitHub → Settings → Secrets)
`PG_CONN_STR` (estado de Terraform en Neon), `RENDER_API_KEY`, `RENDER_OWNER_ID`, `GRAFANA_URL`, `GRAFANA_AUTH`
(service account de Grafana), `GRAFANA_STACK_SLUG`, `OTLP_INSTANCE_ID`, `OTLP_TOKEN`, `OTLP_AUTH_BASIC` y
`CORREO_ALERTAS`. Ninguno está en el código.

### Arranque inicial (solo la primera vez)
El proveedor del monitoreo sintético usa el token que entrega su instalación, así que la primera vez se aplica primero:
```
terraform apply -target=grafana_synthetic_monitoring_installation.sm
```

## Configuración segura
- Secretos solo en GitHub Actions; las salidas sensibles de Terraform pasan a Ansible en un archivo temporal que se borra.
- Acciones fijadas por SHA, imágenes y agentes verificados (digest / SHA-256), `pip --only-binary`, descargas solo HTTPS.
- PostgreSQL acepta conexiones externas solo desde la IP del runner que ejecuta Terraform y por TLS; la API usa la red interna.
- `/actuator/prometheus` exige token; las apps envían su telemetría a Grafana Cloud con un token de solo escritura.
- Trivy analiza el IaC y ansible-lint los playbooks en cada ejecución.

## Limitaciones del plan gratuito
- Render: 0.15 CPU y 512 MB por servicio; las variables de los servicios web no se pueden actualizar con el proveedor
  (se usan grupos de entorno); la base gratuita vence a los 30 días; 750 h de instancia al mes.
- Grafana Cloud: 14 días de retención y 100 000 ejecuciones de sondas al mes (las sondas corren cada 3 minutos).

## Alternativa local (primera versión)
`monitoreo/` (Prometheus, Grafana, Loki, Alertmanager, blackbox y recolector en Docker Compose) y
`ansible/monitoreo.yml` son la versión local del monitoreo que se usó antes de migrar a Grafana Cloud.
