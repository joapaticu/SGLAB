<?php
require_once '../Models/Database.php';
require_once '../Models/Usuario.php';
require_once '../Models/TipoUsuario.php';
require_once '../Models/Auth.php';
require_once '../vendor/autoload.php'; 

use OTPHP\TOTP;
use ParagonIE\ConstantTime\Base32;

// Iniciar sesión
if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    exit(0);
}

function sendJsonResponse($success, $message, $data = []) {
    $response = array_merge([
        'success' => $success,
        'message' => $message
    ], $data);
    echo json_encode($response);
    exit;
}

try {
    $action = isset($_POST['action']) ? $_POST['action'] : '';
    
    error_log("=====================================");
    error_log("Action recibida: " . $action);
    error_log("POST data: " . print_r($_POST, true));
    error_log("=====================================");

    switch ($action) {
        case 'login':
            handleLogin();
            break;
        
        case 'verify_2fa':
            handleVerify2FA();
            break;
        
        case 'setup_2fa':
            handleSetup2FA();
            break;
        
        default:
            sendJsonResponse(false, 'Acción no válida');
    }

} catch (Exception $e) {
    error_log('❌ ERROR CRÍTICO en loginController: ' . $e->getMessage());
    error_log('Stack trace: ' . $e->getTraceAsString());
    sendJsonResponse(false, 'Error en el servidor: ' . $e->getMessage());
}

// ==================== FUNCIONES ====================

function handleLogin() {
    error_log("🔐 === INICIO handleLogin ===");
    
    $username = isset($_POST['username']) ? trim($_POST['username']) : '';
    $password = isset($_POST['password']) ? trim($_POST['password']) : '';
    
    if (empty($username) || empty($password)) {
        sendJsonResponse(false, 'Usuario y contraseña son requeridos');
    }

    error_log("Usuario intentando login: $username");

    // Intentar login
    $usuario = Auth::loginByUsername($username, $password);
    
    if (!$usuario) {
        error_log("❌ Credenciales incorrectas para: $username");
        Auth::registrarIntentoFallido($username);
        sendJsonResponse(false, 'Usuario o contraseña incorrectos');
    }

    error_log("✅ Credenciales correctas - Usuario ID: " . $usuario->getId());

    // Verificar si está bloqueado
    if (Auth::estaBloqueado($usuario->getId())) {
        error_log("🔒 Usuario bloqueado: " . $usuario->getId());
        sendJsonResponse(false, 'Cuenta bloqueada temporalmente. Intente más tarde.');
    }

    $idTipoUsuario = $usuario->getIdTipoUsuario();
    error_log("Tipo de usuario: $idTipoUsuario");
    
    // idTipoUsuario = 1: Administrador (requiere 2FA)
    if ($idTipoUsuario == 1) {
        error_log("👑 Usuario es ADMINISTRADOR - verificando 2FA");
        
        // Verificar si tiene 2FA configurado
        $secret2FA = Auth::getSecret2FA($usuario->getId());

        error_log("Secret 2FA en BD: " . ($secret2FA ? "✅ EXISTE" : "❌ NO EXISTE (primera vez)"));
        error_log("Secret length: " . ($secret2FA ? strlen($secret2FA) : 0));
        
        if (empty($secret2FA)) {
            // Primera vez - generar secreto para 2FA
            error_log("📱 Primera vez - Generando QR para configurar 2FA");
            
            $totp = TOTP::create();
            $secret = $totp->getSecret();
            
            error_log("Secret generado: $secret");
    
            Auth::guardarSecret2FATemp($usuario->getId(), $secret);
            
            $totp->setLabel($usuario->getUsername()); 
            $totp->setIssuer('SGLab');       
            $qrCode = $totp->getProvisioningUri();
            
            error_log("QR URI generado");
            error_log("→ Respondiendo con needs_setup=true");
            
            sendJsonResponse(true, 'Configure su autenticación en dos pasos', [
                'requires_2fa' => true,
                'needs_setup' => true,
                'user_id' => $usuario->getId(),
                'qr_code' => $qrCode,
                'secret' => $secret
            ]);
        } else {
            // Ya tiene 2FA configurado
            error_log("✅ Usuario ya tiene 2FA configurado");
            error_log("→ Respondiendo con needs_setup=false");
            
            sendJsonResponse(true, 'Ingrese el código de autenticación', [
                'requires_2fa' => true,
                'needs_setup' => false,
                'user_id' => $usuario->getId()
            ]);
        }
    } 
    // idTipoUsuario = 2: Docente (login directo)
    else if ($idTipoUsuario == 2) {
        error_log("👨‍🏫 Usuario es DOCENTE - login directo");
        
        crearSesion($usuario);
        Auth::registrarLoginExitoso($usuario->getId());
        
        sendJsonResponse(true, 'Login exitoso', [
            'requires_2fa' => false,
            'redirect' => '../views/menu_docente.php'
        ]);
    }
    // idTipoUsuario = 3: Estudiante (no debería llegar aquí, usa GitHub)
    else {
        error_log("👨‍🎓 Usuario es ESTUDIANTE - debe usar GitHub");
        sendJsonResponse(false, 'Los estudiantes deben iniciar sesión con GitHub');
    }
}

