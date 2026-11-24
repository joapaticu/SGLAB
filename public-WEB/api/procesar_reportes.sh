#!/bin/bash

# --- CONFIGURACIÓN ---
# URL de tu API. Si el script corre en el mismo servidor, usa localhost.
API_URL="http://localhost:8080/api/api_registro.php"
API_KEY="df25493a1b7f80610652420f0b5ae62ab165b8ef6c46e5af" # La misma clave que en el PHP

# Carpeta donde SCP deja los archivos de Windows
INCOMING_DIR="$HOME/SGLAB/LAB6/"
# Carpeta donde la API buscará los archivos (debe coincidir con REPORTS_DIR en el PHP)
PROCESSING_DIR="$(cd "$(dirname "$0")/.." && pwd)/reportes_para_procesar/"
# Carpeta para mover los archivos que fallen
ERROR_DIR="$HOME/reportes_con_error/"
# --- FIN CONFIGURACIÓN ---

# Asegurarse de que los directorios existan
mkdir -p "$INCOMING_DIR"
mkdir -p "$PROCESSING_DIR"
mkdir -p "$ERROR_DIR"

# Verifica si no hay archivos para procesar y sale para no mostrar mensajes vacíos.
if [ -z "$(ls -A $INCOMING_DIR/*.toml 2>/dev/null)" ]; then
    echo "No hay nuevos reportes para procesar."
    exit 0
fi

# Busca archivos .toml en el directorio de entrada
find "$INCOMING_DIR" -maxdepth 1 -type f -name "*.toml" | while read -r filepath
do
    filename=$(basename "$filepath")
    echo "Procesando archivo: $filename"
    
    # 1. Mover el archivo a la carpeta que la API puede leer
    mv "$filepath" "$PROCESSING_DIR$filename"
    chgrp www-data "$PROCESSING_DIR$filename" && chmod 660 "$PROCESSING_DIR$filename"
    
    # 2. Preparar el payload JSON
    JSON_PAYLOAD=$(printf '{"filename": "%s"}' "$filename")
    
    # 3. Llamar a la API con cURL
    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "X-API-KEY: $API_KEY" \
        -d "$JSON_PAYLOAD" \
        "$API_URL")
    
    # Extraer el código HTTP y el cuerpo de la respuesta
    http_code=$(echo "$response" | grep "HTTP_CODE" | awk -F: '{print $2}')
    body=$(echo "$response" | sed '$d')

    # 4. Verificar el resultado y registrar
    if [ "$http_code" -eq 201 ]; then
        echo "  [ÉXITO] El archivo fue procesado correctamente."
        echo "  Respuesta: $(echo $body | jq -r .mensaje)"
    else
        echo "  [ERROR] Falló el procesamiento (Código: $http_code)."
        echo "  Respuesta: $(echo $body | jq -r .mensaje)"
        # Mover el archivo fallido a la carpeta de errores
        mv "$PROCESSING_DIR$filename" "$ERROR_DIR$filename"
    fi
    echo "---------------------------------"
done

echo "Ciclo de procesamiento finalizado."
