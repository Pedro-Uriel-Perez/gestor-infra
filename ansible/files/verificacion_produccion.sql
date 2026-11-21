-- =====================================================================
-- Verificación de la base de producción (Render) en cada ejecución del pipeline gestor-infra.
-- Son las verificaciones estructurales de gestor-api/sql/postgres/05_verificacion_integridad.sql
-- que no dependen de los datos iniciales ni escriben en la base (en producción los usuarios ya
-- agregaron registros). Cada bloque lanza un ERROR si falla y psql termina con código <> 0.
-- =====================================================================
SET client_encoding = 'UTF8';
SET client_min_messages = NOTICE;

-- PROD-01 Existen las 5 tablas del sistema
DO $$
DECLARE faltantes TEXT;
BEGIN
    SELECT string_agg(esperada, ', ') INTO faltantes
    FROM unnest(ARRAY['usuario', 'proyectos', 'tareas', 'comentarios', 'asignaciones']) AS esperada
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = esperada
    );
    IF faltantes IS NOT NULL THEN
        RAISE EXCEPTION 'PROD-01 FALLA: faltan las tablas %', faltantes;
    END IF;
    RAISE NOTICE 'PROD-01 OK: existen las 5 tablas';
END $$;

-- PROD-02 Existen las 4 llaves foráneas
DO $$
DECLARE total INTEGER;
BEGIN
    SELECT count(*) INTO total
    FROM information_schema.table_constraints
    WHERE table_schema = 'public' AND constraint_type = 'FOREIGN KEY'
      AND table_name IN ('tareas', 'comentarios', 'asignaciones');
    IF total < 4 THEN
        RAISE EXCEPTION 'PROD-02 FALLA: se esperaban 4 llaves foraneas y hay %', total;
    END IF;
    RAISE NOTICE 'PROD-02 OK: % llaves foraneas', total;
END $$;

-- PROD-03 No hay registros huérfanos
DO $$
DECLARE huerfanos INTEGER;
BEGIN
    SELECT
        (SELECT count(*) FROM tareas AS t
            WHERE t.id_proyecto IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM proyectos AS p WHERE p.id_proyecto = t.id_proyecto))
        + (SELECT count(*) FROM comentarios AS c
            WHERE c.id_tarea IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM tareas AS t WHERE t.id_tarea = c.id_tarea))
        + (SELECT count(*) FROM asignaciones AS a
            WHERE (a.id_tarea IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tareas AS t WHERE t.id_tarea = a.id_tarea))
               OR (a.id_usuario IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM usuario AS u WHERE u.id_usuario = a.id_usuario)))
    INTO huerfanos;
    IF huerfanos > 0 THEN
        RAISE EXCEPTION 'PROD-03 FALLA: % registros huerfanos', huerfanos;
    END IF;
    RAISE NOTICE 'PROD-03 OK: sin registros huerfanos';
END $$;

-- PROD-04 La secuencia de Hibernate entrega ids mayores a los existentes
DO $$
DECLARE siguiente BIGINT; maximo INTEGER;
BEGIN
    SELECT CASE WHEN is_called THEN last_value + 1 ELSE last_value END INTO siguiente FROM hibernate_sequence;
    SELECT greatest(
        (SELECT max(id_usuario) FROM usuario), (SELECT max(id_proyecto) FROM proyectos),
        (SELECT max(id_tarea) FROM tareas), (SELECT max(id_comentario) FROM comentarios),
        (SELECT max(id_asignacion) FROM asignaciones)
    ) INTO maximo;
    IF siguiente <= maximo THEN
        RAISE EXCEPTION 'PROD-04 FALLA: la secuencia entregaria % pero ya existe el id %', siguiente, maximo;
    END IF;
    RAISE NOTICE 'PROD-04 OK: el siguiente id sera % (maximo actual %)', siguiente, maximo;
END $$;

-- PROD-05 Resumen de registros (evidencia del estado de la base)
SELECT
    (SELECT count(*) FROM usuario) AS usuarios,
    (SELECT count(*) FROM proyectos) AS proyectos,
    (SELECT count(*) FROM tareas) AS tareas,
    (SELECT count(*) FROM comentarios) AS comentarios,
    (SELECT count(*) FROM asignaciones) AS asignaciones,
    version() AS servidor;
