<?php
header('Content-Type: application/json');
date_default_timezone_set('America/Montevideo'); // la fecha del .toml es hora local del PC
require_once '../Models/Database.php';
require_once '../Models/Registro.php';

// --- CONFIGURACIÓN ---
define('API_SECRET_KEY', 'df25493a1b7f80610652420f0b5ae62ab165b8ef6c46e5af'); // debe ser igual a API_KEY en procesar_reportes.sh
define('LAB_NOMBRE_DEFECTO', 'Laboratorio 6'); // laboratorio donde se dan de alta los equipos nuevos
define('REPORTS_DIR', __DIR__ . '/../reportes_para_procesar/');

function enviarRespuesta($statusCode, $mensaje, $datos = null) {
    http_response_code($statusCode);
    $respuesta = ['mensaje' => $mensaje];
    if ($datos) { $respuesta['datos'] = $datos; }
    echo json_encode($respuesta);
    exit;
}

// Parser mínimo de TOML (secciones [x] y pares clave = "texto" | número)
function parseToml($texto) {
    $datos = [];
    $seccion = '';
    foreach (preg_split('/\r?\n/', $texto) as $linea) {
        $linea = trim($linea);
        if ($linea === '' || $linea[0] === '#') continue;
        if (preg_match('/^\[([^\]]+)\]$/', $linea, $m)) { $seccion = $m[1]; continue; }
        if (preg_match('/^([A-Za-z0-9_]+)\s*=\s*(.*)$/', $linea, $m)) {
            $valor = trim($m[2]);
            if (strlen($valor) >= 2 && $valor[0] === '"' && substr($valor, -1) === '"') {
                $valor = substr($valor, 1, -1);
                $valor = strtr($valor, ['\\\\' => '\\', '\\"' => '"', '\\n' => "\n"]);
            }
            $datos[$seccion][$m[1]] = $valor;
        }
    }
    return $datos;
}

// 1. Seguridad y método
$apiKey = $_SERVER['HTTP_X_API_KEY'] ?? '';
if ($apiKey !== API_SECRET_KEY) { enviarRespuesta(401, 'Acceso no autorizado.'); }
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { enviarRespuesta(405, 'Método no permitido.'); }

// 2. Nombre de archivo
$data = json_decode(file_get_contents("php://input"), true);
if (empty($data['filename'])) {
    enviarRespuesta(400, 'Petición incorrecta. Falta el campo "filename".');
}
$filename = basename($data['filename']);
$reportPath = REPORTS_DIR . $filename;
if (!file_exists($reportPath)) {
    enviarRespuesta(404, 'El archivo de reporte no se encuentra.', ['archivo' => $filename]);
}

// 3. Leer y parsear el TOML
$toml = parseToml(file_get_contents($reportPath));
$serial   = trim($toml['info_general']['serial'] ?? '');
$hostname = trim($toml['info_general']['nombre_pc'] ?? '');
if ($serial === '' && $hostname === '') {
    enviarRespuesta(400, 'El reporte no trae serial ni nombre_pc.', ['recibido' => $filename]);
}

