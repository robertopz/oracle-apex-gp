CREATE OR REPLACE EDITIONABLE PACKAGE "GPROY_ELEL"."PKG_LIQUIDACION_OBRA" AS

  -- Estados lógicos de las planillas (Columna PLANILLA_CONTRACTUAL.ESTADO_ID)
  CN_ESTADO_BORRADOR  CONSTANT NUMBER := 64; -- En preparación
  CN_ESTADO_REVISION  CONSTANT NUMBER := 62; -- Enviada a Fiscalización
  CN_ESTADO_APROBADA  CONSTANT NUMBER := 61; -- Validada y aprobada para pago
  CN_ESTADO_DEVUELTA  CONSTANT NUMBER := 63; -- Devuelta con observaciones
  /*61	Planilla APROBADA
    62	Planilla REVISION
    63	Planilla DEVUELTA
    64	Planilla BORRADOR*/
  /**
   * Cambia el estado de una planilla a 'Revisión'.
   * Controla que la sumatoria acumulada de planillas no rompa el monto total del proyecto.
   */
  PROCEDURE PRC_PRESENTAR_PLANILLA (
    p_planilla_id    IN NUMBER,
    p_usuario_id     IN NUMBER
  );

  /**
   * Registra la aprobación o devolución definitiva por parte del Fiscalizador.
   * Actualiza las firmas de auditoría en el contrato maestro.
   */
  PROCEDURE PRC_EVALUAR_PLANILLA (
    p_planilla_id     IN NUMBER,
    p_fiscalizador_id IN NUMBER,
    p_nuevo_estado_id IN NUMBER,
    p_comentario      IN VARCHAR2
  );

END PKG_LIQUIDACION_OBRA;
/
CREATE OR REPLACE EDITIONABLE PACKAGE BODY "GPROY_ELEL"."PKG_LIQUIDACION_OBRA" AS
--Ejecutar por el CONTRATISTA o Residente de Obra.
  PROCEDURE PRC_PRESENTAR_PLANILLA (
    p_planilla_id    IN NUMBER,
    p_usuario_id     IN NUMBER
  ) IS
    v_contrato_id    PLANILLA_CONTRACTUAL.CONTRATO_ID%TYPE;
    v_proyecto_id    CONTRATO.PROYECTO_ID%TYPE;
    v_monto_planilla PLANILLA_CONTRACTUAL.MONTO_TOTAL%TYPE;
    v_monto_maximo   PROYECTO.MONTO%TYPE;
    v_monto_acum     NUMBER(12,2);
    v_estado_actual  PLANILLA_CONTRACTUAL.ESTADO_ID%TYPE;
  BEGIN
    -- 1. Obtener la información de la planilla desde PLANILLA_CONTRACTUAL
    SELECT CONTRATO_ID, ESTADO_ID, MONTO_TOTAL
    INTO v_contrato_id, v_estado_actual, v_monto_planilla
    FROM PLANILLA_CONTRACTUAL
    WHERE PLANILLA_ID = p_planilla_id;

    -- 2. Validación de proceso: Bloquear reenvíos o ediciones si ya no está en borrador/devuelta
    IF v_estado_actual IN (CN_ESTADO_REVISION, CN_ESTADO_APROBADA) THEN
      RAISE_APPLICATION_ERROR(-20001, 'Operación denegada: La planilla ya se encuentra bajo revisión o aprobada.');
    END IF;

    -- 3. Obtener el ID del proyecto desde el contrato maestro
    SELECT PROYECTO_ID
    INTO v_proyecto_id
    FROM CONTRATO
    WHERE CONTRATO_ID = v_contrato_id;

    -- 4. Extraer el presupuesto base de la tabla PROYECTO
    SELECT MONTO 
    INTO v_monto_maximo 
    FROM PROYECTO 
    WHERE PROYECTO_ID = v_proyecto_id;

    -- 5. Calcular la sumatoria de las planillas aprobadas con anterioridad para este contrato
    SELECT NVL(SUM(MONTO_TOTAL), 0)
    INTO v_monto_acum
    FROM PLANILLA_CONTRACTUAL
    WHERE CONTRATO_ID = v_contrato_id
      AND ESTADO_ID = CN_ESTADO_APROBADA
      AND PLANILLA_ID <> p_planilla_id;

    -- Consolidar con el monto de la planilla actual en proceso
    v_monto_acum := v_monto_acum + NVL(v_monto_planilla, 0);

    -- 6. Regla de Negocio: Controlar que no se rompa el techo financiero adjudicado
    IF v_monto_acum > v_monto_maximo THEN
      RAISE_APPLICATION_ERROR(-20002, 'Desviación Financiera: El monto acumulado de planillas (' || 
                              v_monto_acum || ') excede el valor total del proyecto (' || v_monto_maximo || ').');
    END IF;

    -- 7. Actualizar el estado físico de la planilla en control transaccional
    UPDATE PLANILLA_CONTRACTUAL
    SET ESTADO_ID = CN_ESTADO_REVISION,
        FECHA_CREAR_PLANILLA = SYSDATE
    WHERE PLANILLA_ID = p_planilla_id;

    -- 8. Actualizar firmas de auditoría de control en el contrato maestro
    UPDATE CONTRATO
    SET USUARIO_ID = p_usuario_id,
        COMENTARIO = 'Planilla periódica enviada al Fiscalizador para su respectiva auditoría técnica.'
    WHERE CONTRATO_ID = v_contrato_id;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20003, 'Error: No se encontró la estructura de datos solicitada.');
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20099, 'Fallo crítico en el motor PL/SQL (PRC_PRESENTAR_PLANILLA): ' || SQLERRM);
  END PRC_PRESENTAR_PLANILLA;

