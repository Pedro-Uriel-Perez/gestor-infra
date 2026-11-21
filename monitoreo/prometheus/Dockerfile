# prometheus.yml lo genera Ansible (lleva el token de métricas): la imagen solo se construye en el
# equipo local y nunca se publica.
FROM prom/prometheus:v3.15.1
COPY prometheus.yml reglas.yml /etc/prometheus/
USER nobody
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO- http://localhost:9090/-/ready > /dev/null || exit 1
