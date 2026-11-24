<?php
// Cierra la sesión del usuario y lo manda a la pantalla de login.
// Lo llaman los botones "Salir" de todos los menús (enlace GET).
require_once '../Models/Database.php';
require_once '../Models/Auth.php';

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

$sessionId = session_id();
$usuarioId = $_SESSION['usuario_id'] ?? null;

// 1. Borrar la sesión registrada en la base de datos (tabla sesiones)
if ($usuarioId) {
    Auth::cerrarSesion($sessionId);
    error_log("Logout: sesión cerrada para usuario ID " . $usuarioId);
}

// 2. Vaciar los datos de sesión en PHP
$_SESSION = [];

// 3. Borrar la cookie de sesión del navegador
if (ini_get('session.use_cookies')) {
    $p = session_get_cookie_params();
    setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
}

// 4. Destruir la sesión
session_destroy();

// 5. Volver al login
header('Location: ../views/login_usuario.html');
exit();
