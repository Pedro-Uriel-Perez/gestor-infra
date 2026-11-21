FROM python:3.13.17-alpine
WORKDIR /app
RUN adduser -S -D -H recolector
COPY recolector.py .
USER recolector
EXPOSE 9100
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO- http://localhost:9100/metrics > /dev/null || exit 1
CMD ["python", "-u", "recolector.py"]
