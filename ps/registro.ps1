# Script PowerShell: Diagnóstico del PC y exportación en formato TOML con clave SSH
param(
    [int]$cedula = 0,
    # Dirección (IP o nombre) del servidor SGLAB. Si se omite, se busca sola en cada ejecución
    # (último servidor, sglab.lab, WSL de esta PC y las redes de la PC).
    [string]$servidor = ""
)

$usuario     = "joaquin"
$laboratorio = "LAB6"
$destino     = "/home/" + $usuario + "/SGLAB/" + $laboratorio
$sshDir      = Join-Path $env:USERPROFILE ".ssh"
$clavePrivada = Join-Path $sshDir "id_rsa"
# Clave compartida del laboratorio: si existe la carpeta "clave" junto al script, se usa esa
# (así ninguna PC necesita autorizarse en el servidor). Si no, se usa/genera la clave propia.
$claveLab = Join-Path $PSScriptRoot "clave\sglab_lab"
if ((Test-Path $claveLab) -and (Test-Path "$claveLab.pub")) { $clavePrivada = $claveLab }

# ---------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------

# Escapa un texto para usarlo como string básico de TOML (entre comillas dobles).
# Necesario porque las rutas de Windows tienen "\" que en TOML son escapes.
function TomlStr {
    param([object]$valor)
    $s = if ($null -eq $valor) { "" } else { [string]$valor }
    $s = $s.Replace('\', '\\').Replace('"', '\"')
    $s = $s -replace "`r?`n", '\n'
    return '"' + $s + '"'
}

# Obtiene el número de serie del equipo (NS), descartando valores genéricos de fabricantes.
function Get-NumeroSerie {
    $invalidos = '^(|0+|none|default string|to be filled by o\.e\.m\.?|system serial number|not specified|not applicable|n/a|unknown|chassis serial number|base board serial number|123456789.*)$'
    $candidatos = @()
    try { $candidatos += (Get-CimInstance Win32_BIOS).SerialNumber } catch {}
    try { $candidatos += (Get-CimInstance Win32_BaseBoard).SerialNumber } catch {}
    try { $candidatos += (Get-CimInstance Win32_ComputerSystemProduct).IdentifyingNumber } catch {}
    try { $candidatos += (Get-CimInstance Win32_SystemEnclosure).SerialNumber } catch {}

    foreach ($c in $candidatos) {
        if ($null -eq $c) { continue }
        $t = ([string]$c).Trim()
        if ($t -notmatch $invalidos) {
            # Quitar caracteres no válidos para nombre de archivo
            return ($t -replace '[\\/:*?"<>|\s]', '_')
        }
    }
    return "SinSerial"
}

# Valida cédula uruguaya: cuerpo de 6 o 7 dígitos + 1 dígito verificador
# (7 u 8 dígitos en total). Acepta puntos y guión: 1.234.567-2
function Test-CedulaUruguaya {
    param([string]$cedula)

    $limpia = $cedula -replace '[\.\-\s]', ''
    if ($limpia -notmatch '^\d{7,8}$') { return $false }

    $cuerpo = $limpia.Substring(0, $limpia.Length - 1).PadLeft(7, '0')
    $dvIngresado = [int]::Parse($limpia.Substring($limpia.Length - 1, 1))

    $coeficientes = @(2, 9, 8, 7, 6, 3, 4)
    $suma = 0
    for ($i = 0; $i -lt 7; $i++) {
        $suma += [int]::Parse($cuerpo[$i].ToString()) * $coeficientes[$i]
    }
    $dvCalculado = (10 - ($suma % 10)) % 10

    return ($dvIngresado -eq $dvCalculado)
}

# Genera la clave SSH si no existe y devuelve SOLO la clave pública.
# (Se usa Write-Host para los mensajes: Write-Output se mezclaría con el valor devuelto)
function New-SSHKey {
    $publicKeyPath = "$clavePrivada.pub"

    if (!(Test-Path $sshDir)) {
        try {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
            Write-Host "Directorio .ssh creado"
        }
        catch {
            Write-Host "Error al crear directorio .ssh: $($_.Exception.Message)"
            return "ERROR: No se pudo crear el directorio .ssh"
        }
    }

    if (Test-Path $publicKeyPath) {
        try {
            return (Get-Content $publicKeyPath -Raw).Trim()
        }
        catch {
            Write-Host "Error al leer la clave existente: $($_.Exception.Message)"
            return "ERROR: No se pudo leer la clave SSH existente"
        }
    }

    Write-Host "Generando nueva clave SSH..."
    Write-Host "Directorio .ssh = $sshDir"
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Host "ssh-keygen no está disponible en el sistema"
        return "ERROR: ssh-keygen no disponible. Instale OpenSSH Client."
    }

    try {
        # Start-Process con un único string asegura que -N "" (sin passphrase)
        # llegue vacío tanto en PowerShell 5.1 como en 7.x
        $argumentos = "-t rsa -b 2048 -q -f `"$clavePrivada`" -N `"`" -C `"$env:USERNAME@$env:COMPUTERNAME`""
        Start-Process -FilePath "ssh-keygen" -ArgumentList $argumentos -Wait -NoNewWindow
        if (Test-Path $publicKeyPath) {
            Write-Host "Clave SSH generada exitosamente"
            return (Get-Content $publicKeyPath -Raw).Trim()
        }
        Write-Host "Error al generar la clave SSH"
        return "ERROR: No se pudo generar la clave SSH"
    }
    catch {
        Write-Host "Error ejecutando ssh-keygen: $_"
        return "ERROR: ssh-keygen falló - $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------
# Datos básicos
# ---------------------------------------------------------------
$fecha        = Get-Date -Format "yyyyMMdd"
$fechaLegible = Get-Date -Format "yyyy/MM/dd (HH:mm)"
$nombrePC     = $env:COMPUTERNAME
$serial       = Get-NumeroSerie

Write-Output "========== GESTION DE CLAVES SSH =========="
$clavePublica = New-SSHKey
Write-Output "=========================================="

# ---------------------------------------------------------------
# Conectividad (ping al gateway)
# ---------------------------------------------------------------
Write-Output "Verificando conectividad..."
$rutaDefault = $null
$gateway = "No disponible"
try {
    $rutaDefault = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    $gateway = $rutaDefault.NextHop
    if (Test-Connection -ComputerName $gateway -Count 1 -Quiet) { $estado = "Exito" } else { $estado = "Fallo" }
}
catch {
    $estado = "Error"
}

# ---------------------------------------------------------------
# Información del sistema
# ---------------------------------------------------------------
Write-Output "Recopilando información del sistema..."
try {
    $so = Get-CimInstance Win32_OperatingSystem

    # IP de la interfaz que tiene la ruta por defecto (evita tomar adaptadores virtuales)
    $ipInfo = $null
    if ($rutaDefault) {
        $ipInfo = Get-NetIPAddress -InterfaceIndex $rutaDefault.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $ipInfo) {
        $ipInfo = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.PrefixOrigin -eq "Dhcp" -or $_.PrefixOrigin -eq "Manual" } | Select-Object -First 1
    }

    $cpuObjs = @(Get-CimInstance Win32_Processor)
    $cpuNombre = ($cpuObjs | Select-Object -First 1).Name.Trim()
    $cpuProm = ($cpuObjs | Measure-Object -Property LoadPercentage -Average).Average
    $cpuUso = if ($null -eq $cpuProm) { 0 } else { [math]::Round($cpuProm, 0) }

    $ram = [math]::Round($so.TotalVisibleMemorySize / 1024 / 1024, 2)
    $ramUsoPorc = [math]::Round((($so.TotalVisibleMemorySize - $so.FreePhysicalMemory) / $so.TotalVisibleMemorySize) * 100, 1)

    $disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $discoTotal = [math]::Round($disco.Size / 1GB, 2)
    $discoUso = [math]::Round((($disco.Size - $disco.FreeSpace) / $disco.Size) * 100, 1)
}
catch {
    Write-Output "Error al recopilar información del sistema: $($_.Exception.Message)"
    exit 1
}

# ---------------------------------------------------------------
# Cédula del responsable
# ---------------------------------------------------------------
if ($cedula -eq 0) {
    Write-Output "Ejecutando en modo desatendido con cedula = 0"
} else {
    # Si se pasó un parámetro distinto de 0, se solicita la cédula por consola
    do {
        $inputCedula = Read-Host "Ingrese su cedula (7 u 8 digitos incluyendo el verificador, ej: 1234567-2)"
        $cedulaValida = Test-CedulaUruguaya $inputCedula
        if (-not $cedulaValida) {
            Write-Output "Cédula inválida. Debe tener 7 u 8 dígitos (con dígito verificador correcto)."
        } else {
            $cedula = [int](($inputCedula -replace '[\.\-\s]', ''))
        }
    } until ($cedulaValida)
}

# ---------------------------------------------------------------
# Archivo TOML
# ---------------------------------------------------------------
$escritorio = [Environment]::GetFolderPath("Desktop")
# Si corre como SYSTEM (tarea programada) el escritorio puede no existir: se usa una carpeta propia.
if (-not $escritorio -or -not (Test-Path $escritorio)) {
    $escritorio = Join-Path $env:ProgramData "SGLAB"
    New-Item -ItemType Directory -Path $escritorio -Force | Out-Null
}
# Nombre del archivo: AAAAMMDD-SERIE-ESTADO.toml (formato que espera api_registro.php).
# El serial no puede contener "-" (la API separa el nombre por guiones) y el estado se
# informa como true/false; el detalle (Exito/Fallo/Error) queda dentro del archivo.
$serialArchivo = $serial -replace '-', '_'
$estadoArchivo = if ($estado -eq "Exito") { "true" } else { "false" }
$archivo = Join-Path $escritorio "$fecha-$serialArchivo-$estadoArchivo.toml"

$contenido = @"
[info_general]
serial = $(TomlStr $serial)
fecha = $(TomlStr $fechaLegible)
nombre_pc = $(TomlStr $nombrePC)
estado_conexion = $(TomlStr $estado)

[sistema_operativo]
nombre = $(TomlStr $so.Caption)
version = $(TomlStr $so.Version)

[red]
ip = $(TomlStr $ipInfo.IPAddress)
mascara = $(TomlStr $ipInfo.PrefixLength)
default_gateway = $(TomlStr $gateway)

[hardware]
cpu = $(TomlStr $cpuNombre)
ram_gb = $ram
disco_c_gb = $discoTotal

[ssh]
clave_publica = $(TomlStr $clavePublica)
usuario = $(TomlStr $env:USERNAME)
ruta_clave = $(TomlStr "$clavePrivada.pub")

[usuario_responsable]
cedula = $(TomlStr $cedula)

[recursos_disponibles]
cpu_uso_porcentaje = $cpuUso
ram_uso_porcentaje = $ramUsoPorc
disco_c_uso_porcentaje = $discoUso

"@

try {
    # UTF-8 sin BOM (Out-File -Encoding utf8 en PS 5.1 agrega BOM y algunos parsers TOML fallan)
    [System.IO.File]::WriteAllText($archivo, $contenido, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "Archivo TOML guardado: $archivo"
}
catch {
    Write-Output "Error al guardar archivo: $($_.Exception.Message)"
    Write-Output "========== SCRIPT con ERROR=========="
    exit 1
}

Write-Output ""
# ---------------------------------------------------------------
# Localizar el servidor SGLAB
# ---------------------------------------------------------------
# Se repite en cada ejecución, porque la red puede haber cambiado desde la anterior.
# Un candidato solo se acepta si responde $idServidor en http://IP:8080/sglab.txt
# Y tiene abierto el puerto 22. Orden en que se prueban:
#   1) -servidor (si se indicó)       2) el último servidor que funcionó
#   3) el nombre sglab.lab (DNS)      4) la IP de WSL, si el servidor es esta misma PC
#   5) búsqueda en cada red de la PC (máscara real, como mucho /22)
#   6) esta misma PC (localhost y sus IP), por si el servidor usa reenvío de puertos
# $idServidor debe coincidir con public-WEB/sglab.txt y $puertoWeb con docker-compose.yaml (8080:80).
$idServidor      = "SGLAB-jle"
# sglab.lab: nombre que publica el DNS del MikroTik.
$nombresServidor = @("sglab.lab")
$puertoWeb       = 8080
$puertoSsh       = 22
$archivoUltimo   = Join-Path $escritorio "sglab_ultimo_servidor.txt"

function Test-Puerto {
    param([string]$ip, [int]$puerto, [int]$ms = 1500)
    $c = New-Object Net.Sockets.TcpClient
    try { $t = $c.ConnectAsync($ip, $puerto); if ($t.Wait($ms)) { return $c.Connected } else { return $false } }
    catch { return $false }
    finally { $c.Close() }
}

function Test-ServidorSGLAB {
    param([string]$ip)
    if (-not $ip) { return $false }
    if (-not (Test-Puerto $ip $puertoWeb)) { return $false }
    try {
        $r = Invoke-WebRequest "http://${ip}:${puertoWeb}/sglab.txt" -UseBasicParsing -TimeoutSec 3
        if (([string]$r.Content).Trim() -ne $idServidor) { return $false }
    } catch { return $false }
    return (Test-Puerto $ip $puertoSsh)
}

# Recorre la red de una IP (máscara real, pero como mucho /22 = 1022 direcciones)
function Find-ServidorEnRed {
    param([string]$ipLocal, [int]$prefijoLocal)
    $prefijo = [Math]::Max($prefijoLocal, 22)
    if ($prefijo -ge 31) { return $null }
    $bytes = ([Net.IPAddress]$ipLocal).GetAddressBytes(); [Array]::Reverse($bytes)
    $numero = [BitConverter]::ToUInt32($bytes, 0)
    $tamano = [uint32][Math]::Pow(2, 32 - $prefijo)
    $red    = [uint32]([Math]::Floor($numero / $tamano) * $tamano)
    $rb = [BitConverter]::GetBytes($red); [Array]::Reverse($rb)
    Write-Output "Buscando el servidor $idServidor en $((New-Object Net.IPAddress (,[byte[]]$rb)).ToString())/$prefijo..." | Out-Host
    $intentos = foreach ($n in 1..($tamano - 2)) {
        $b = [BitConverter]::GetBytes([uint32]($red + $n)); [Array]::Reverse($b)
        $ip = (New-Object Net.IPAddress (,[byte[]]$b)).ToString()
        $cliente = New-Object Net.Sockets.TcpClient
        [pscustomobject]@{ Ip = $ip; Cliente = $cliente; Tarea = $cliente.ConnectAsync($ip, $puertoWeb) }
    }
    Start-Sleep 2
    $abiertos = @($intentos | Where-Object { $_.Tarea.Status -eq 'RanToCompletion' } | ForEach-Object { $_.Ip })
    $intentos | ForEach-Object { $_.Cliente.Close() }
    foreach ($ip in $abiertos) { if (Test-ServidorSGLAB $ip) { return $ip } }
    return $null
}

function Find-Servidor {
    param([switch]$SinCache)
    # 2) último servidor que funcionó
    if (-not $SinCache -and (Test-Path $archivoUltimo)) {
        $ip = (Get-Content $archivoUltimo -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($ip) { $ip = $ip.Trim() }
        if (Test-ServidorSGLAB $ip) { return $ip }
    }
    # 3) nombre publicado por el DNS del router
    foreach ($nombre in $nombresServidor) {
        try {
            foreach ($a in [Net.Dns]::GetHostAddresses($nombre)) {
                if ($a.AddressFamily -eq 'InterNetwork' -and (Test-ServidorSGLAB $a.ToString())) { return $a.ToString() }
            }
        } catch {}
    }
    # 4) WSL en esta misma PC (no funciona como SYSTEM: WSL es de cada usuario)
    if ($env:USERNAME -notlike '*$' -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        try {
            $salidaWsl = (& wsl.exe -e hostname -I 2>$null) -join ' '
            foreach ($ip in [regex]::Matches($salidaWsl, '\b\d{1,3}(\.\d{1,3}){3}\b') | ForEach-Object { $_.Value }) {
                if (Test-ServidorSGLAB $ip) { return $ip }
            }
        } catch {}
    }
    # 5) búsqueda en cada red de la PC (Wi-Fi, cable, etc.)
    $propias = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })
    $vistas = @{}
    foreach ($p in $propias) {
        $clave = "$($p.IPAddress)/$($p.PrefixLength)"
        if ($vistas.ContainsKey($clave)) { continue }; $vistas[$clave] = $true
        $ip = Find-ServidorEnRed $p.IPAddress ([int]$p.PrefixLength)
        if ($ip) { return $ip }
    }
    # 6) esta misma PC
    foreach ($ip in @('127.0.0.1') + @($propias | ForEach-Object { $_.IPAddress })) {
        if (Test-ServidorSGLAB $ip) { return $ip }
    }
    return $null
}

$servidorFijo = [bool]$servidor
if (-not $servidor) { $servidor = Find-Servidor }
if (-not $servidor) {
    Write-Output "No se encontro el servidor $idServidor en ninguna red de esta PC."
    Write-Output "El reporte queda guardado y se enviara en la proxima ejecucion: $archivo"
    exit 1
}

Write-Output "========== DIAGNOSTICO COMPLETADO =========="
Write-Output "Archivo generado: $archivo"
Write-Output "Usuario: $usuario"
Write-Output "Servidor SSH: $servidor"
Write-Output "Directorio destino: $destino"
Write-Output ""
Write-Output "========== CLAVE SSH PUBLICA =========="
Write-Output $clavePublica
Write-Output "======================================"

# ---------------------------------------------------------------
# Envío por SCP (este reporte y los que quedaron sin enviar)
# ---------------------------------------------------------------
# HostKeyAlias: la huella del servidor se guarda con un nombre fijo y no con su IP,
# así un cambio de IP no rompe la conexión.
$opcionesSsh = @("-i", $clavePrivada,
    "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=8", "-o", "HostKeyAlias=sglab-servidor",
    "-o", "UserKnownHostsFile=$(Join-Path $PSScriptRoot 'known_hosts')")
$carpetaEnviados = Join-Path $escritorio "sglab_enviados"

function Send-Reportes {
    param([string]$srv)
    $r = & ssh @opcionesSsh "${usuario}@${srv}" "mkdir -p '${destino}' && echo LISTO" 2>&1
    if ($LASTEXITCODE -ne 0 -or ($r -join ' ') -notmatch 'LISTO') {
        Write-Output "No se pudo entrar por SSH a ${srv}: $($r -join ' ')" | Out-Host
        return $false
    }
    $pendientes = @(Get-ChildItem $escritorio -Filter *.toml -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-.+-(true|false)\.toml$' } | Sort-Object LastWriteTime | Select-Object -Last 48)
    New-Item -ItemType Directory -Path $carpetaEnviados -Force | Out-Null
    foreach ($f in $pendientes) {
        Write-Output "Subiendo $($f.Name) a ${usuario}@${srv}:${destino}/" | Out-Host
        & scp @opcionesSsh "$($f.FullName)" "${usuario}@${srv}:${destino}/" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Output "Error al subir $($f.Name) (scp codigo $LASTEXITCODE)" | Out-Host; return $false }
        Move-Item $f.FullName (Join-Path $carpetaEnviados $f.Name) -Force
    }
    return $true
}

# Hasta 3 intentos; si fallan y el servidor no se fijó a mano, se busca de nuevo
# (puede haber cambiado de IP o de red mientras tanto).
$enviado = $false
for ($intento = 1; $intento -le 3 -and -not $enviado; $intento++) {
    $enviado = Send-Reportes $servidor
    if (-not $enviado -and $intento -lt 3) {
        Start-Sleep 5
        if (-not $servidorFijo) {
            $nuevo = Find-Servidor -SinCache
            if ($nuevo) { $servidor = $nuevo }
        }
    }
}
if (-not $enviado) {
    Write-Output "No se pudo enviar. El reporte queda guardado y se reintenta en la proxima ejecucion."
    Write-Output "========== SCRIPT con ERROR=========="
    exit 1
}
try { Set-Content -Path $archivoUltimo -Value $servidor -Encoding ASCII } catch {}
Write-Output "========== SCRIPT COMPLETADO con EXITO=========="
