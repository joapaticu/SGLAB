#!/bin/bash
# Deja funcionando la cadena .toml -> BD -> web. Ejecutar como el usuario joaquin (NO root):
#   bash sh/setup_ingesta.sh
set -u
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
DOCKER="docker"; docker ps >/dev/null 2>&1 || DOCKER="sudo docker"

echo "== 1. Permisos de reportes_para_procesar y carpeta de entrada"
mkdir -p public-WEB/reportes_para_procesar "$HOME/SGLAB/LAB6" "$HOME/reportes_con_error"
sudo chown -R "$USER":"$USER" public-WEB/reportes_para_procesar "$HOME/SGLAB" "$HOME/reportes_con_error"
chmod 777 public-WEB/reportes_para_procesar   # Apache (www-data, otro usuario) debe poder leer y borrar el .toml
chmod +x public-WEB/api/procesar_reportes.sh

echo "== 2. Dependencias (jq, cron)"
command -v jq >/dev/null || sudo apt-get install -y jq
command -v crontab >/dev/null || sudo apt-get install -y cron
sudo service cron start >/dev/null 2>&1 || true

echo "== 3. Usuario MySQL sgapp_admin accesible desde el contenedor web"
ADMIN_PASS="$(grep -E '^DB_PASSWORD_ADMIN=' public-WEB/.env | cut -d= -f2- | tr -d '\r"'"'")"
$DOCKER compose exec -T database sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<SQL
CREATE USER IF NOT EXISTS 'sgapp_admin'@'%' IDENTIFIED BY '${ADMIN_PASS}';
GRANT SELECT, INSERT, UPDATE, DELETE ON bddsglab6.* TO 'sgapp_admin'@'%';
FLUSH PRIVILEGES;
SQL
# Persistir para cuando se recree el volumen
if ! grep -q "sgapp_admin" docker/init-db.sh; then
  sed -i "/FLUSH PRIVILEGES;/i\\    CREATE USER IF NOT EXISTS 'sgapp_admin'@'%' IDENTIFIED BY '${ADMIN_PASS}';\n    GRANT SELECT, INSERT, UPDATE, DELETE ON bddsglab6.* TO 'sgapp_admin'@'%';\n" docker/init-db.sh
fi

echo "== 4. Cron cada minuto (el PDF pide cada hora: cambiar a '0 * * * *' cuando termine la prueba)"
LINEA="* * * * * /bin/bash $REPO/public-WEB/api/procesar_reportes.sh >> $HOME/procesar.log 2>&1"
( crontab -l 2>/dev/null | grep -v procesar_reportes.sh; echo "$LINEA" ) | crontab -

echo "== 5. Corrida de prueba ahora"
bash public-WEB/api/procesar_reportes.sh
echo "Listo. Log de cron: $HOME/procesar.log"
