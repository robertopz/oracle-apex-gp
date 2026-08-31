    var region = apex.region("mi_ig_volumen");
    if (!region) {
        console.log("Error: No se encontró la región con Static ID 'mi_ig_volumen'");
        return;
    }
   var widget = region.widget();
    if (!widget) {
        console.log("El widget aún no está listo, reintentando en 50ms...");
        setTimeout(inicializarSumatoriaIG, 50);
        return;
    }
    var gridView = widget.interactiveGrid("getViews", "grid");
    var model = gridView ? gridView.model : null;
    if (!model) {
        console.log("El modelo de datos de la Grid aún no existe, reintentando en 50ms...");
        setTimeout(inicializarSumatoriaIG, 50);
        return;
    }
    console.log("2. ¡Modelo de la IG detectado con éxito!");
    // Función principal de cálculo
    // Función principal de cálculo optimizada para decimales y formatos regionales
    var calcularGranTotal = function() {
        console.log("3. Ejecutando la función calcularGranTotal() con soporte decimal...");
        var sumaTotal = 0;
        model.forEach(function(record) {
            var meta = model.getRecordMetadata(model.getRecordId(record));
            if (!meta || !meta.deleted) {
                // 1. Obtenemos el valor crudo en texto
                var valorCelda = model.getValue(record, "TOTAL");
                var valorFila = 0;
                if (valorCelda !== null && valorCelda !== undefined && valorCelda !== "") {
                    // 2. Usamos el API nativo de APEX para convertir a número respetando 
                      //comas/puntos decimales
                    valorFila = apex.locale.toNumber(valorCelda);
                }
                // Si es un número válido de JavaScript, lo acumulamos
                if (!isNaN(valorFila)) {
                    sumaTotal += valorFila;
                }
            }
        });
        console.log("4. Suma decimal calculada exitosamente en JS:", sumaTotal);
        // 3. Asignamos el valor al ítem formateándolo con la configuración regional de la app
        // Esto asegura que si tu app usa coma para decimales, se muestre con coma en  
        //P21_TOTAL
        apex.item("P21_TOTAL").setValue(apex.locale.formatNumber(sumaTotal, 
                                                                                 "999G999G999G990D00"));
    };
    // Ejecución inicial inmediata ya que el modelo existe
    calcularGranTotal();
    // Suscripción a cambios futuros (ediciones, insertar filas, borrar filas)
    model.subscribe({
        onChange: function(type, change) {
            console.log("-> Cambio detectado en el modelo. Tipo de evento:", type);
            if (type === "set" || type === "addData" || type === "metaChange") {
                calcularGranTotal();
            }
        }
    });
}
// Lanzamos la función inmediatamente en el Page Load
inicializarSumatoriaIG();
