FROM prom/alertmanager:v0.34.2
COPY alertmanager.yml /etc/alertmanager/alertmanager.yml
USER nobody
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO- http://localhost:9093/-/ready > /dev/null || exit 1