// 4. Buscar el equipo: por serial (solo si es numérico, la columna es INT) o por hostname
try {
    $db = Database::getConnection('admin');
} catch (Throwable $e) {
    error_log("api_registro.php: sin conexion BD admin: " . $e->getMessage());
    enviarRespuesta(500, 'No se pudo conectar a la base de datos (usuario admin).');
}
$equipo = null;
if ($serial !== '' && ctype_digit($serial)) {
    $st = $db->prepare("SELECT idEquipo FROM Equipos WHERE serialNumber = :s LIMIT 1");
    $st->execute([':s' => (int)$serial]);
    $equipo = $st->fetch(PDO::FETCH_ASSOC);
}
if (!$equipo && $hostname !== '') {
    $st = $db->prepare("SELECT idEquipo FROM Equipos WHERE hostname = :h LIMIT 1");
    $st->execute([':h' => $hostname]);
    $equipo = $st->fetch(PDO::FETCH_ASSOC);
}
if (!$equipo) {
    // Alta automatica: el equipo no existe, se crea con los datos del .toml
    // y se lo asigna al laboratorio LAB_NOMBRE_DEFECTO (se crea si no existe).
    try {
        $st = $db->prepare("SELECT idLaboratorio FROM Laboratorios WHERE nombre = :n LIMIT 1");
        $st->execute([':n' => LAB_NOMBRE_DEFECTO]);
        $idLab = $st->fetchColumn();
        if (!$idLab) {
            $st = $db->prepare("INSERT INTO Laboratorios (nombre, comentario) VALUES (:n, 'Creado automaticamente por api_registro')");
            $st->execute([':n' => LAB_NOMBRE_DEFECTO]);
            $idLab = $db->lastInsertId();
        }
        $serialInt = ($serial !== '' && ctype_digit($serial) && strlen($serial) <= 8) ? (int)$serial : null;
        $st = $db->prepare("INSERT INTO Equipos (serialNumber, hostname, CPU, RAM, diskType, diskTotal, idLaboratorio)
                            VALUES (:s, :h, :c, :r, 'N/D', :d, :l)");
        $st->execute([
            ':s' => $serialInt,
            ':h' => $hostname !== '' ? $hostname : $serial,
            ':c' => substr($toml['hardware']['cpu'] ?? 'N/D', 0, 100),
            ':r' => (int)round((float)($toml['hardware']['ram_gb'] ?? 0)),
            ':d' => (int)round((float)($toml['hardware']['disco_c_gb'] ?? 0)),
            ':l' => $idLab,
        ]);
        $equipo = ['idEquipo' => $db->lastInsertId()];
    } catch (Throwable $e) {
        error_log("api_registro.php: no se pudo dar de alta el equipo: " . $e->getMessage());
        enviarRespuesta(500, 'No se pudo dar de alta el equipo: ' . $e->getMessage());
    }
}

// 5. Armar el registro
$ip = $toml['red']['ip'] ?? null;
$discoTotal = (float)($toml['hardware']['disco_c_gb'] ?? 0);
$discoUso   = (float)($toml['recursos_disponibles']['disco_c_uso_porcentaje'] ?? 0);
$diskFree   = (int)round($discoTotal * (1 - $discoUso / 100));

$fechaTxt = preg_replace('/[()]/', '', $toml['info_general']['fecha'] ?? ''); // "2025/08/07 (09:31)"
$fecha = strtotime($fechaTxt) ?: time();
$estado = (($toml['info_general']['estado_conexion'] ?? '') === 'Exito') ? 1 : 0;

$descripcion = "Reporte automático. " .
    "PC: " . $hostname . " | " .
    "Usuario: " . ($toml['ssh']['usuario'] ?? '') . " | " .
    "OS: " . ($toml['sistema_operativo']['nombre'] ?? '') . " | " .
    "CPU: " . ($toml['hardware']['cpu'] ?? '') . " | " .
    "Uso RAM: " . ($toml['recursos_disponibles']['ram_uso_porcentaje'] ?? '') . "% | " .
    "Uso Disco: " . $discoUso . "%";

try {
    $registro = new Registro([
        'idEquipo'    => $equipo['idEquipo'],
        'idUsuario'   => 1, // usuario del sistema
        'fecha'       => $fecha,
        'estado'      => $estado,
        'IP'          => $ip,
        'diskFree'    => $diskFree,
        'descripcion' => substr($descripcion, 0, 255)
    ]);
    if ($registro->guardar()) {
        unlink($reportPath);
        enviarRespuesta(201, 'Registro creado exitosamente y reporte procesado.');
    }
    enviarRespuesta(500, 'Error al guardar el registro en la base de datos.');
} catch (Exception $e) {
    error_log("Error en api_registro.php: " . $e->getMessage());
    enviarRespuesta(500, 'Ocurrió un error interno en el servidor.');
}
?>
