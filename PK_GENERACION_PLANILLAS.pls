CREATE OR REPLACE EDITIONABLE PACKAGE "GPROY_ELEL"."PKG_GENERACION_PLANILLAS" AS

    -- Procedimiento anterior (carga masiva mensual)
    PROCEDURE PR_GENERAR_PLANILLA_MENSUAL (
        p_contrato_id IN NUMBER,
        p_fecha_mes   IN DATE
    );

    /**
     * Nuevo Procedimiento: Procesa una sola fila del Anexo de Volumen de Obra.
     * Si no existe la planilla para el contrato y mes/año de la fila, la crea.
     * Luego, inserta el detalle correspondiente.
     */
    PROCEDURE PR_PROCESAR_NUEVO_ANEXO (
        p_anexo_id         IN NUMBER,
        p_fecha_planilla   IN DATE,
        p_rubro            IN VARCHAR2,
        p_total            IN NUMBER,
        p_precio_unitario  IN NUMBER,
        p_actividad_id     IN NUMBER
    );
    --Nueva versión que acepta rango de fechas por Acrtibvidad al crear el Anexo.
    PROCEDURE PR_PROCESAR_NUEVO_ANEXO2 (
    p_anexo_id         IN NUMBER,
    p_fecha_inicio     IN DATE,
    p_fecha_fin        IN DATE,
    p_rubro            IN VARCHAR2,
    p_total            IN NUMBER,
    p_precio_unitario  IN NUMBER,
    p_actividad_id     IN NUMBER
);

