<?php
// Endpoints del panel de laboratorios del docente.
// Lo consume Public/js/panel_docente_laboratorios.js con:
//   GET  ?action=obtenerEstadisticas
//   GET  ?action=obtenerLaboratoriosConEquipos
//   POST ?action=actualizarComentario   (JSON: idLaboratorio, comentario)
require_once '../Models/Database.php';
require_once '../Models/LaboratorioDocente.php';

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

header('Content-Type: application/json');

function responder($success, $data = null, $message = '', $codigoHttp = 200) {
    http_response_code($codigoHttp);
    $respuesta = ['success' => $success, 'message' => $message];
    if ($data !== null) {
        $respuesta['data'] = $data;
    }
    echo json_encode($respuesta);
    exit;
}

// Solo docentes (idTipoUsuario = 2) con sesión iniciada
if (!isset($_SESSION['usuario_id']) || ($_SESSION['idTipoUsuario'] ?? null) != 2) {
    responder(false, null, 'No autorizado', 403);
}

try {
    $action = $_GET['action'] ?? '';
    $modelo = new LaboratorioDocente('docente');

    switch ($action) {

        case 'obtenerEstadisticas':
            responder(true, $modelo->obtenerEstadisticas());
            break;

        case 'obtenerLaboratoriosConEquipos':
            responder(true, $modelo->obtenerLaboratoriosConEquipos());
            break;

        case 'actualizarComentario':
            if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
                responder(false, null, 'Método no permitido', 405);
            }

            $entrada = json_decode(file_get_contents('php://input'), true);
            if (!is_array($entrada)) {
                responder(false, null, 'Datos inválidos', 400);
            }

            $idLaboratorio = isset($entrada['idLaboratorio']) ? (int)$entrada['idLaboratorio'] : 0;
            $comentario = trim($entrada['comentario'] ?? '');

            if ($idLaboratorio <= 0) {
                responder(false, null, 'Laboratorio no indicado', 400);
            }
            if (mb_strlen($comentario) > 255) {
                responder(false, null, 'El comentario no puede superar los 255 caracteres', 400);
            }
            if (!$modelo->obtenerLaboratorioPorId($idLaboratorio)) {
                responder(false, null, 'Laboratorio no encontrado', 404);
            }

            $modelo->actualizarComentario($idLaboratorio, $comentario);
            responder(true, null, 'Comentario actualizado');
            break;

        default:
            responder(false, null, 'Acción no válida', 400);
    }

} catch (Exception $e) {
    error_log('DocenteController: ' . $e->getMessage());
    responder(false, null, 'Error en el servidor', 500);
}
