CREATE OR REPLACE EDITIONABLE PACKAGE "GPROY_ELEL"."PKG_GESTION_CONTINGENCIAS3" AS

  -- (Se mantiene) Registra la contingencia inicial
  PROCEDURE PRC_REGISTRAR_CONTINGENCIA (
    p_contrato_id             IN NUMBER,
    p_descripcion_observacion IN VARCHAR2,
    p_dias_subsanacion        IN NUMBER,
    p_usuario_registra_id     IN NUMBER,
    p_planilla_id             IN NUMBER DEFAULT NULL
  );

  -- (NUEVO) El contratista registra su acción de subsanación
  PROCEDURE PRC_REGISTRAR_RESPUESTA (
    p_contingencia_id        IN NUMBER,
    p_descripcion_accion     IN CLOB,
    p_usuario_contratista_id IN NUMBER,
    o_respuesta_id           OUT NUMBER -- Retorna el ID para adjuntar la evidencia luego
  );

  -- (MODIFICADO) El fiscalizador evalúa la respuesta y aprueba o rechaza la subsanación
  PROCEDURE PRC_EVALUAR_CONTINGENCIA (
    p_contingencia_id     IN NUMBER,
    p_usuario_fiscaliza   IN NUMBER,
    p_es_aprobada         IN VARCHAR2, -- 'S' = Aprobada (Subsanada), 'N' = Rechazada
    p_motivo_rechazo      IN VARCHAR2 DEFAULT NULL
  );

  -- (Se mantiene) Job nocturno
  PROCEDURE PRC_VERIFICAR_VENCIMIENTOS;
  
  -- (NUEVO) Registra un anexo fotográfico garantizando el diseño de arco (XOR)
  PROCEDURE PRC_REGISTRAR_EVIDENCIA (
    p_nombre_archivo  IN VARCHAR2,
    p_mime_type       IN VARCHAR2,
    p_anexo           IN BLOB,
    p_contingencia_id IN NUMBER DEFAULT NULL,
    p_respuesta_id    IN NUMBER DEFAULT NULL,
    o_evidencia_id    OUT NUMBER
  );