END PKG_GENERACION_PLANILLAS;
/
CREATE OR REPLACE EDITIONABLE PACKAGE BODY "GPROY_ELEL"."PKG_GENERACION_PLANILLAS" AS

    -- [Procedimiento PR_GENERAR_PLANILLA_MENSUAL se mantiene igual]
    PROCEDURE PR_GENERAR_PLANILLA_MENSUAL (
        p_contrato_id IN NUMBER,
        p_fecha_mes   IN DATE
    ) IS 
          
        -- Variables de control y auditoría
        v_planilla_id    PLANILLA_CONTRACTUAL.PLANILLA_ID%TYPE;
        v_nro_planilla   PLANILLA_CONTRACTUAL.NRO_PLANILLA%TYPE;
        v_primer_dia_mes DATE := TRUNC(p_fecha_mes, 'MM');
        v_ultimo_dia_mes DATE := LAST_DAY(TRUNC(p_fecha_mes));
        
        -- Definición de tipos para carga en memoria (Bulk Collect) optimizada
        TYPE t_detalle_tab IS TABLE OF PLANILLA_CONTRACTUAL_DETALLE%ROWTYPE;
        v_detalles t_detalle_tab;
        
    BEGIN
        -- 1. OBTENER EL SIGUIENTE NÚMERO DE PLANILLA PARA EL CONTRATO
        -- Optimizable con un índice compuesto en (CONTRATO_ID, NRO_PLANILLA)
        SELECT COALESCE(MAX(NRO_PLANILLA), 0) + 1
        INTO v_nro_planilla
        FROM PLANILLA_CONTRACTUAL
        WHERE CONTRATO_ID = p_contrato_id;
        
        -- 2. GENERAR EL ID DE LA PLANILLA MAESTRA
        -- En Oracle 12c+ se prefiere usar IDENTITY columns, pero si usas secuencias:
        --v_planilla_id := SEQ_PLANILLA_ID.NEXTVAL; 
        
        -- 3. INSERCIÓN DE LA CABECERA
        INSERT INTO PLANILLA_CONTRACTUAL (
            --LANILLA_ID,
            NRO_PLANILLA,
            FECHA_CREAR_PLANILLA,
            CONTRATO_ID
        ) VALUES (
            --v_planilla_id,
            v_nro_planilla,
            SYSDATE,
            p_contrato_id
        );

        -- 4. RECOLECCIÓN MASIVA Y CÁLCULO ANALÍTICO (BULK COLLECT)
        -- Usamos funciones analíticas para calcular acumulados eficientemente sin subconsultas costosas.
        SELECT 
            NULL,--SEQ_DETALLE_PLANILLA.NEXTVAL, -- DETALLE_PLANILLAID
            v_planilla_id,                -- PLANILLA_ID
            anexo.ANEXO_VOLUMENOBRA_ID,   -- ANEXO_VOLUMENOBRA_ID
            TO_NUMBER(REGEXP_SUBSTR(anexo.RUBRO, '^[0-9]+')), -- RUBRO (Conversión segura de VARCHAR2 a NUMBER si aplica)
            'UND',                        -- UNIDAD (Hardcoded temporal / Ajustar según negocio)
            anexo.TOTAL,                  -- CANTIDAD
            anexo.PRECIO_UNITARIO,         -- PRECIO_UNITARIO
            (anexo.TOTAL * anexo.PRECIO_UNITARIO), -- PRECIO_TOTAL
            
            -- CEJEC_ANTERIORES: Suma de cantidades de periodos previos
            NVL(SUM(anexo.TOTAL) OVER (
                PARTITION BY anexo.RUBRO 
                ORDER BY anexo.FECHA_CREAR_PLANILLA
                RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ), 0), 
            
            anexo.TOTAL,                  -- CEJEC_ESTEPERIODO
            
            -- CEJEC_ACUMULADAS: Suma acumulada total incluyendo el periodo actual
            SUM(anexo.TOTAL) OVER (
                PARTITION BY anexo.RUBRO 
                ORDER BY anexo.FECHA_CREAR_PLANILLA
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ),
            
            0, 0, 0, 0 -- Valores financieros inicializados para cálculo posterior si se requiere
        BULK COLLECT INTO v_detalles
        FROM ANEXO_VOLUMEN_DE_OBRA anexo
        WHERE anexo.FECHA_CREAR_PLANILLA BETWEEN v_primer_dia_mes AND v_ultimo_dia_mes
          -- Asumiendo que el anexo se vincula al contrato mediante las actividades del libro de obra:
          AND EXISTS (
              SELECT 1 FROM LIBRO_OBRA_ACTIVIDADES_REALIZADAS loa -- Tabla conceptual de tu modelo
              WHERE loa.ACTIVIDAD_ID = anexo.LIBRO_OBRA_ACTIVIDADES_REALIZADAS_ACTIVIDAD_ID
                -- AND loa.CONTRATO_ID = p_contrato_id (Descomentar al mapear relación)
          );

        -- 5. INSERCIÓN MASIVA UTILIZANDO FORALL (ALTO RENDIMIENTO)
        -- Rompe la barrera PL/SQL-SQL insertando el set completo de datos de un solo golpe.
        IF v_detalles.COUNT > 0 THEN
            FORALL i IN 1..v_detalles.COUNT
                INSERT /*+ APPEND_VALUES */ INTO PLANILLA_CONTRACTUAL_DETALLE VALUES v_detalles(i);
        END IF;

        COMMIT;
        
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            -- Reemplazar por tu paquete de log institucional (ej. LOGGER.log_error)
            RAISE_APPLICATION_ERROR(-20001, 'Error al generar planilla: ' || SQLERRM);
    END PR_GENERAR_PLANILLA_MENSUAL;

    -- NUEVO PROCEDIMIENTO PARA PROCESAMIENTO FILA POR FILA DESDE TRIGGER
    PROCEDURE PR_PROCESAR_NUEVO_ANEXO (
        p_anexo_id         IN NUMBER,
        p_fecha_planilla   IN DATE,
        p_rubro            IN VARCHAR2,
        p_total            IN NUMBER,
        p_precio_unitario  IN NUMBER,
        p_actividad_id     IN NUMBER
    ) IS
        v_contrato_id      NUMBER;
        v_planilla_id      PLANILLA_CONTRACTUAL.PLANILLA_ID%TYPE;
        v_nro_planilla     PLANILLA_CONTRACTUAL.NRO_PLANILLA%TYPE;
        v_primer_dia_mes   DATE := TRUNC(p_fecha_planilla, 'MM');
        v_ultimo_dia_mes   DATE := LAST_DAY(TRUNC(p_fecha_planilla));

        -- Variables para cálculos del detalle
        v_cejec_anteriores    NUMBER := 0;
        v_cejec_este_periodo  NUMBER := NVL(p_total, 0);
        v_cejec_acumuladas    NUMBER := 0;

    BEGIN
        -- 1. OBTENER EL CONTRATO ID DESDE LA ACTIVIDAD DEL CRONOGRAMA
        -- (Ajustar nombres de tabla/columnas según tu modelo real de actividades)
        SELECT contrato.contrato_id INTO v_contrato_id
        FROM LIBRO_OBRA_ACTIVIDADES_realizadas LOAR 
        INNER JOIN libro_de_obra LDO on ldo.libro_obra_id = loar.libro_obra_id
        INNER JOIN Contrato on ldo.contrato_id = contrato.contrato_id
        WHERE ACTIVIDAD_ID = p_actividad_id;

        -- 2. VERIFICAR SI YA EXISTE LA PLANILLA PARA ESE MES Y CONTRATO
        -- Se busca si hay una planilla cuya fecha de creación caiga en el mismo mes/año.
        BEGIN
            SELECT PLANILLA_ID
              INTO v_planilla_id
              FROM PLANILLA_CONTRACTUAL
             WHERE CONTRATO_ID = v_contrato_id
               AND FECHA_CREAR_PLANILLA BETWEEN v_primer_dia_mes AND v_ultimo_dia_mes
               -- Cláusula de seguridad por si existen múltiples, priorizamos la última
               AND ROWNUM = 1;

        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- 3. SI NO EXISTE, SE CREA LA CABECERA DE LA PLANILLA
                -- Calculamos el siguiente número de planilla para el contrato
                SELECT COALESCE(MAX(NRO_PLANILLA), 0) + 1
                  INTO v_nro_planilla
                  FROM PLANILLA_CONTRACTUAL
                 WHERE CONTRATO_ID = v_contrato_id;

                --v_planilla_id := SEQ_PLANILLA_ID.NEXTVAL;

                INSERT INTO PLANILLA_CONTRACTUAL (
                     NRO_PLANILLA, FECHA_CREAR_PLANILLA, CONTRATO_ID
                ) VALUES (
                     v_nro_planilla, p_fecha_planilla, v_contrato_id
                )returning planilla_id into v_planilla_id; --línea que agregao para obtener el Id de la nueva planilla.
        END;

        -- 4. CÁLCULO DE ACUMULADOS HISTÓRICOS (TUNING: Uso de índices en lugar de scans completos)
        -- Cantidades ejecutadas en periodos anteriores de este mismo rubro
        SELECT COALESCE(SUM(CANTIDAD), 0)
          INTO v_cejec_anteriores
          FROM PLANILLA_CONTRACTUAL_DETALLE d
          JOIN PLANILLA_CONTRACTUAL m ON (d.PLANILLA_ID = m.PLANILLA_ID)
         WHERE m.CONTRATO_ID = v_contrato_id
           AND d.RUBRO = TO_NUMBER(REGEXP_SUBSTR(p_rubro, '^[0-9]+'))
           AND m.FECHA_CREAR_PLANILLA < v_primer_dia_mes;

        v_cejec_acumuladas := v_cejec_anteriores + v_cejec_este_periodo;

        -- 5. INSERCIÓN DEL DETALLE DE LA PLANILLA
        INSERT INTO PLANILLA_CONTRACTUAL_DETALLE (
            PLANILLA_ID, ANEXO_VOLUMENOBRA_ID, RUBRO,
            UNIDAD, CANTIDAD, PRECIO_UNITARIO, PRECIO_TOTAL,
            CEJEC_ANTERIORES, CEJEC_ESTEPERIODO, CEJEC_ACUMULADAS,
            VALEJEC_ANTERIORES, VALEJEC_ACUMULADAS, VALEJEC_ACUMULADAS1, PORC_AVANCE_ACUMULADO
        ) VALUES (
            v_planilla_id,
            p_anexo_id,
            TO_NUMBER(REGEXP_SUBSTR(p_rubro, '^[0-9]+')),
            'UND',
            p_total,
            p_precio_unitario,
            (p_total * p_precio_unitario),
            v_cejec_anteriores,
            v_cejec_este_periodo,
            v_cejec_acumuladas,
            0, 0, 0, 0 -- Se pueden mapear fórmulas financieras si se requiere
        );

    END PR_PROCESAR_NUEVO_ANEXO;

    --Nueva versión que acepta rango de fechas por Acrtibvidad al crear el Anexo.
    PROCEDURE PR_PROCESAR_NUEVO_ANEXO2 (
    p_anexo_id         IN NUMBER,
    p_fecha_inicio     IN DATE,
    p_fecha_fin        IN DATE,
    p_rubro            IN VARCHAR2,
    p_total            IN NUMBER,
    p_precio_unitario  IN NUMBER,
    p_actividad_id     IN NUMBER
) IS
    v_contrato_id          NUMBER;
    v_planilla_id          PLANILLA_CONTRACTUAL.PLANILLA_ID%TYPE;
    v_nro_planilla          PLANILLA_CONTRACTUAL.NRO_PLANILLA%TYPE;
    v_rubro_num            NUMBER;
    
    -- Variables de cálculo
    v_cejec_anteriores     NUMBER := 0;
    v_cejec_este_periodo   NUMBER := NVL(p_total, 0);
    v_cejec_acumuladas     NUMBER := 0;
