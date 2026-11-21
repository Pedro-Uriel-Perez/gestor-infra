"""Recolector de Render para el stack de monitoreo.

Render (plan gratuito) no permite instalar agentes en sus servidores, pero expone los logs y las
métricas de la plataforma por su API. Este proceso:
  - cada 15 s copia los logs nuevos (aplicación, peticiones HTTP y builds) de cada recurso a Loki;
  - cada 60 s lee CPU, memoria y sus límites (y las conexiones de PostgreSQL) y los publica en
    /metrics con formato Prometheus;
  - recibe en POST /alertas el webhook de Alertmanager y guarda cada alerta en Loki, para verla
    en Grafana junto a los logs.
Solo usa la biblioteca estándar de Python.
"""
import json
import logging
import os
import threading
import time
import urllib.parse
import urllib.request
from collections import deque
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

API = "https://api.render.com/v1"
CLAVE = os.environ["RENDER_API_KEY"]
DUENO = os.environ["RENDER_OWNER_ID"]
LOKI = os.environ.get("LOKI_URL", "http://loki:3100")
# "gestor-api=srv-...,gestor-frontend=srv-...,gestor-db=dpg-..."
RECURSOS = {nombre: recurso for nombre, _, recurso in
            (par.partition("=") for par in os.environ["RECURSOS_RENDER"].split(","))}

# (endpoint de Render, métrica Prometheus, ayuda)
METRICAS = [
    ("cpu", "render_cpu_uso_cores", "CPU usada (núcleos) según Render"),
    ("cpu-limit", "render_cpu_limite_cores", "Límite de CPU del plan (núcleos)"),
    ("memory", "render_memoria_bytes", "Memoria usada según Render"),
    ("memory-limit", "render_memoria_limite_bytes", "Límite de memoria del plan"),
    ("active-connections", "render_db_conexiones", "Conexiones activas a PostgreSQL"),
]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("recolector")

valores = {}             # (métrica, servicio) -> valor
estado = {"errores": 0, "logs_enviados": 0, "ultima_lectura": 0.0}
candado = threading.Lock()


