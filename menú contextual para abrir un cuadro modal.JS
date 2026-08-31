// Cerrar el menú si hacen clic izquierdo en cualquier otro lugar de la pantalla
$(document).on("mousedown", function(e) {
    if (!$(e.target).closest("#calendar-context-menu").length) 
          $("#calendar-context-menu").hide();
    }
});
// Acción de clic sobre "Anexo de Volumen de Obra" - APERTURA MODAL DEFINITIVA
$(document).on("click", "#opt-anexo-volumen", function() {
       $("#calendar-context-menu").hide();
            var fechaParametro = window.apexSelectedCalendarDateLatina || '';
            // Llamamos al proceso PL/SQL del servidor
           apex.server.process  'OBTENER_URL_MODAL', 
           {
              x01: fechaParametro 
           },
          {
             dataType: 'text',
             loadingIndicator: '#calendar-context-menu',
             success: function(pData) {
                var urlSegura = pData.trim();
                if (urlSegura) {                   
                  // Usamos la API de navegación nativa para abrir el diálogo pasando la URL  
                 //que ya viene con su Checksum seguro
                 apex.navigation.dialog(
                        urlSegura,
                        { 
                            title: 'Anexo Volumen de Obra', 
                            height: 'auto', 
                            width: '720', 
                            modal: true 
                        },
                        'a-Dialog--standard',
                        $('#calendar-context-menu')
                    );
                } else {
                    console.error("El servidor retornó una URL vacía.");
                }
            },
            error: function(xhr, status, error) {
                console.error("Error al obtener la URL encriptada:", error);
            }
        }
    );
});