END PKG_GESTION_CONTINGENCIAS3;
/
CREATE OR REPLACE EDITIONABLE PACKAGE BODY "GPROY_ELEL"."PKG_GESTION_CONTINGENCIAS3" AS

  -- ... (PRC_REGISTRAR_CONTINGENCIA se mantiene igual al anterior) ...
   PROCEDURE PRC_REGISTRAR_CONTINGENCIA (
    p_contrato_id             IN NUMBER,
    p_descripcion_observacion IN VARCHAR2,
    p_dias_subsanacion        IN NUMBER,
    p_usuario_registra_id     IN NUMBER,
    p_planilla_id             IN NUMBER DEFAULT NULL
  ) IS
    v_existe_abierta NUMBER;
  BEGIN
    -- 1. Validar que no exista ya una contingencia activa sobre este contrato
    --81 ABIERTA, 82 SUBSANADA, 83 INCUMPLIDA
    SELECT COUNT(*) INTO v_existe_abierta 
    FROM CONTINGENCIA_CONTRATO cc
    INNER JOIN estados_configurados ec ON cc.ESTADO_CONTINGENCIA_ID = ec.ESTADO_ID
    WHERE cc.CONTRATO_ID = p_contrato_id AND ec.NOMBRE_ESTADOS = 'ABIERTA';

    IF v_existe_abierta > 0 THEN
      RAISE_APPLICATION_ERROR(-20101, 'Operación Cancelada: Ya existe un proceso de contingencia abierto para este contrato.');
    END IF;

    -- 2. Insertar el registro físico de la disputa técnica
    INSERT INTO CONTINGENCIA_CONTRATO (
        CONTRATO_ID,
        DESCRIPCION_OBSERVACION,
        FECHA_LIMITE_SUBSANACION,
        ESTADO_CONTINGENCIA_ID,
        USUARIO_REGISTRA_ID,
        PLANILLA_ID -- Incluimos el nuevo campo
    ) VALUES (
        p_contrato_id,
        p_descripcion_observacion,
        SYSDATE + p_dias_subsanacion,
        81, -- 'ABIERTA'
        p_usuario_registra_id,
        p_planilla_id
    );

    -- 3. REGLA DE NEGOCIO: Bloquear Planilla si fue provista
    IF p_planilla_id IS NOT NULL THEN
       UPDATE PLANILLA_CONTRACTUAL
       SET ESTADO_ID = 99, -- Ej: 99 = 'RETENIDA'
           -- En Oracle 12c+, concatenar VARCHAR2 a CLOB es nativo, pero usar TO_CLOB es más seguro y explícito
           OBSERVACION_TECNICA = TO_CLOB('Planilla retenida por contingencia técnica: ' || p_descripcion_observacion)
       WHERE PLANILLA_ID = p_planilla_id;
    END IF;

    -- 4. Actualizar el estado del Contrato Maestro
    UPDATE CONTRATO 
    SET COMENTARIO = 'Contrato suspendido. ' || 
                     CASE WHEN p_planilla_id IS NOT NULL THEN 'Planilla Nro. ID ' || p_planilla_id || ' retenida.' 
                     ELSE 'Suspensión general de obra.' END
    WHERE CONTRATO_ID = p_contrato_id;

  END PRC_REGISTRAR_CONTINGENCIA;
  
  

  -- =========================================================================
  -- PROCEDIMIENTO: PRC_REGISTRAR_RESPUESTA (PERFIL: CONTRATISTA)
  -- =========================================================================
  PROCEDURE PRC_REGISTRAR_RESPUESTA (
    p_contingencia_id        IN NUMBER,
    p_descripcion_accion     IN CLOB,
    p_usuario_contratista_id IN NUMBER,
    o_respuesta_id           OUT NUMBER
  ) IS
    v_estado_actual NUMBER;
  BEGIN
    -- 1. Validar que la contingencia siga abierta
    SELECT ESTADO_CONTINGENCIA_ID INTO v_estado_actual
    FROM CONTINGENCIA_CONTRATO
    WHERE CONTINGENCIA_ID = p_contingencia_id;

    IF v_estado_actual <> 81 /* ABIERTA */ THEN
       RAISE_APPLICATION_ERROR(-20104, 'No puede responder a una contingencia que ya está cerrada o incumplida.');
    END IF;

    -- 2. Insertar la respuesta y recuperar el ID generado automáticamente
    -- Asumiendo que RESPUESTA_ID es un GENERATED ALWAYS AS IDENTITY
    INSERT INTO CONTINGENCIA_CONTRATO_RESPUESTA (
      CONTINGENCIA_ID,
      FECHA_REGISTRO,
      DESCRIPCION_ACCION,
      USUARIO_CONTRATISTA_ID
    ) VALUES (
      p_contingencia_id,
      SYSTIMESTAMP,
      p_descripcion_accion,
      p_usuario_contratista_id
    ) RETURNING RESPUESTA_ID INTO o_respuesta_id;

    -- Nota: Al retornar 'o_respuesta_id', tu aplicación (APEX, Java, C#, etc.) 
    -- puede tomar este valor inmediatamente para insertar en CONTINGENCIA_CONTRATO_EVIDENCIA.

  END PRC_REGISTRAR_RESPUESTA;

  -- =========================================================================
  -- PROCEDIMIENTO: PRC_EVALUAR_CONTINGENCIA (PERFIL: FISCALIZADOR)
  -- =========================================================================
  PROCEDURE PRC_EVALUAR_CONTINGENCIA (
    p_contingencia_id     IN NUMBER,
    p_usuario_fiscaliza   IN NUMBER,
    p_es_aprobada         IN VARCHAR2, 
    p_motivo_rechazo      IN VARCHAR2 DEFAULT NULL
  ) IS
    v_contrato_id CONTRATO.CONTRATO_ID%TYPE;
    v_planilla_id CONTINGENCIA_CONTRATO.PLANILLA_ID%TYPE;
    v_estado      CONTINGENCIA_CONTRATO.ESTADO_CONTINGENCIA_ID%TYPE;
  BEGIN
    -- Obtener datos de la contingencia
    SELECT CONTRATO_ID, PLANILLA_ID, ESTADO_CONTINGENCIA_ID 
    INTO v_contrato_id, v_planilla_id, v_estado
    FROM CONTINGENCIA_CONTRATO 
    WHERE CONTINGENCIA_ID = p_contingencia_id;

    IF v_estado <> 81 /* 'ABIERTA' */ THEN
      RAISE_APPLICATION_ERROR(-20102, 'La contingencia no se encuentra en estado de evaluación.');
    END IF;

    IF p_es_aprobada = 'S' THEN
      -- APROBADA: Subsanar la contingencia
      UPDATE CONTINGENCIA_CONTRATO
      SET ESTADO_CONTINGENCIA_ID = 82, /* 'SUBSANADA' */
          FECHA_RESOLUCION = SYSDATE
      WHERE CONTINGENCIA_ID = p_contingencia_id;

      -- Liberar la Planilla vinculada si existe
      IF v_planilla_id IS NOT NULL THEN
         UPDATE PLANILLA_CONTRACTUAL
         SET ESTADO_ID = 91, -- HABILITADA
             OBSERVACION_TECNICA = TO_CLOB('Contingencia subsanada aprobada por Fiscalización.')
         WHERE PLANILLA_ID = v_planilla_id;
      END IF;

      -- Actualizar Contrato
      UPDATE CONTRATO
      SET COMENTARIO = 'Contingencia solventada exitosamente.'
      WHERE CONTRATO_ID = v_contrato_id;

    ELSIF p_es_aprobada = 'N' THEN
      -- RECHAZADA: La contingencia sigue abierta, pero notificamos el rechazo
      -- (Opcionalmente podrías cambiar a estado 'INCUMPLIDA' si es grave)
      UPDATE CONTRATO
      SET COMENTARIO = 'Fiscalización RECHAZÓ la respuesta de subsanación. Motivo: ' || p_motivo_rechazo
      WHERE CONTRATO_ID = v_contrato_id;

      -- Si existe planilla, reforzamos que sigue retenida
      IF v_planilla_id IS NOT NULL THEN
         UPDATE PLANILLA_CONTRACTUAL
         SET OBSERVACION_TECNICA = TO_CLOB('Respuesta rechazada. La planilla continúa retenida.')
         WHERE PLANILLA_ID = v_planilla_id;
      END IF;

    ELSE
       RAISE_APPLICATION_ERROR(-20105, 'El parámetro de aprobación debe ser S o N.');
    END IF;

  END PRC_EVALUAR_CONTINGENCIA;

  -- ... (PRC_VERIFICAR_VENCIMIENTOS se mantiene igual al anterior) ...
  
  -- =========================================================================
  -- PROCEDIMIENTO: PRC_REGISTRAR_EVIDENCIA
  -- OBJETIVO: Almacena el BLOB y valida el arco exclusivo (XOR)
  -- =========================================================================
  PROCEDURE PRC_REGISTRAR_EVIDENCIA (
    p_nombre_archivo  IN VARCHAR2,
    p_mime_type       IN VARCHAR2,
    p_anexo           IN BLOB,
    p_contingencia_id IN NUMBER DEFAULT NULL,
    p_respuesta_id    IN NUMBER DEFAULT NULL,
    o_evidencia_id    OUT NUMBER
  ) IS
  BEGIN
    -- 1. Validación de Regla de Negocio (XOR Exclusivo)
    -- Ambas llaves presentes: Error
    IF (p_contingencia_id IS NOT NULL AND p_respuesta_id IS NOT NULL) THEN
        RAISE_APPLICATION_ERROR(-20106, 'Error de Integridad: La fotografía no puede asociarse simultáneamente a la contingencia original y a la respuesta.');
    END IF;

    -- Ninguna llave presente: Error
    IF (p_contingencia_id IS NULL AND p_respuesta_id IS NULL) THEN
        RAISE_APPLICATION_ERROR(-20107, 'Error de Integridad: Debe indicar a qué evento (Contingencia o Respuesta) pertenece la fotografía.');
    END IF;

    -- 2. Inserción de la evidencia física y el archivo BLOB
    -- Utilizamos CURRENT_TIMESTAMP para capturar la zona horaria de la sesión del cliente
    -- (vital para el tipo TIMESTAMP WITH LOCAL TIME ZONE)
    INSERT INTO CONTINGENCIA_CONTRATO_EVIDENCIA (
        CONTINGENCIA_ID,
        RESPUESTA_ID,
        FECHA_HORA_EVIDENCIA,
        ANEXO,
        MIME_TYPE,
        NOMBRE_ARCHIVO,
        FECHA_ACTUALIZACION
    ) VALUES (
        p_contingencia_id,
        p_respuesta_id,
        CURRENT_TIMESTAMP, 
        p_anexo,
        p_mime_type,
        p_nombre_archivo,
        SYSDATE
    ) RETURNING EVIDENCIA_ID INTO o_evidencia_id;

  END PRC_REGISTRAR_EVIDENCIA;

PROCEDURE PRC_VERIFICAR_VENCIMIENTOS IS
    CURSOR c_vencidos IS 
      SELECT CONTINGENCIA_ID, CONTRATO_ID, PLANILLA_ID 
      FROM CONTINGENCIA_CONTRATO
      WHERE ESTADO_CONTINGENCIA_ID = 81 /*'ABIERTA'*/ 
        AND FECHA_LIMITE_SUBSANACION < SYSDATE;
  BEGIN
    FOR r_vencido IN c_vencidos LOOP
      -- 1. Marcar el estado de la contingencia como INCUMPLIDA
      UPDATE CONTINGENCIA_CONTRATO
      SET ESTADO_CONTINGENCIA_ID = 83 /*'INCUMPLIDA'*/,
          FECHA_RESOLUCION = SYSDATE
      WHERE CONTINGENCIA_ID = r_vencido.CONTINGENCIA_ID;

      -- 2. REGLA DE NEGOCIO: Anular definitivamente la planilla si el plazo venció
      IF r_vencido.PLANILLA_ID IS NOT NULL THEN
         UPDATE PLANILLA_CONTRACTUAL
         SET ESTADO_ID = 100, -- Ej: 100 = 'ANULADA / RECHAZADA'
             OBSERVACION_TECNICA = TO_CLOB('Planilla rechazada definitivamente por incumplimiento del plazo de subsanación de la contingencia.')
         WHERE PLANILLA_ID = r_vencido.PLANILLA_ID;
      END IF;

      -- 3. Ejecución automatizada de la Regla de Negocio: Terminación Unilateral
      UPDATE CONTRATO
      SET COMENTARIO = 'CONTRATO TERMINADO UNILATERALMENTE POR INCUMPLIMIENTO EN PLAZO DE SUBSANACIÓN.'
      WHERE CONTRATO_ID = r_vencido.CONTRATO_ID;

    END LOOP;
  END PRC_VERIFICAR_VENCIMIENTOS;
END PKG_GESTION_CONTINGENCIAS3;
/

