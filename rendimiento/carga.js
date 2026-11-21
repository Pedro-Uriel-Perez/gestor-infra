// Prueba de carga CONTROLADA contra los servicios propios en Render (plan gratuito: 0.1 CPU, 512 MB).
// La carga es baja a propósito: se busca medir latencia, throughput y errores sin afectar a terceros
// ni agotar la cuota del plan. Las métricas se envían a Prometheus (remote write) y se ven en Grafana.
//
//   k6 run -e URL_API=https://... -e URL_FRONTEND=https://... rendimiento/carga.js
import http from 'k6/http';
import { check, group, sleep } from 'k6';

const API = __ENV.URL_API;
const FRONTEND = __ENV.URL_FRONTEND;
const USUARIOS_MAX = Number(__ENV.USUARIOS || 10);

export const options = {
  scenarios: {
    // Clientes de la API REST: suben de 0 a USUARIOS_MAX, se mantienen y bajan
    api: {
      executor: 'ramping-vus',
      exec: 'api',
      startVUs: 0,
      stages: [
        { duration: '30s', target: Math.ceil(USUARIOS_MAX / 2) },
        { duration: '1m', target: USUARIOS_MAX },
        { duration: '2m', target: USUARIOS_MAX },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
      tags: { escenario: 'api' },
    },
    // Usuarios del frontend: cada página consulta la API, que consulta PostgreSQL
    frontend: {
      executor: 'constant-vus',
      exec: 'frontend',
      vus: Math.max(1, Math.ceil(USUARIOS_MAX / 3)),
      duration: '4m',
      tags: { escenario: 'frontend' },
    },
  },
  // Criterios de aceptación (si no se cumplen, k6 termina con error y el pipeline lo marca)
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{escenario:api}': ['p(95)<1500'],
    'http_req_duration{escenario:frontend}': ['p(95)<2500'],
    checks: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

// Despierta los servicios antes de medir (el plan gratuito los duerme tras 15 minutos sin tráfico)
export function setup() {
  for (const url of [`${API}/actuator/health`, `${FRONTEND}/actuator/health`]) {
    let respuesta;
    for (let intento = 0; intento < 30; intento++) {
      respuesta = http.get(url, { timeout: '90s', tags: { name: 'calentamiento' } });
      if (respuesta.status === 200) break;
      sleep(10);
    }
    if (respuesta.status !== 200) {
      throw new Error(`${url} no respondió 200 (último estado ${respuesta.status})`);
    }
  }
}

const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

export function api() {
  group('API: listar proyectos', () => {
    const r = http.post(`${API}/buscarProyectos`, null, { tags: { name: 'POST /buscarProyectos' } });
    check(r, {
      'proyectos: 200': (x) => x.status === 200,
      'proyectos: lista con datos': (x) => Array.isArray(x.json()) && x.json().length > 0,
    });
  });
  group('API: proyecto por id', () => {
    const r = http.get(`${API}/buscarProyecto?id_proyecto=197`, { tags: { name: 'GET /buscarProyecto' } });
    check(r, { 'proyecto 197: 200': (x) => x.status === 200 });
  });
  group('API: tareas de un proyecto', () => {
    const r = http.post(`${API}/getTarea`, JSON.stringify({ id_proyecto: 197 }),
      Object.assign({ tags: { name: 'POST /getTarea' } }, JSON_HEADERS));
    check(r, { 'tareas: 200': (x) => x.status === 200 });
  });
  sleep(1);
}

export function frontend() {
  group('Frontend: página de inicio de sesión', () => {
    const r = http.get(`${FRONTEND}/login`, { tags: { name: 'GET /login' } });
    check(r, { 'login: 200': (x) => x.status === 200 });
  });
  group('Frontend → API → PostgreSQL: consultar proyectos', () => {
    const r = http.post(`${FRONTEND}/consultarProyectos`, null, { tags: { name: 'POST /consultarProyectos' } });
    check(r, { 'consultarProyectos: 200': (x) => x.status === 200 });
  });
  sleep(2);
}
