<?php
/**
 * Mendek Arena Masteran Burung v2 — Backend API (limopancer.com/mendek/api.php)
 * Kompatibel penuh dengan Flutter v1 (verify, ping, config) dan fitur baru v2:
 * - Dynamic Branding (app_name, logo_url, hero_title, accent_color, announcement)
 * - Fade-In Default & Battery Guard Thresholds
 * - Katalog Preset Masteran (?action=catalog)
 * - Monitoring Baterai, Suhu & Pemutaran Real-Time
 * - Admin Endpoints untuk update branding & kelola key lisensi tanpa edit kode
 */

declare(strict_types=1);
date_default_timezone_set('Asia/Jakarta');

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Admin-Secret');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

// Ganti secret admin ini (atau set environment variable MENDEK_ADMIN_SECRET di server)
define('ADMIN_SECRET', getenv('MENDEK_ADMIN_SECRET') ?: 'GANTI_SECRET_ADMIN_ANDA_2026');
define('DB_DIR', __DIR__ . '/data');
define('DB_FILE', DB_DIR . '/mendek_db.json');

function respond(int $statusCode, array $payload): void {
    http_response_code($statusCode);
    $payload['server_time'] = date('c');
    echo json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
    exit;
}

function defaultDatabase(): array {
    return [
        'remote_config' => [
            'app_name' => 'Mendek Arena',
            'logo_url' => 'https://limopancer.com/mendek/assets/logo.png',
            'accent_color' => '#007AFF',
            'hero_title' => 'Masteran Burung Otomatis',
            'hero_subtitle' => 'Jadwal Harian, Fade-In Volume & Anti Layar Mati',
            'announcement' => 'Semangat kicau mania',
            'wa_number' => '6281327559823',
            'wa_message' => 'Halo Admin, saya ingin meminta Key Login Mendek Arena Masteran Burung.',
            'tiktok_url' => 'https://www.tiktok.com/@mendekarena',
            'enable_offline_download' => true,
            'enable_cloud_anim' => true,
            'min_version' => '2.0.0',
            'fade_in_default_sec' => 25,
            'battery_guard_default_pct' => 90,
            'battery_guard_max_temp_c' => 42,
        ],
        'keys' => [
            'DEMO-KICAU-2026' => [
                'key' => 'DEMO-KICAU-2026',
                'label_user' => 'Member Demo Kicau',
                'active' => true,
                'expires_at' => '2027-12-31 23:59:59',
                'bound_device_id' => '',
                'device_name' => '',
                'app_version' => '',
                'last_seen' => null,
                'playing_now' => null,
                'battery_pct' => null,
                'battery_temp' => null,
                'is_charging' => false,
            ],
        ],
        'catalog' => [
            [
                'id' => 'cat_cililin',
                'title' => 'Masteran Cililin Rapat Kristal',
                'species' => 'Murai Batu / Kacer / Cucak Ijo',
                'platform' => 'youtube',
                'url' => 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
                'recommended_play_min' => 15,
                'recommended_pause_min' => 5,
                'recommended_fade_sec' => 25,
            ],
            [
                'id' => 'cat_kenari',
                'title' => 'Kenari Isian Panjang Non-Stop',
                'species' => 'Murai Batu / Lovebird',
                'platform' => 'youtube',
                'url' => 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
                'recommended_play_min' => 20,
                'recommended_pause_min' => 10,
                'recommended_fade_sec' => 30,
            ],
        ],
    ];
}

function loadDb(): array {
    if (!is_dir(DB_DIR)) {
        @mkdir(DB_DIR, 0755, true);
    }
    if (!file_exists(DB_FILE)) {
        $initial = defaultDatabase();
        saveDb($initial);
        return $initial;
    }
    $fp = fopen(DB_FILE, 'rb');
    if (!$fp) {
        return defaultDatabase();
    }
    flock($fp, LOCK_SH);
    $raw = stream_get_contents($fp);
    flock($fp, LOCK_UN);
    fclose($fp);

    $decoded = json_decode((string)$raw, true);
    if (!is_array($decoded)) {
        return defaultDatabase();
    }
    $defaults = defaultDatabase();
    $decoded['remote_config'] = array_merge($defaults['remote_config'], $decoded['remote_config'] ?? []);
    $decoded['keys'] = $decoded['keys'] ?? $defaults['keys'];
    $decoded['catalog'] = $decoded['catalog'] ?? $defaults['catalog'];
    return $decoded;
}