--Ejecutar por el Fiscalizador
  PROCEDURE PRC_EVALUAR_PLANILLA (
    p_planilla_id     IN NUMBER,
    p_fiscalizador_id IN NUMBER,
    p_nuevo_estado_id IN NUMBER,
    p_comentario      IN VARCHAR2
  ) IS
    v_contrato_id   PLANILLA_CONTRACTUAL.CONTRATO_ID%TYPE;
    v_estado_actual PLANILLA_CONTRACTUAL.ESTADO_ID%TYPE;
  BEGIN
    -- 1. Validar existencia de la transacción mensual
    SELECT CONTRATO_ID, ESTADO_ID 
    INTO v_contrato_id, v_estado_actual
    FROM PLANILLA_CONTRACTUAL 
    WHERE PLANILLA_ID = p_planilla_id;

    -- 2. Validación de flujo: Debe estar en revisión por el fiscalizador
    IF v_estado_actual <> CN_ESTADO_REVISION THEN
      RAISE_APPLICATION_ERROR(-20004, 'Violación de Proceso: Solo se pueden evaluar planillas que estén en estado de revisión.');
    END IF;

    -- 3. Validar consistencia del parámetro de destino fiscal
    IF p_nuevo_estado_id NOT IN (CN_ESTADO_APROBADA, CN_ESTADO_DEVUELTA) THEN
      RAISE_APPLICATION_ERROR(-20005, 'Error de Parámetro: El estado de destino debe ser estrictamente Aprobada o Devuelta.');
    END IF;

    -- 4. Modificar el estado transaccional de la planilla
    UPDATE PLANILLA_CONTRACTUAL
    SET ESTADO_ID = p_nuevo_estado_id
    WHERE PLANILLA_ID = p_planilla_id;

    -- 5. Estampar las observaciones y asignar el Fiscalizador responsable en la cabecera del contrato
    UPDATE CONTRATO
    SET FISCALIZADOR_ID = p_fiscalizador_id,
        COMENTARIO = SUBSTR(p_comentario, 1, 3000)
    WHERE CONTRATO_ID = v_contrato_id;

  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20006, 'Error: Registro de planilla no localizado.');
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20099, 'Fallo crítico en el motor PL/SQL (PRC_EVALUAR_PLANILLA): ' || SQLERRM);
  END PRC_EVALUAR_PLANILLA;

END PKG_LIQUIDACION_OBRA;
/