function handleVerify2FA() {
    error_log("🔑 === INICIO handleVerify2FA ===");
    
    $userId = isset($_POST['user_id']) ? intval($_POST['user_id']) : 0;
    $code = isset($_POST['code']) ? trim($_POST['code']) : '';
    
    error_log("Usuario ID: $userId - Código recibido: $code");
    
    if (empty($userId) || empty($code)) {
        sendJsonResponse(false, 'Datos incompletos');
    }

    // Obtener el secreto 2FA del usuario
    $secret = Auth::getSecret2FA($userId);
    
    if (empty($secret)) {
        error_log("❌ No se encontró secret 2FA para usuario: $userId");
        sendJsonResponse(false, 'No se encontró configuración 2FA');
    }

    error_log("Secret recuperado de BD para verificación");

    // Verificar el código TOTP
    $totp = TOTP::create($secret);
    $isValid = $totp->verify($code);
    
    error_log("Verificación TOTP: " . ($isValid ? "✅ VÁLIDO" : "❌ INVÁLIDO"));
    
    if ($isValid) {
        error_log("✅ Código 2FA correcto - creando sesión");
        
        // Código correcto - crear sesión
        $usuario = Auth::getUsuarioById($userId);
        
        if ($usuario) {
            crearSesion($usuario);
            Auth::registrarLoginExitoso($userId, '2FA exitoso');
            
            error_log("✅ Sesión creada exitosamente");
            
            sendJsonResponse(true, 'Verificación exitosa', [
                'redirect' => '../views/menu_admin.php'
            ]);
        } else {
            error_log("❌ Error: No se pudo obtener información del usuario");
            sendJsonResponse(false, 'Error al obtener información del usuario');
        }
    } else {
        error_log("❌ Código 2FA incorrecto");
        Auth::registrarIntentoFallido2FA($userId);
        sendJsonResponse(false, 'Código incorrecto. Verifique e intente nuevamente.');
    }
}

function handleSetup2FA() {
    error_log("⚙️ === INICIO handleSetup2FA (CONFIGURACIÓN PRIMERA VEZ) ===");
    
    $userId = isset($_POST['user_id']) ? intval($_POST['user_id']) : 0;
    $code = isset($_POST['code']) ? trim($_POST['code']) : '';
    
    error_log("Usuario ID: $userId");
    error_log("Código recibido: $code");
    
    if (empty($userId) || empty($code)) {
        error_log("❌ Datos incompletos");
        sendJsonResponse(false, 'Datos incompletos');
    }

    // Obtener el secreto temporal
    $secret = Auth::getSecret2FATemp($userId);
    
    if (empty($secret)) {
        error_log("❌ No se encontró secret temporal para usuario: $userId");
        sendJsonResponse(false, 'No se encontró configuración temporal');
    }

    error_log("✅ Secret temporal recuperado");

    // Verificar el código
    $totp = TOTP::create($secret);
    $isValid = $totp->verify($code);
    
    error_log("Verificación código setup: " . ($isValid ? "✅ VÁLIDO" : "❌ INVÁLIDO"));
    
    if ($isValid) {
        error_log("✅ Código correcto - Guardando secret permanentemente en BD");
        
        // Código correcto - confirmar y guardar permanentemente
        $guardado = Auth::confirmarSecret2FA($userId, $secret);
        
        if (!$guardado) {
            error_log("❌ ERROR CRÍTICO: No se pudo guardar el secret en BD");
            sendJsonResponse(false, 'Error al guardar la configuración');
        }
        
        error_log("✅ Secret guardado correctamente en BD");
        
        // Verificar que se guardó
        $verificar = Auth::getSecret2FA($userId);
        error_log("Verificación post-guardado: " . ($verificar ? "✅ EXISTE" : "❌ NO EXISTE"));
        
        $usuario = Auth::getUsuarioById($userId);
        
        if ($usuario) {
            crearSesion($usuario);
            Auth::registrarLoginExitoso($userId, '2FA configurado y activado');
            
            error_log("✅ Setup 2FA completado exitosamente");
            
            sendJsonResponse(true, 'Autenticación configurada exitosamente', [
                'redirect' => '../views/menu_admin.php'
            ]);
        } else {
            error_log("❌ Error al obtener información del usuario");
            sendJsonResponse(false, 'Error al obtener información del usuario');
        }
    } else {
        error_log("❌ Código incorrecto en setup");
        sendJsonResponse(false, 'Código incorrecto. Verifique e intente nuevamente.');
    }
}

function crearSesion($usuario) {
    $_SESSION['usuario'] = [
        'id' => $usuario->getId(),
        'ci' => $usuario->getCi(),
        'nombre' => $usuario->getNombre(),
        'email' => $usuario->getEmail(),
        'username' => $usuario->getUsername(),
        'idTipoUsuario' => $usuario->getIdTipoUsuario(),
        'roles' => $usuario->getRoles()
    ];
    $_SESSION['usuario_id'] = $usuario->getId();
    $_SESSION['idTipoUsuario'] = $usuario->getIdTipoUsuario();
    
    // Guardar sesión en BD
    Auth::guardarSesion($usuario->getId(), session_id());
    
    error_log("✅ Sesión creada para usuario: " . $usuario->getNombre() . " (ID: " . $usuario->getId() . ")");
}
?>