BEGIN
    -- Validar fechas de entrada
    IF p_fecha_inicio IS NULL OR p_fecha_fin IS NULL OR p_fecha_inicio > p_fecha_fin THEN
        RAISE_APPLICATION_ERROR(-20001, 'El rango de fechas especificado no es válido.');
    END IF;

    -- Precalculo en PL/SQL para permitir que la consulta SQL use índices en d.RUBRO
    v_rubro_num := TO_NUMBER(REGEXP_SUBSTR(p_rubro, '^[0-9]+'));

    -- 1. OBTENER EL CONTRATO ID
    SELECT contrato.contrato_id 
      INTO v_contrato_id
      FROM LIBRO_OBRA_ACTIVIDADES_realizadas LOAR 
     INNER JOIN libro_de_obra LDO ON ldo.libro_obra_id = loar.libro_obra_id
     INNER JOIN Contrato ON ldo.contrato_id = contrato.contrato_id
     WHERE LOAR.ACTIVIDAD_ID = p_actividad_id
       AND ROWNUM = 1;

    -- 2. VERIFICAR O CREAR CABECERA DE PLANILLA PARA EL PERÍODO ESPECÍFICO
    BEGIN
        SELECT PLANILLA_ID
          INTO v_planilla_id
          FROM PLANILLA_CONTRACTUAL
         WHERE CONTRATO_ID = v_contrato_id
           AND FECHA_INICIO = p_fecha_inicio
           AND FECHA_FIN    = p_fecha_fin
           AND ROWNUM = 1;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Secuencial para el número de planilla del contrato
            SELECT COALESCE(MAX(NRO_PLANILLA), 0) + 1
              INTO v_nro_planilla
              FROM PLANILLA_CONTRACTUAL
             WHERE CONTRATO_ID = v_contrato_id;

            INSERT INTO PLANILLA_CONTRACTUAL (
                NRO_PLANILLA, 
                FECHA_CREAR_PLANILLA, 
                FECHA_INICIO, 
                FECHA_FIN, 
                CONTRATO_ID,
                ESTADO_ID
            ) VALUES (
                v_nro_planilla, 
                SYSDATE, 
                p_fecha_inicio, 
                p_fecha_fin, 
                v_contrato_id,
                62--Planilla REVISION	PLANILLAS CONTRACTUALES
            ) RETURNING PLANILLA_ID INTO v_planilla_id;
    END;

    -- 3. CÁLCULO DE ACUMULADOS HISTÓRICOS (Suma ejecuciones de períodos estrictamente anteriores)
    SELECT COALESCE(SUM(d.CANTIDAD), 0)
      INTO v_cejec_anteriores
      FROM PLANILLA_CONTRACTUAL_DETALLE d
      JOIN PLANILLA_CONTRACTUAL m ON (d.PLANILLA_ID = m.PLANILLA_ID)
     WHERE m.CONTRATO_ID = v_contrato_id
       AND d.RUBRO       = v_rubro_num
       AND m.FECHA_FIN   < p_fecha_inicio;

    v_cejec_acumuladas := v_cejec_anteriores + v_cejec_este_periodo;

    -- 4. INSERCIÓN DEL DETALLE DE LA PLANILLA
    INSERT INTO PLANILLA_CONTRACTUAL_DETALLE (
        PLANILLA_ID, 
        ANEXO_VOLUMENOBRA_ID, 
        RUBRO,
        UNIDAD, 
        CANTIDAD, 
        PRECIO_UNITARIO, 
        PRECIO_TOTAL,
        CEJEC_ANTERIORES, 
        CEJEC_ESTEPERIODO, 
        CEJEC_ACUMULADAS,
        VALEJEC_ANTERIORES, 
        VALEJEC_ACUMULADAS, 
        PORC_AVANCE_ACUMULADO
    ) VALUES (
        v_planilla_id,
        p_anexo_id,
        v_rubro_num,
        'UND',
        p_total,
        p_precio_unitario,
        (p_total * p_precio_unitario),
        v_cejec_anteriores,
        v_cejec_este_periodo,
        v_cejec_acumuladas,
        (v_cejec_anteriores * p_precio_unitario),
        (v_cejec_acumuladas * p_precio_unitario),
        0
    );

END PR_PROCESAR_NUEVO_ANEXO2;

END PKG_GENERACION_PLANILLAS;