def rfc3339(momento):
    return momento.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def a_nanosegundos(marca):
    """'2026-11-16T03:18:58.174615916Z' -> nanosegundos desde epoch (Loki usa ns)."""
    base, _, fraccion = marca.rstrip("Z").partition(".")
    segundos = datetime.strptime(base, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    return int(segundos) * 1_000_000_000 + int((fraccion or "0").ljust(9, "0")[:9])


def render(ruta, **parametros):
    url = f"{API}{ruta}?{urllib.parse.urlencode(parametros, doseq=True)}"
    peticion = urllib.request.Request(url, headers={"Authorization": f"Bearer {CLAVE}", "Accept": "application/json"})
    with urllib.request.urlopen(peticion, timeout=30) as respuesta:
        return json.load(respuesta)


def a_loki(flujos):
    datos = json.dumps({"streams": flujos}).encode()
    peticion = urllib.request.Request(f"{LOKI}/loki/api/v1/push", data=datos, headers={"Content-Type": "application/json"})
    urllib.request.urlopen(peticion, timeout=15).close()


def copiar_logs(servicio, recurso, desde, vistos):
    """Copia a Loki los logs de un recurso a partir de 'desde'. Devuelve la nueva marca."""
    inicio, fin = desde, rfc3339(datetime.now(timezone.utc))
    while True:
        pagina = render("/logs", ownerId=DUENO, resource=recurso, startTime=inicio, endTime=fin,
                        direction="forward", limit=100)
        flujos = {}
        for entrada in pagina.get("logs", []):
            if entrada["id"] in vistos:
                continue
            vistos.append(entrada["id"])
            desde = entrada["timestamp"]
            if not entrada.get("message", "").strip():
                continue  # Render también registra las líneas en blanco de la salida
            etiquetas = {e["name"]: e["value"] for e in entrada.get("labels", [])}
            # tipo: app (aplicación) o build (construcción de la imagen en cada despliegue)
            clave = (etiquetas.get("type", "app"), etiquetas.get("level", "info"))
            flujos.setdefault(clave, []).append([str(a_nanosegundos(entrada["timestamp"])), entrada["message"]])
        if flujos:
            # "level" es la etiqueta que Grafana usa para colorear cada línea según su severidad
            a_loki([{"stream": {"fuente": "render", "servicio": servicio, "tipo": tipo, "level": nivel},
                     "values": lineas} for (tipo, nivel), lineas in flujos.items()])
            with candado:
                estado["logs_enviados"] += sum(len(v) for v in flujos.values())
        if not pagina.get("hasMore"):
            return desde
        inicio, fin = pagina["nextStartTime"], pagina["nextEndTime"]


# URLError hereda de OSError; ValueError/KeyError cubren respuestas inesperadas de la API
ERRORES_API = (OSError, ValueError, KeyError)


def contar_error(contexto, error):
    with candado:
        estado["errores"] += 1
    log.warning("%s: %s", contexto, error)


def ciclo_logs():
    marcas = dict.fromkeys(RECURSOS, rfc3339(datetime.now(timezone.utc) - timedelta(hours=1)))
    vistos = deque(maxlen=5000)
    while True:
        for servicio, recurso in RECURSOS.items():
            try:
                marcas[servicio] = copiar_logs(servicio, recurso, marcas[servicio], vistos)
            except ERRORES_API as error:
                contar_error(f"logs de {servicio}", error)
        time.sleep(15)


def ultimo_valor(series):
    """Render devuelve una serie por instancia: se suma el valor más reciente de cada una."""
    ultimos = [serie["values"][-1] for serie in series if serie.get("values")]
    if not ultimos:
        return None
    marca = max(v["timestamp"] for v in ultimos)
    return sum(v["value"] for v in ultimos if v["timestamp"] == marca)


def leer_metricas(servicio, recurso, ahora):
    # Las bases de datos (dpg-...) reportan conexiones; los servicios web, sus límites
    propias = ("cpu", "memory", "active-connections") if recurso.startswith("dpg-") \
        else ("cpu", "cpu-limit", "memory", "memory-limit")
    for endpoint, metrica, _ in (m for m in METRICAS if m[0] in propias):
        try:
            valor = ultimo_valor(render(f"/metrics/{endpoint}", resource=recurso,
                                        startTime=rfc3339(ahora - timedelta(minutes=10)),
                                        endTime=rfc3339(ahora), resolutionSeconds=60))
        except ERRORES_API as error:
            contar_error(f"métrica {endpoint} de {servicio}", error)
            continue
        with candado:
            if valor is None:
                valores.pop((metrica, servicio), None)
            else:
                valores[(metrica, servicio)] = valor


def ciclo_metricas():
    while True:
        ahora = datetime.now(timezone.utc)
        for servicio, recurso in RECURSOS.items():
            leer_metricas(servicio, recurso, ahora)
        with candado:
            estado["ultima_lectura"] = time.time()
        time.sleep(60)


def texto_prometheus():
    lineas = []
    with candado:
        for _, metrica, ayuda in METRICAS:
            lineas += [f"# HELP {metrica} {ayuda}", f"# TYPE {metrica} gauge"]
            lineas += [f'{metrica}{{servicio="{s}"}} {v}' for (m, s), v in sorted(valores.items()) if m == metrica]
        lineas += [
            "# HELP recolector_errores_total Errores al consultar la API de Render",
            "# TYPE recolector_errores_total counter",
            f"recolector_errores_total {estado['errores']}",
            "# HELP recolector_logs_enviados_total Líneas de log enviadas a Loki",
            "# TYPE recolector_logs_enviados_total counter",
            f"recolector_logs_enviados_total {estado['logs_enviados']}",
            "# HELP recolector_ultima_lectura_segundos Momento de la última lectura de métricas",
            "# TYPE recolector_ultima_lectura_segundos gauge",
            f"recolector_ultima_lectura_segundos {estado['ultima_lectura']}",
        ]
    return "\n".join(lineas) + "\n"


class Manejador(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        cuerpo = texto_prometheus().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_POST(self):
        if self.path != "/alertas":
            self.send_error(404)
            return
        aviso = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        ahora = str(time.time_ns())
        flujos = []
        for alerta in aviso.get("alerts", []):
            etiquetas = alerta.get("labels", {})
            resumen = alerta.get("annotations", {}).get("resumen", "")
            flujos.append({
                "stream": {"fuente": "alertmanager", "alerta": etiquetas.get("alertname", "?"),
                           "estado": alerta.get("status", "?"), "severidad": etiquetas.get("severidad", "?")},
                "values": [[ahora, f"[{alerta.get('status', '?').upper()}] {etiquetas.get('alertname')} "
                                   f"{etiquetas.get('servicio', '')}: {resumen}"]],
            })
        if flujos:
            a_loki(flujos)
        log.info("alertas recibidas: %d", len(flujos))
        self.send_response(200)
        self.end_headers()

    def log_message(self, formato, *args):
        pass  # las consultas de Prometheus cada 30 s no se registran


if __name__ == "__main__":
    log.info("recursos: %s", RECURSOS)
    threading.Thread(target=ciclo_logs, daemon=True).start()
    threading.Thread(target=ciclo_metricas, daemon=True).start()
    # HTTP sin TLS a propósito: el puerto 9100 no se publica fuera de la red interna "monitoreo"
    # de Docker; solo lo consultan Prometheus y Alertmanager.
    ThreadingHTTPServer(("0.0.0.0", 9100), Manejador).serve_forever()  # NOSONAR
