FROM prom/blackbox-exporter:v0.29.1
COPY blackbox.yml /etc/blackbox_exporter/config.yml
USER nobody
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO- http://localhost:9115/-/healthy > /dev/null || exit 1
