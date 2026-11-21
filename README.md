# gestor-infra

Infraestructura como código del **Gestor de Proyectos**: despliegue en la nube (Render), configuración,
monitoreo/observabilidad y pruebas de rendimiento.

| Repositorio | Contenido |
|---|---|
| [gestor-api](https://github.com/Pedro-Uriel-Perez/gestor-api) | API REST (Java 21 / Spring Boot 3), scripts SQL y Jenkins (Docker Compose + JCasC) |
| [gestor-frontend](https://github.com/Pedro-Uriel-Perez/gestor-frontend) | Frontend web (Java 21 / Spring Boot 3 + Thymeleaf) |
| **gestor-infra** (este) | Terraform, Ansible, stack de monitoreo y pruebas de carga |

## Arquitectura

```
 GitHub ──► Jenkins (Docker local)
              ├─ gestor-api / gestor-frontend: compila → pruebas + JaCoCo → SonarQube + Quality Gate
              │                                → Trivy → Semgrep (SAST) → despliegue en Render (API)
              ├─ gestor-basedatos: SQLFluff → migración → verificación de integridad
              ├─ gestor-infra:     terraform plan/apply → Ansible (base de datos, verificación, monitoreo)
              └─ gestor-rendimiento: k6 ──(remote write)──┐
                                                          ▼
 Render (proyecto gestor-proyectos, región Ohio)       Monitoreo (Docker local, red "monitoreo")
   gestor-frontend ──HTTPS──► gestor-api ──► gestor-db   Prometheus ◄── /actuator/prometheus (token)
        ▲                         ▲     (red interna)     │   ▲  ◄── blackbox (disponibilidad HTTPS)
        └──────── usuarios ───────┘                       │   └───── recolector (API de Render:
                                                          ▼           CPU, memoria, logs)
                                         Alertmanager ──► recolector ──► Loki ◄── Grafana (tablero)
```

## Qué automatiza cada herramienta

| Herramienta | Alcance | Archivos |
|---|---|---|
| **Terraform** (proveedor `render-oss/render`) | **Aprovisionamiento**: proyecto y entorno, PostgreSQL 18, servicios web Docker de la API y del frontend, variables de entorno (conexión a la base, URL de la API, token de métricas generado), lista de IPs permitidas en la base | `terraform/` |
| **Ansible** | **Configuración**: carga idempotente del esquema y los datos (scripts de `gestor-api/sql/postgres`), verificación de integridad, pruebas de humo de los servicios integrados y despliegue del stack de monitoreo | `ansible/` |
| **Docker Compose** | Stack de monitoreo: Prometheus, Alertmanager, blackbox exporter, Loki, Grafana (fuentes y tablero aprovisionados) y recolector de Render | `monitoreo/` |
| **k6** | Prueba de carga controlada (latencia p95, throughput, errores) | `rendimiento/` |

Render es un servicio administrado (PaaS): no hay servidores que configurar por SSH. Por eso Terraform
cubre el aprovisionamiento y la configuración de la plataforma, y Ansible la configuración de los datos,
la verificación y el monitoreo desde el equipo de administración.

## Ejecución (Jenkins)

1. En `gestor-api/jenkins/.env` (no se versiona): `SONAR_TOKEN`, `RENDER_API_KEY` y `GRAFANA_ADMIN_PASSWORD`.
2. `cd gestor-api/jenkins && docker compose up -d --build` → http://localhost:8090
3. Job **gestor-infra** → *Build with Parameters* (APLICAR = sí). Crea o actualiza todo y deja el monitoreo en
   http://localhost:3000 (Grafana), http://localhost:9090 (Prometheus) y http://localhost:9093 (Alertmanager).
4. Job **gestor-rendimiento** → prueba de carga; el reporte HTML queda en los artefactos del build.

El estado de Terraform se guarda en el volumen de Jenkins (`/var/jenkins_home/terraform/gestor-infra.tfstate`).

## Configuración segura

- Ningún secreto está en el repositorio: la llave de Render y la contraseña de Grafana son credenciales de
  Jenkins (desde `.env`); la contraseña de PostgreSQL la genera Render y el token de métricas lo genera Terraform
  (`random_password`). Las salidas sensibles se pasan a Ansible en un archivo temporal que se borra al terminar.
- PostgreSQL solo acepta conexiones externas desde la IP del equipo de administración; la API usa la red interna de Render.
- `/actuator/prometheus` exige `Authorization: Bearer <token>`; solo `health`, `info` y `prometheus` están expuestos.
- Los puertos del monitoreo se publican solo en `127.0.0.1`.
- Trivy analiza el IaC (Terraform, Dockerfiles, Compose) y ansible-lint los playbooks en cada ejecución.

## Limitaciones del plan gratuito de Render

- 0.1 CPU y 512 MB por servicio: arranque en frío de varios minutos (se mitiga con CDS en los Dockerfile).
- Los servicios se duermen tras 15 minutos sin tráfico; mientras el monitoreo está encendido se mantienen despiertos.
- La base de datos gratuita vence a los 30 días y no tiene respaldos automáticos.