function saveDb(array $db): bool {
    if (!is_dir(DB_DIR)) {
        @mkdir(DB_DIR, 0755, true);
    }
    $fp = fopen(DB_FILE, 'cb+');
    if (!$fp) {
        return false;
    }
    if (!flock($fp, LOCK_EX)) {
        fclose($fp);
        return false;
    }
    ftruncate($fp, 0);
    rewind($fp);
    fwrite($fp, json_encode($db, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
    return true;
}

function readInput(): array {
    $data = array_merge($_GET, $_POST);
    $rawBody = file_get_contents('php://input');
    if (is_string($rawBody) && trim($rawBody) !== '') {
        $json = json_decode($rawBody, true);
        if (is_array($json)) {
            $data = array_merge($data, $json);
        }
    }
    return $data;
}

function isKeyExpired(?string $expiresAt): bool {
    if ($expiresAt === null || trim($expiresAt) === '') {
        return false;
    }
    $ts = strtotime($expiresAt);
    if ($ts === false) {
        return false;
    }
    return time() > $ts;
}

function requireAdmin(array $input): void {
    $provided = $_SERVER['HTTP_X_ADMIN_SECRET'] ?? ($input['admin_secret'] ?? '');
    if (!is_string($provided) || !hash_equals(ADMIN_SECRET, $provided)) {
        respond(401, ['ok' => false, 'message' => 'Akses admin ditolak (secret tidak cocok).']);
    }
}

$input = readInput();
$action = trim((string)($input['action'] ?? 'config'));
$db = loadDb();

switch ($action) {
    case 'config':
        respond(200, [
            'ok' => true,
            'remote_config' => $db['remote_config'],
        ]);
        break;

    case 'catalog':
        respond(200, [
            'ok' => true,
            'catalog' => $db['catalog'],
        ]);
        break;

    case 'verify':
        $rawKey = strtoupper(trim((string)($input['key'] ?? '')));
        $deviceId = trim((string)($input['device_id'] ?? ''));
        $deviceName = trim((string)($input['device_name'] ?? 'Android HP'));
        $appVersion = trim((string)($input['app_version'] ?? '2.0.0'));

        if ($rawKey === '' || $deviceId === '') {
            respond(400, ['ok' => false, 'message' => 'Key dan Device ID wajib diisi.']);
        }

        if (!isset($db['keys'][$rawKey])) {
            respond(404, ['ok' => false, 'message' => 'Key lisensi tidak ditemukan.']);
        }

        $record = $db['keys'][$rawKey];
        if (empty($record['active'])) {
            respond(403, ['ok' => false, 'message' => 'Key lisensi dinonaktifkan oleh admin.']);
        }
        if (isKeyExpired($record['expires_at'] ?? null)) {
            respond(403, ['ok' => false, 'message' => 'Masa aktif Key sudah berakhir. Hubungi admin untuk perpanjang.']);
        }

        $boundId = trim((string)($record['bound_device_id'] ?? ''));
        if ($boundId !== '' && $boundId !== $deviceId) {
            respond(403, [
                'ok' => false,
                'message' => 'Key ini sudah terikat di HP lain (' . ($record['device_name'] ?: 'Perangkat Lain') . '). Hubungi admin untuk reset device.',
            ]);
        }

        $record['bound_device_id'] = $deviceId;
        $record['device_name'] = $deviceName;
        $record['app_version'] = $appVersion;
        $record['last_seen'] = date('c');
        $db['keys'][$rawKey] = $record;
        saveDb($db);

        respond(200, [
            'ok' => true,
            'message' => 'Aktivasi berhasil. Selamat datang ' . $record['label_user'] . '!',
            'user' => [
                'key' => $record['key'],
                'label_user' => $record['label_user'],
                'expires_at' => $record['expires_at'] ?? null,
                'bound_device_id' => $record['bound_device_id'],
            ],
            'remote_config' => $db['remote_config'],
        ]);
        break;

    case 'ping':
        $rawKey = strtoupper(trim((string)($input['key'] ?? '')));
        $deviceId = trim((string)($input['device_id'] ?? ''));

        if ($rawKey === '' || !isset($db['keys'][$rawKey])) {
            respond(404, ['ok' => false, 'message' => 'Key tidak ditemukan atau sudah dihapus.']);
        }

        $record = $db['keys'][$rawKey];
        if (empty($record['active'])) {
            respond(403, ['ok' => false, 'message' => 'Key diblokir oleh admin.']);
        }
        if (isKeyExpired($record['expires_at'] ?? null)) {
            respond(403, ['ok' => false, 'message' => 'Masa aktif Key sudah habis.']);
        }
        $boundId = trim((string)($record['bound_device_id'] ?? ''));
        if ($boundId !== '' && $deviceId !== '' && $boundId !== $deviceId) {
            respond(403, ['ok' => false, 'message' => 'Sesi berpindah ke perangkat lain.']);
        }

        $record['last_seen'] = date('c');
        if (isset($input['playing_now'])) {
            $record['playing_now'] = trim((string)$input['playing_now']);
        }
        if (isset($input['battery_pct'])) {
            $record['battery_pct'] = (int)$input['battery_pct'];
        }
        if (isset($input['battery_temp'])) {
            $record['battery_temp'] = (float)$input['battery_temp'];
        }
        if (isset($input['is_charging'])) {
            $record['is_charging'] = filter_var($input['is_charging'], FILTER_VALIDATE_BOOLEAN);
        }
        if (isset($input['app_version'])) {
            $record['app_version'] = trim((string)$input['app_version']);
        }
        $db['keys'][$rawKey] = $record;
        saveDb($db);

        respond(200, [
            'ok' => true,
            'remote_config' => $db['remote_config'],
        ]);
        break;

    case 'admin_dashboard':
        requireAdmin($input);
        respond(200, [
            'ok' => true,
            'remote_config' => $db['remote_config'],
            'keys' => array_values($db['keys']),
            'catalog' => $db['catalog'],
        ]);
        break;

    case 'admin_save_config':
        requireAdmin($input);
        $allowedFields = [
            'app_name',
            'logo_url',
            'accent_color',
            'hero_title',
            'hero_subtitle',
            'announcement',
            'wa_number',
            'wa_message',
            'tiktok_url',
            'min_version',
        ];
        foreach ($allowedFields as $field) {
            if (isset($input[$field])) {
                $db['remote_config'][$field] = trim((string)$input[$field]);
            }
        }
        if (isset($input['enable_offline_download'])) {
            $db['remote_config']['enable_offline_download'] = filter_var($input['enable_offline_download'], FILTER_VALIDATE_BOOLEAN);
        }
        if (isset($input['enable_cloud_anim'])) {
            $db['remote_config']['enable_cloud_anim'] = filter_var($input['enable_cloud_anim'], FILTER_VALIDATE_BOOLEAN);
        }
        if (isset($input['fade_in_default_sec'])) {
            $db['remote_config']['fade_in_default_sec'] = max(0, (int)$input['fade_in_default_sec']);
        }
        if (isset($input['battery_guard_default_pct'])) {
            $db['remote_config']['battery_guard_default_pct'] = max(50, min(100, (int)$input['battery_guard_default_pct']));
        }
        if (isset($input['battery_guard_max_temp_c'])) {
            $db['remote_config']['battery_guard_max_temp_c'] = max(35, min(50, (int)$input['battery_guard_max_temp_c']));
        }

        saveDb($db);
        respond(200, [
            'ok' => true,
            'message' => 'Remote config & branding berhasil diperbarui.',
            'remote_config' => $db['remote_config'],
        ]);
        break;

    case 'admin_upsert_key':
        requireAdmin($input);
        $key = strtoupper(trim((string)($input['key'] ?? '')));
        if ($key === '') {
            respond(400, ['ok' => false, 'message' => 'Parameter key wajib diisi.']);
        }
        $existing = $db['keys'][$key] ?? [
            'key' => $key,
            'label_user' => 'Kicau Mania',
            'active' => true,
            'expires_at' => null,
            'bound_device_id' => '',
            'device_name' => '',
            'app_version' => '',
            'last_seen' => null,
            'playing_now' => null,
        ];
        if (isset($input['label_user'])) {
            $existing['label_user'] = trim((string)$input['label_user']);
        }
        if (isset($input['active'])) {
            $existing['active'] = filter_var($input['active'], FILTER_VALIDATE_BOOLEAN);
        }
        if (array_key_exists('expires_at', $input)) {
            $existing['expires_at'] = $input['expires_at'] ?: null;
        }
        if (!empty($input['reset_device'])) {
            $existing['bound_device_id'] = '';
            $existing['device_name'] = '';
        }
        $db['keys'][$key] = $existing;
        saveDb($db);

        respond(200, [
            'ok' => true,
            'message' => 'Data key berhasil disimpan.',
            'user' => $existing,
        ]);
        break;

    default:
        respond(400, ['ok' => false, 'message' => 'Action tidak dikenali.']);
}
