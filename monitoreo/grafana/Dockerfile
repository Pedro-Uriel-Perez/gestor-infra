# Grafana con las fuentes de datos y el tablero ya aprovisionados (configuración como código)
FROM grafana/grafana:13.3.0
COPY provisioning /etc/grafana/provisioning
COPY tableros /etc/grafana/tableros
USER grafana
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO- http://localhost:3000/api/health > /dev/null || exit 1
