CREATE OR REPLACE EDITIONABLE PACKAGE "GPROY_ELEL"."PKG_GESTION_OBRAS" AS

  /**
  * Orquesta todo el flujo de registro posterior a la creación de un Proyecto.
  * Realiza la inserción del Contrato, la apertura del Libro de Obra 
  * y la transferencia masiva de actividades del cronograma.
  */
  PROCEDURE PRC_TRANSFERIR_ACTIVIDADES (
    p_proyecto_id   IN NUMBER,
    p_libro_obra_id IN NUMBER
  );
  PROCEDURE PRC_PROCESAR_FLUJO_OBRA (
    p_proyecto_id       IN  NUMBER,
    p_usuario_id        IN  NUMBER,
    p_contratista_id    IN  NUMBER   DEFAULT NULL,
    p_administrador_id  IN  NUMBER   DEFAULT NULL,
    p_fiscalizador_id   IN  NUMBER   DEFAULT NULL,
    p_comentario        IN  VARCHAR2 DEFAULT NULL,
    p_contrato_id_out   OUT NUMBER,
    p_libro_obra_id_out OUT NUMBER
  );

END PKG_GESTION_OBRAS;
/
CREATE OR REPLACE EDITIONABLE PACKAGE BODY "GPROY_ELEL"."PKG_GESTION_OBRAS" AS

  -----------------------------------------------------------------------------
  -- PROCEDIMIENTO PRIVADO: Transferencia Óptima de Actividades (Paso 3)
  -----------------------------------------------------------------------------
  PROCEDURE PRC_TRANSFERIR_ACTIVIDADES (
    p_proyecto_id   IN NUMBER,
    p_libro_obra_id IN NUMBER
  ) IS
  BEGIN
    -- Se utiliza INSERT masivo directo (Set-Based Approach) para máximo rendimiento.
    -- El filtro NOT EXISTS previene la duplicidad de datos en ejecuciones concurrentes o repetidas.
    INSERT/*+ NO_PARALLEL */ INTO LIBRO_OBRA_ACTIVIDADES_REALIZADAS (
      ACTIVIDAD_ID,
      LIBRO_OBRA_ID,
      ACTIVIDAD_REALIZADA,
      LUGAR,
      ACTIVIDAD_ID_CRONOGRAMA
    )
    SELECT 
      SEQ_LIBRO_ACTIVIDAD.NEXTVAL, -- Asumiendo una secuencia para la PK del detalle del libro
      p_libro_obra_id,
      CAST(act.DESCRIPCION AS VARCHAR2(6000)), -- Conversión segura de CLOB a VARCHAR2 según tu destino
      'NO ESPECIFICADO',                       -- Campo obligatorio o por defecto en destino
      act.ACTIVIDAD_ID
    FROM cronograma_actividades cro
    JOIN CRONOGRA_ACTIVIDADES_DETALLES act ON act.CRONOGRAMA_ID = cro.CRONOGRAMA_ID
    WHERE cro.PROYECTO_ID = p_proyecto_id
      AND NOT EXISTS (
        SELECT 1 
        FROM LIBRO_OBRA_ACTIVIDADES_REALIZADAS dest 
        WHERE dest.ACTIVIDAD_ID_CRONOGRAMA = act.ACTIVIDAD_ID
          AND dest.LIBRO_OBRA_ID = p_libro_obra_id
      );

    DBMS_OUTPUT.PUT_LINE('Actividades transferidas correctamente: ' || SQL%ROWCOUNT);
  END PRC_TRANSFERIR_ACTIVIDADES;


  -----------------------------------------------------------------------------
  -- PROCEDIMIENTO PÚBLICO: Orquestador Principal
  -----------------------------------------------------------------------------
  PROCEDURE PRC_PROCESAR_FLUJO_OBRA (
    p_proyecto_id       IN  NUMBER,
    p_usuario_id        IN  NUMBER,
    p_contratista_id    IN  NUMBER   DEFAULT NULL,
    p_administrador_id  IN  NUMBER   DEFAULT NULL,
    p_fiscalizador_id   IN  NUMBER   DEFAULT NULL,
    p_comentario        IN  VARCHAR2 DEFAULT NULL,
    p_contrato_id_out   OUT NUMBER,
    p_libro_obra_id_out OUT NUMBER
  ) IS
    v_monto_proyecto FLOAT;
    v_fecha_fin_proj DATE;
    v_anticipo_val   NUMBER(8,2);

    v_contrato_id    NUMBER(38);
    v_libro_obra_id  NUMBER(38);
  BEGIN

    -- 0. Obtener parámetros requeridos desde el PROYECTO previamente insertado
    BEGIN
      SELECT MONTO, FECHA_FIN_EJECUCION, ANTICIPO_VALOR
      INTO v_monto_proyecto, v_fecha_fin_proj, v_anticipo_val
      FROM PROYECTO
      WHERE PROYECTO_ID = p_proyecto_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        raise_application_error(-20001, 'Error: El PROYECTO_ID suministrado no existe.');
    END;

    -- PASO 1: Insertar el CONTRATO después de insertar el PROYECTO
    --v_contrato_id := SEQ_CONTRATO.NEXTVAL; -- Asumiendo secuencia para Contratos

    INSERT INTO CONTRATO (
      --CONTRATO_ID,
      PROYECTO_ID,
      ANTICIPO_VALOR,
      FECHA_CONTRATO,
      FECHA_FIN,
      USUARIO_ID,
      TIEMPO_MESES,
      COMENTARIO,
      CONTRATISTA_ID,
      ADMINISTRADOR_ID,
      FISCALIZADOR_ID
    ) VALUES (
      --v_contrato_id,
      p_proyecto_id,
      v_anticipo_val,
      SYSDATE,                                                   -- Fecha actual del contrato
      NVL(v_fecha_fin_proj, ADD_MONTHS(SYSDATE, 12)),            -- Fecha fin estipulada o por defecto
      p_usuario_id,
      MONTHS_BETWEEN(NVL(v_fecha_fin_proj, ADD_MONTHS(SYSDATE, 12)), SYSDATE), -- Cálculo estimado de meses
      p_comentario,
      p_contratista_id,
      p_administrador_id,
      p_fiscalizador_id
    )returning contrato_id into v_contrato_id;


    -- PASO 2: Crear el Libro de Obra después de crear el CONTRATO
    --v_libro_obra_id := SEQ_LIBRO_OBRA.NEXTVAL; -- Asumiendo secuencia para Libro de Obra

    INSERT INTO LIBRO_DE_OBRA (
      --LIBRO_OBRA_ID,
      CONTRATO_ID,
      OBSERVACIONES_CONTRATISTA,
      OBSERVACIONES_ADMINISTRADOR,
      OBSERVACIONES_FISCALIZADOR
    ) VALUES (
      --v_libro_obra_id,
      v_contrato_id,
      'Apertura automática - Esperando observaciones',
      'Apertura automática - Esperando observaciones',
      'Apertura automática - Esperando observaciones'
    )returning libro_obra_id into v_libro_obra_id;


    -- PASO 3: Transferir las actividades de forma optimizada
    PRC_TRANSFERIR_ACTIVIDADES(p_proyecto_id, v_libro_obra_id);


    -- Asignación de parámetros de salida para confirmación externa
    p_contrato_id_out   := v_contrato_id;
    p_libro_obra_id_out := v_libro_obra_id;

  EXCEPTION
    WHEN OTHERS THEN
      -- Log o propagación de errores manteniendo consistencia atómica
      DBMS_OUTPUT.PUT_LINE('Error crítico detectado en el paquete: ' || SQLERRM);
      RAISE;
  END PRC_PROCESAR_FLUJO_OBRA;

END PKG_GESTION_OBRAS;
/

