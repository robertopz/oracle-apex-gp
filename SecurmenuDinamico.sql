CREATE OR REPLACE VIEW VW_SECUR_MENU_APEX AS
SELECT 
    LEVEL AS lvl,
    nombre_menu AS label,
    -- Formato declarativo nativo para las URL de páginas en APEX
    CASE 
        WHEN pagina IS NOT NULL THEN 'f?p=' || SYS_CONTEXT('APEX$SESSION', 'APP_ID') || ':' || pagina || ':' || SYS_CONTEXT('APEX$SESSION', 'APP_SESSION') || '::NO:::'
        ELSE NULL 
    END AS target,
    'NO' AS is_current_list_entry,
    icono AS image
FROM (
    -- Subconsulta única con DISTINCT para consolidar accesos si el usuario tiene múltiples roles
    SELECT DISTINCT
        m.menu_id,
        m.submenudeid,
        m.nombre_menu,
        m.icono,
        m.pagina,
        m.orden_prioridad
    FROM secur_menu m
    JOIN secur_menu_roles mr      ON m.menu_id = mr.menu_id
    JOIN secur_roles_usuarios ru  ON mr.rol_id = ru.rol_id
    JOIN secur_usuarios_app u     ON ru.usuario_id = u.usuario_id
    --WHERE UPPER(u.nombreusuario) = UPPER(SYS_CONTEXT('APEX$SESSION', 'APP_USER'))
      AND u.activo_sn = 'S'
      AND ru.activo_sn = 'S'
      AND mr.activo_sn = 'S'
)
START WITH submenudeid IS NULL
CONNECT BY PRIOR menu_id = submenudeid
ORDER SIBLINGS BY orden_prioridad;