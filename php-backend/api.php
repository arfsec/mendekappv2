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
define('ADMIN_SECRET', getenv('MENDEK_ADMIN_SECRET') ?: 'mendek-admin-secret-ganti-ini');
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
            'logo_url' => 'https://limopancer.com/mendek/assets/logo.jpg',
            'accent_color' => '#007AFF',
            'hero_title' => 'Masteran Burung Otomatis',
            'hero_subtitle' => 'Jadwal Harian, Fade-In Volume & Anti Layar Mati',
            'announcement' => 'Semangat kicau mania',
            'wa_number' => '6281327559823',
            'wa_message' => 'Halo Admin, saya ingin meminta Key Login Mendek Arena Masteran Burung.',
            'tiktok_url' => 'https://www.tiktok.com/@mendekarena',
            'enable_offline_download' => true,
            'enable_cloud_anim' => true,
            'enable_social_feed' => true,
            'min_version' => '2.0.0',
            'apk_download_url' => '',
            'fade_in_default_sec' => 25,
            'battery_guard_default_pct' => 90,
            'battery_guard_max_temp_c' => 42,
            'github_sync_url' => '',
            'github_repo' => '',
            'sync_interval_sec' => 90,
            'ota_revision' => 1,
            'live_modules' => [],
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
        'social_posts' => [
            [
                'id' => 'post_welcome_mendek',
                'author_key' => 'ADMIN',
                'author_name' => 'Admin Mendek Arena',
                'author_region' => 'Nasional',
                'bird_tag' => 'Semua Burung Kicau',
                'category' => 'info',
                'title' => 'Selamat Datang di Komunitas Kicau Mania!',
                'content' => 'Bagikan info cuaca BMKG esok hari di wilayahmu, tips rawatan harian, jadwal masteran, atau kabar gantangan langsung dari APK.',
                'pinned' => true,
                'is_admin' => true,
                'liked_keys' => [],
                'comments' => [],
                'created_at' => '2026-01-01T07:00:00+07:00',
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
    $decoded['social_posts'] = is_array($decoded['social_posts'] ?? null) ? $decoded['social_posts'] : $defaults['social_posts'];
    $decoded['security'] = is_array($decoded['security'] ?? null) ? $decoded['security'] : [];
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

function requireAdmin(array $input, array $db): void {
    $provided = $_SERVER['HTTP_X_ADMIN_SECRET'] ?? ($input['admin_secret'] ?? '');
    if (!is_string($provided) || $provided === '') {
        respond(401, ['ok' => false, 'message' => 'Akses admin ditolak (secret kosong).']);
    }
    $customHash = $db['security']['admin_secret_hash'] ?? '';
    if (is_string($customHash) && $customHash !== '') {
        if (!password_verify($provided, $customHash)) {
            respond(401, ['ok' => false, 'message' => 'Akses admin ditolak (secret tidak cocok).']);
        }
        return;
    }
    if (!hash_equals(ADMIN_SECRET, $provided)) {
        respond(401, ['ok' => false, 'message' => 'Akses admin ditolak (secret tidak cocok).']);
    }
}

function isAdminAuthorized(array $input, array $db): bool {
    $provided = $_SERVER['HTTP_X_ADMIN_SECRET'] ?? ($input['admin_secret'] ?? '');
    if (!is_string($provided) || $provided === '') {
        return false;
    }
    $customHash = $db['security']['admin_secret_hash'] ?? '';
    if (is_string($customHash) && $customHash !== '') {
        return password_verify($provided, $customHash);
    }
    return hash_equals(ADMIN_SECRET, $provided);
}

function cleanSocialText(string $val, int $maxLen): string {
    $cleaned = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u', '', $val);
    $trimmed = trim((string)$cleaned);
    if (function_exists('mb_substr')) {
        return mb_substr($trimmed, 0, $maxLen, 'UTF-8');
    }
    return substr($trimmed, 0, $maxLen);
}

function normalizeSocialCategory(string $raw): string {
    $cat = strtolower(trim($raw));
    if (in_array($cat, ['rawatan', 'cuaca', 'lomba', 'isian', 'info'], true)) {
        return $cat;
    }
    return 'info';
}

function isSafeHttpsUrl(string $url): bool {
    $u = trim($url);
    if ($u === '' || preg_match('/[\x00-\x20\x7F]/', $u)) {
        return false;
    }
    $parts = @parse_url($u);
    if (!is_array($parts)) {
        return false;
    }
    $scheme = strtolower((string)($parts['scheme'] ?? ''));
    $host = strtolower((string)($parts['host'] ?? ''));
    return $scheme === 'https' && $host !== '';
}

function isAllowedGithubRawUrl(string $url): bool {
    if (!isSafeHttpsUrl($url)) {
        return false;
    }
    $host = strtolower((string)(parse_url(trim($url), PHP_URL_HOST) ?? ''));
    return in_array($host, ['raw.githubusercontent.com', 'gist.githubusercontent.com'], true);
}

function isValidGithubRepoSlug(string $slug): bool {
    return preg_match('/^[A-Za-z0-9._-]{1,64}\/[A-Za-z0-9._-]{1,100}$/', trim($slug)) === 1;
}

function sanitizeLiveModules($raw): array {
    if (!is_array($raw)) {
        return [];
    }
    $out = [];
    foreach ($raw as $idx => $item) {
        if (!is_array($item)) {
            continue;
        }
        $title = cleanSocialText((string)($item['title'] ?? ''), 70);
        $url = trim((string)($item['url'] ?? ''));
        if ($title === '' || !isSafeHttpsUrl($url)) {
            continue;
        }
        $id = preg_replace('/[^A-Za-z0-9_-]/', '', (string)($item['id'] ?? ''));
        if ($id === '') {
            $id = 'mod_' . ($idx + 1) . '_' . substr(md5($title . $url), 0, 6);
        }
        $mode = strtolower(trim((string)($item['open_mode'] ?? 'webview'))) === 'external' ? 'external' : 'webview';
        $out[] = [
            'id' => $id,
            'title' => $title,
            'subtitle' => cleanSocialText((string)($item['subtitle'] ?? ''), 120),
            'url' => $url,
            'badge' => cleanSocialText((string)($item['badge'] ?? 'LIVE'), 20) ?: 'LIVE',
            'open_mode' => $mode,
            'enabled' => !isset($item['enabled']) || filter_var($item['enabled'], FILTER_VALIDATE_BOOLEAN),
        ];
        if (count($out) >= 20) {
            break;
        }
    }
    return $out;
}

function fetchGithubOverrideJson(string $githubSyncUrl): ?array {
    if (!isAllowedGithubRawUrl($githubSyncUrl)) {
        return null;
    }
    $cacheFile = DB_DIR . '/github_sync_cache.json';
    $now = time();
    if (file_exists($cacheFile)) {
        $rawCache = @file_get_contents($cacheFile);
        $cached = json_decode((string)$rawCache, true);
        if (
            is_array($cached)
            && ($cached['url'] ?? '') === $githubSyncUrl
            && isset($cached['fetched_at'])
            && ($now - (int)$cached['fetched_at']) < 120
            && is_array($cached['payload'] ?? null)
        ) {
            return $cached['payload'];
        }
    }

    $ctx = stream_context_create([
        'http' => [
            'method' => 'GET',
            'timeout' => 4,
            'follow_location' => 0,
            'header' => "Accept: application/json\r\nUser-Agent: MendekArenaServer/3.3\r\n",
        ],
        'ssl' => [
            'verify_peer' => true,
            'verify_peer_name' => true,
        ],
    ]);
    $raw = @file_get_contents($githubSyncUrl, false, $ctx);
    if (!is_string($raw) || trim($raw) === '' || strlen($raw) > 512000) {
        return null;
    }
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        return null;
    }
    $payload = is_array($decoded['remote_config'] ?? null) ? $decoded['remote_config'] : $decoded;
    if (!is_dir(DB_DIR)) {
        @mkdir(DB_DIR, 0755, true);
    }
    @file_put_contents(
        $cacheFile,
        json_encode([
            'url' => $githubSyncUrl,
            'fetched_at' => $now,
            'payload' => $payload,
        ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)
    );
    return $payload;
}

function resolveEffectiveRemoteConfig(array $db): array {
    $cfg = $db['remote_config'];
    $cfg['live_modules'] = sanitizeLiveModules($cfg['live_modules'] ?? []);
    $cfg['sync_interval_sec'] = max(30, min(600, (int)($cfg['sync_interval_sec'] ?? 90)));
    $cfg['ota_revision'] = max(1, (int)($cfg['ota_revision'] ?? 1));

    $ghUrl = trim((string)($cfg['github_sync_url'] ?? ''));
    if ($ghUrl !== '' && isAllowedGithubRawUrl($ghUrl)) {
        $gh = fetchGithubOverrideJson($ghUrl);
        if (is_array($gh)) {
            $strFields = [
                'app_name', 'logo_url', 'accent_color', 'hero_title',
                'hero_subtitle', 'announcement', 'wa_number', 'wa_message',
                'tiktok_url', 'min_version',
            ];
            foreach ($strFields as $f) {
                if (isset($gh[$f]) && is_string($gh[$f])) {
                    $cfg[$f] = trim($gh[$f]);
                }
            }
            if (isset($gh['apk_download_url']) && is_string($gh['apk_download_url'])) {
                $cand = trim($gh['apk_download_url']);
                if ($cand === '' || isSafeHttpsUrl($cand)) {
                    $cfg['apk_download_url'] = $cand;
                }
            }
            if (isset($gh['github_repo']) && is_string($gh['github_repo']) && isValidGithubRepoSlug($gh['github_repo'])) {
                $cfg['github_repo'] = trim($gh['github_repo']);
            }
            foreach (['enable_offline_download', 'enable_cloud_anim', 'enable_social_feed'] as $bf) {
                if (isset($gh[$bf])) {
                    $cfg[$bf] = filter_var($gh[$bf], FILTER_VALIDATE_BOOLEAN);
                }
            }
            if (isset($gh['fade_in_default_sec'])) {
                $cfg['fade_in_default_sec'] = max(0, (int)$gh['fade_in_default_sec']);
            }
            if (isset($gh['battery_guard_default_pct'])) {
                $cfg['battery_guard_default_pct'] = max(50, min(100, (int)$gh['battery_guard_default_pct']));
            }
            if (isset($gh['battery_guard_max_temp_c'])) {
                $cfg['battery_guard_max_temp_c'] = max(35, min(50, (int)$gh['battery_guard_max_temp_c']));
            }
            if (isset($gh['sync_interval_sec'])) {
                $cfg['sync_interval_sec'] = max(30, min(600, (int)$gh['sync_interval_sec']));
            }
            if (isset($gh['ota_revision'])) {
                $cfg['ota_revision'] = max((int)$cfg['ota_revision'], (int)$gh['ota_revision']);
            }
            if (isset($gh['live_modules'])) {
                $cfg['live_modules'] = sanitizeLiveModules($gh['live_modules']);
            }
        }
    }
    return $cfg;
}

function sanitizeSocialPost(array $post, string $viewerKey = ''): array {
    $likedKeys = is_array($post['liked_keys'] ?? null) ? $post['liked_keys'] : [];
    $rawComments = is_array($post['comments'] ?? null) ? $post['comments'] : [];
    $comments = [];
    foreach ($rawComments as $c) {
        if (!is_array($c)) {
            continue;
        }
        $cAuthorKey = strtoupper(trim((string)($c['author_key'] ?? '')));
        $comments[] = [
            'id' => (string)($c['id'] ?? ''),
            'author_name' => (string)($c['author_name'] ?? 'Kicau Mania'),
            'content' => (string)($c['content'] ?? ''),
            'is_admin' => !empty($c['is_admin']),
            'is_mine' => $viewerKey !== '' && $cAuthorKey === $viewerKey,
            'created_at' => (string)($c['created_at'] ?? ''),
        ];
    }
    $authorKey = strtoupper(trim((string)($post['author_key'] ?? '')));
    return [
        'id' => (string)($post['id'] ?? ''),
        'author_name' => (string)($post['author_name'] ?? 'Kicau Mania'),
        'author_region' => (string)($post['author_region'] ?? ''),
        'bird_tag' => (string)($post['bird_tag'] ?? ''),
        'category' => normalizeSocialCategory((string)($post['category'] ?? 'info')),
        'title' => (string)($post['title'] ?? ''),
        'content' => (string)($post['content'] ?? ''),
        'pinned' => !empty($post['pinned']),
        'is_admin' => !empty($post['is_admin']),
        'likes_count' => count($likedKeys),
        'liked_by_me' => $viewerKey !== '' && in_array($viewerKey, $likedKeys, true),
        'is_mine' => $viewerKey !== '' && $authorKey === $viewerKey,
        'comments' => $comments,
        'created_at' => (string)($post['created_at'] ?? ''),
    ];
}

function sortAndSanitizeSocialFeed(array $posts, string $viewerKey = '', string $category = ''): array {
    $filterCat = $category !== '' && $category !== 'all' ? normalizeSocialCategory($category) : '';
    $sorted = $posts;
    usort($sorted, function (array $a, array $b): int {
        $pinDiff = (!empty($b['pinned']) ? 1 : 0) <=> (!empty($a['pinned']) ? 1 : 0);
        if ($pinDiff !== 0) {
            return $pinDiff;
        }
        return strcmp((string)($b['created_at'] ?? ''), (string)($a['created_at'] ?? ''));
    });
    $out = [];
    foreach ($sorted as $p) {
        if (!is_array($p)) {
            continue;
        }
        if ($filterCat !== '' && normalizeSocialCategory((string)($p['category'] ?? 'info')) !== $filterCat) {
            continue;
        }
        $out[] = sanitizeSocialPost($p, $viewerKey);
    }
    return $out;
}

function verifySocialUser(array $input, array $db): array {
    $rawKey = strtoupper(trim((string)($input['key'] ?? '')));
    $deviceId = trim((string)($input['device_id'] ?? ''));
    if ($rawKey === '' || !isset($db['keys'][$rawKey])) {
        respond(401, ['ok' => false, 'message' => 'Login Key diperlukan untuk menggunakan fitur Komunitas.']);
    }
    $record = $db['keys'][$rawKey];
    if (empty($record['active'])) {
        respond(403, ['ok' => false, 'message' => 'Key lisensi dinonaktifkan oleh admin.']);
    }
    if (isKeyExpired($record['expires_at'] ?? null)) {
        respond(403, ['ok' => false, 'message' => 'Masa aktif Key sudah berakhir.']);
    }
    $boundId = trim((string)($record['bound_device_id'] ?? ''));
    if ($boundId !== '' && $boundId !== 'web-browser-preview-01' && $deviceId !== '' && $boundId !== $deviceId) {
        respond(403, ['ok' => false, 'message' => 'Perangkat tidak cocok dengan Key lisensi.']);
    }
    return ['key' => $rawKey, 'record' => $record];
}

function trimSocialPostsStorage(array $posts, int $maxCount = 120): array {
    if (count($posts) <= $maxCount) {
        return $posts;
    }
    $pinned = [];
    $regular = [];
    foreach ($posts as $p) {
        if (!empty($p['pinned'])) {
            $pinned[] = $p;
        } else {
            $regular[] = $p;
        }
    }
    $remain = max(0, $maxCount - count($pinned));
    return array_merge($pinned, array_slice($regular, 0, $remain));
}

$input = readInput();
$action = trim((string)($input['action'] ?? 'config'));
$db = loadDb();

switch ($action) {
    case 'config':
        respond(200, [
            'ok' => true,
            'remote_config' => resolveEffectiveRemoteConfig($db),
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
        $dryRun = !empty($input['dry_run']) || $deviceId === 'web-browser-preview-01';

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
        if ($boundId === 'web-browser-preview-01') {
            $boundId = '';
        }
        if ($boundId !== '' && $boundId !== $deviceId) {
            respond(403, [
                'ok' => false,
                'message' => 'Key ini sudah terikat di HP lain (' . ($record['device_name'] ?: 'Perangkat Lain') . '). Hubungi admin untuk reset device.',
            ]);
        }

        if (!$dryRun) {
            $record['bound_device_id'] = $deviceId;
            $record['device_name'] = $deviceName;
            $record['app_version'] = $appVersion;
            $record['last_seen'] = date('c');
            $db['keys'][$rawKey] = $record;
            saveDb($db);
        }

        respond(200, [
            'ok' => true,
            'message' => 'Aktivasi berhasil. Selamat datang ' . $record['label_user'] . '!',
            'user' => [
                'key' => $record['key'],
                'label_user' => $record['label_user'],
                'expires_at' => $record['expires_at'] ?? null,
                'bound_device_id' => $dryRun ? $boundId : $record['bound_device_id'],
            ],
            'remote_config' => resolveEffectiveRemoteConfig($db),
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
            'remote_config' => resolveEffectiveRemoteConfig($db),
        ]);
        break;

    case 'admin_dashboard':
        requireAdmin($input, $db);
        respond(200, [
            'ok' => true,
            'remote_config' => resolveEffectiveRemoteConfig($db),
            'keys' => array_values($db['keys']),
            'catalog' => $db['catalog'],
            'social_posts' => sortAndSanitizeSocialFeed($db['social_posts']),
        ]);
        break;

    case 'admin_save_config':
        requireAdmin($input, $db);
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
            'apk_download_url',
        ];
        foreach ($allowedFields as $field) {
            if (isset($input[$field])) {
                $val = trim((string)$input[$field]);
                if ($field === 'apk_download_url' && $val !== '' && !isSafeHttpsUrl($val)) {
                    respond(400, ['ok' => false, 'message' => 'URL download APK wajib diawali https:// yang valid.']);
                }
                $db['remote_config'][$field] = $val;
            }
        }
        if (isset($input['github_sync_url'])) {
            $ghUrl = trim((string)$input['github_sync_url']);
            if ($ghUrl !== '' && !isAllowedGithubRawUrl($ghUrl)) {
                respond(400, ['ok' => false, 'message' => 'URL GitHub Sync harus berupa HTTPS dari raw.githubusercontent.com atau gist.githubusercontent.com.']);
            }
            $db['remote_config']['github_sync_url'] = $ghUrl;
        }
        if (isset($input['github_repo'])) {
            $repo = trim((string)$input['github_repo']);
            if ($repo !== '' && !isValidGithubRepoSlug($repo)) {
                respond(400, ['ok' => false, 'message' => 'Format repo GitHub harus pemilik/nama_repo (contoh: mendek/mendekappv2).']);
            }
            $db['remote_config']['github_repo'] = $repo;
        }
        if (isset($input['sync_interval_sec'])) {
            $db['remote_config']['sync_interval_sec'] = max(30, min(600, (int)$input['sync_interval_sec']));
        }
        if (isset($input['live_modules']) && is_array($input['live_modules'])) {
            $db['remote_config']['live_modules'] = sanitizeLiveModules($input['live_modules']);
        }
        $rawLogo = (string)($db['remote_config']['logo_url'] ?? '');
        if (preg_match('/^data:image\/(png|jpe?g|webp);base64,(.+)$/i', $rawLogo, $m)) {
            $ext = strtolower($m[1]) === 'jpeg' ? 'jpg' : strtolower($m[1]);
            $bin = base64_decode($m[2], true);
            if ($bin !== false && strlen($bin) > 0) {
                $assetsDir = __DIR__ . '/assets';
                if (!is_dir($assetsDir)) {
                    @mkdir($assetsDir, 0755, true);
                }
                $targetFile = $assetsDir . '/uploaded_logo.' . $ext;
                if (@file_put_contents($targetFile, $bin) !== false) {
                    $isHttps = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
                        || (($_SERVER['SERVER_PORT'] ?? '') === '443')
                        || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');
                    $scheme = $isHttps ? 'https' : 'http';
                    $host = $_SERVER['HTTP_HOST'] ?? 'limopancer.com';
                    $basePath = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '')), '/');
                    $db['remote_config']['logo_url'] = $scheme . '://' . $host . $basePath . '/assets/uploaded_logo.' . $ext . '?v=' . time();
                }
            }
        }
        if (isset($input['enable_offline_download'])) {
            $db['remote_config']['enable_offline_download'] = filter_var($input['enable_offline_download'], FILTER_VALIDATE_BOOLEAN);
        }
        if (isset($input['enable_cloud_anim'])) {
            $db['remote_config']['enable_cloud_anim'] = filter_var($input['enable_cloud_anim'], FILTER_VALIDATE_BOOLEAN);
        }
        if (isset($input['enable_social_feed'])) {
            $db['remote_config']['enable_social_feed'] = filter_var($input['enable_social_feed'], FILTER_VALIDATE_BOOLEAN);
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

        $db['remote_config']['ota_revision'] = max(1, (int)($db['remote_config']['ota_revision'] ?? 1)) + 1;
        @unlink(DB_DIR . '/github_sync_cache.json');
        saveDb($db);
        respond(200, [
            'ok' => true,
            'message' => 'Remote config, branding & modul live berhasil diperbarui (Rev #' . $db['remote_config']['ota_revision'] . ').',
            'remote_config' => resolveEffectiveRemoteConfig($db),
        ]);
        break;

    case 'admin_save_modules':
        requireAdmin($input, $db);
        $rawMods = $input['live_modules'] ?? null;
        if (!is_array($rawMods)) {
            respond(400, ['ok' => false, 'message' => 'Data live_modules harus berupa array.']);
        }
        $db['remote_config']['live_modules'] = sanitizeLiveModules($rawMods);
        $db['remote_config']['ota_revision'] = max(1, (int)($db['remote_config']['ota_revision'] ?? 1)) + 1;
        saveDb($db);
        respond(200, [
            'ok' => true,
            'message' => count($db['remote_config']['live_modules']) . ' modul fitur live berhasil disimpan.',
            'remote_config' => resolveEffectiveRemoteConfig($db),
        ]);
        break;

    case 'admin_upsert_key':
        requireAdmin($input, $db);
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
            'battery_pct' => null,
            'battery_temp' => null,
            'is_charging' => false,
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

    case 'admin_delete_key':
        requireAdmin($input, $db);
        $key = strtoupper(trim((string)($input['key'] ?? '')));
        if ($key === '') {
            respond(400, ['ok' => false, 'message' => 'Parameter key wajib diisi.']);
        }
        if (!isset($db['keys'][$key])) {
            respond(404, ['ok' => false, 'message' => 'Key tidak ditemukan di server.']);
        }
        unset($db['keys'][$key]);
        saveDb($db);

        respond(200, [
            'ok' => true,
            'message' => 'Key "' . $key . '" berhasil dihapus permanen.',
            'keys' => array_values($db['keys']),
        ]);
        break;

    case 'admin_save_catalog':
        requireAdmin($input, $db);
        $rawCatalog = $input['catalog'] ?? null;
        if (!is_array($rawCatalog)) {
            respond(400, ['ok' => false, 'message' => 'Data catalog harus berupa array.']);
        }
        $cleanCatalog = [];
        foreach ($rawCatalog as $idx => $item) {
            if (!is_array($item)) {
                continue;
            }
            $title = trim((string)($item['title'] ?? ''));
            $url = trim((string)($item['url'] ?? ''));
            if ($title === '' || $url === '') {
                continue;
            }
            $platform = strtolower(trim((string)($item['platform'] ?? 'youtube')));
            if (!in_array($platform, ['youtube', 'tiktok', 'synth', 'local'], true)) {
                $platform = 'youtube';
            }
            $id = trim((string)($item['id'] ?? ''));
            if ($id === '') {
                $id = 'cat_' . ($idx + 1) . '_' . substr(md5($title . $url), 0, 6);
            }
            $cleanCatalog[] = [
                'id' => $id,
                'title' => $title,
                'species' => trim((string)($item['species'] ?? 'Semua Burung Kicau')),
                'platform' => $platform,
                'url' => $url,
                'recommended_play_min' => max(1, (int)($item['recommended_play_min'] ?? 15)),
                'recommended_pause_min' => max(0, (int)($item['recommended_pause_min'] ?? 5)),
                'recommended_fade_sec' => max(0, (int)($item['recommended_fade_sec'] ?? 25)),
            ];
        }
        $db['catalog'] = $cleanCatalog;
        $db['remote_config']['ota_revision'] = max(1, (int)($db['remote_config']['ota_revision'] ?? 1)) + 1;
        saveDb($db);

        respond(200, [
            'ok' => true,
            'message' => count($cleanCatalog) . ' item katalog masteran berhasil disimpan.',
            'catalog' => $db['catalog'],
        ]);
        break;

    case 'admin_change_secret':
        requireAdmin($input, $db);
        $newSecret = trim((string)($input['new_secret'] ?? ''));
        if (strlen($newSecret) < 6) {
            respond(400, ['ok' => false, 'message' => 'Admin Secret / PIN baru minimal 6 karakter.']);
        }
        $db['security']['admin_secret_hash'] = password_hash($newSecret, PASSWORD_DEFAULT);
        $db['security']['updated_at'] = date('c');
        saveDb($db);

        respond(200, [
            'ok' => true,
            'message' => 'Admin Secret / PIN Server berhasil diperbarui.',
        ]);
        break;

    case 'social_feed':
        $viewerKey = strtoupper(trim((string)($input['key'] ?? '')));
        $catFilter = trim((string)($input['category'] ?? ''));
        respond(200, [
            'ok' => true,
            'enable_social_feed' => !empty($db['remote_config']['enable_social_feed']),
            'posts' => sortAndSanitizeSocialFeed($db['social_posts'], $viewerKey, $catFilter),
        ]);
        break;

    case 'social_create':
        if (empty($db['remote_config']['enable_social_feed'])) {
            respond(403, ['ok' => false, 'message' => 'Fitur Komunitas sedang dinonaktifkan admin.']);
        }
        $auth = verifySocialUser($input, $db);
        $rawKey = $auth['key'];
        $record = $auth['record'];
        $title = cleanSocialText((string)($input['title'] ?? ''), 100);
        $content = cleanSocialText((string)($input['content'] ?? ''), 800);
        if ($title === '' || $content === '') {
            respond(400, ['ok' => false, 'message' => 'Judul dan isi info tidak boleh kosong.']);
        }
        $category = normalizeSocialCategory((string)($input['category'] ?? 'info'));
        $region = cleanSocialText((string)($input['author_region'] ?? ''), 80);
        $birdTag = cleanSocialText((string)($input['bird_tag'] ?? ''), 60);
        $authorName = cleanSocialText((string)($record['label_user'] ?? 'Kicau Mania'), 50);
        if ($authorName === '') {
            $authorName = 'Kicau Mania';
        }
        $newPost = [
            'id' => 'post_' . date('YmdHis') . '_' . bin2hex(random_bytes(3)),
            'author_key' => $rawKey,
            'author_name' => $authorName,
            'author_region' => $region,
            'bird_tag' => $birdTag,
            'category' => $category,
            'title' => $title,
            'content' => $content,
            'pinned' => false,
            'is_admin' => false,
            'liked_keys' => [],
            'comments' => [],
            'created_at' => date('c'),
        ];
        array_unshift($db['social_posts'], $newPost);
        $db['social_posts'] = trimSocialPostsStorage($db['social_posts']);
        saveDb($db);
        respond(200, [
            'ok' => true,
            'message' => 'Info berhasil dibagikan ke Komunitas!',
            'post' => sanitizeSocialPost($newPost, $rawKey),
        ]);
        break;

    case 'social_like':
        $auth = verifySocialUser($input, $db);
        $rawKey = $auth['key'];
        $postId = trim((string)($input['post_id'] ?? ''));
        if ($postId === '') {
            respond(400, ['ok' => false, 'message' => 'post_id wajib diisi.']);
        }
        $foundIdx = null;
        foreach ($db['social_posts'] as $idx => $p) {
            if (($p['id'] ?? '') === $postId) {
                $foundIdx = $idx;
                break;
            }
        }
        if ($foundIdx === null) {
            respond(404, ['ok' => false, 'message' => 'Postingan tidak ditemukan.']);
        }
        $liked = is_array($db['social_posts'][$foundIdx]['liked_keys'] ?? null)
            ? $db['social_posts'][$foundIdx]['liked_keys']
            : [];
        if (in_array($rawKey, $liked, true)) {
            $liked = array_values(array_filter($liked, fn($k) => $k !== $rawKey));
        } else {
            $liked[] = $rawKey;
        }
        $db['social_posts'][$foundIdx]['liked_keys'] = $liked;
        saveDb($db);
        respond(200, [
            'ok' => true,
            'post' => sanitizeSocialPost($db['social_posts'][$foundIdx], $rawKey),
        ]);
        break;

    case 'social_comment':
        if (empty($db['remote_config']['enable_social_feed'])) {
            respond(403, ['ok' => false, 'message' => 'Fitur Komunitas sedang dinonaktifkan admin.']);
        }
        $auth = verifySocialUser($input, $db);
        $rawKey = $auth['key'];
        $record = $auth['record'];
        $postId = trim((string)($input['post_id'] ?? ''));
        $content = cleanSocialText((string)($input['content'] ?? ''), 300);
        if ($postId === '' || $content === '') {
            respond(400, ['ok' => false, 'message' => 'Komentar tidak boleh kosong.']);
        }
        $foundIdx = null;
        foreach ($db['social_posts'] as $idx => $p) {
            if (($p['id'] ?? '') === $postId) {
                $foundIdx = $idx;
                break;
            }
        }
        if ($foundIdx === null) {
            respond(404, ['ok' => false, 'message' => 'Postingan tidak ditemukan.']);
        }
        $authorName = cleanSocialText((string)($record['label_user'] ?? 'Kicau Mania'), 50);
        $comments = is_array($db['social_posts'][$foundIdx]['comments'] ?? null)
            ? $db['social_posts'][$foundIdx]['comments']
            : [];
        $comments[] = [
            'id' => 'cmt_' . date('YmdHis') . '_' . bin2hex(random_bytes(2)),
            'author_key' => $rawKey,
            'author_name' => $authorName !== '' ? $authorName : 'Kicau Mania',
            'content' => $content,
            'is_admin' => false,
            'created_at' => date('c'),
        ];
        if (count($comments) > 50) {
            $comments = array_slice($comments, -50);
        }
        $db['social_posts'][$foundIdx]['comments'] = $comments;
        saveDb($db);
        respond(200, [
            'ok' => true,
            'message' => 'Komentar terkirim.',
            'post' => sanitizeSocialPost($db['social_posts'][$foundIdx], $rawKey),
        ]);
        break;

    case 'social_delete':
        $postId = trim((string)($input['post_id'] ?? ''));
        if ($postId === '') {
            respond(400, ['ok' => false, 'message' => 'post_id wajib diisi.']);
        }
        $isAdmin = isAdminAuthorized($input, $db);
        $viewerKey = '';
        if (!$isAdmin) {
            $auth = verifySocialUser($input, $db);
            $viewerKey = $auth['key'];
        }
        $foundIdx = null;
        foreach ($db['social_posts'] as $idx => $p) {
            if (($p['id'] ?? '') === $postId) {
                $foundIdx = $idx;
                break;
            }
        }
        if ($foundIdx === null) {
            respond(404, ['ok' => false, 'message' => 'Postingan tidak ditemukan.']);
        }
        $postAuthorKey = strtoupper(trim((string)($db['social_posts'][$foundIdx]['author_key'] ?? '')));
        if (!$isAdmin && $postAuthorKey !== $viewerKey) {
            respond(403, ['ok' => false, 'message' => 'Anda hanya dapat menghapus postingan milik sendiri.']);
        }
        array_splice($db['social_posts'], $foundIdx, 1);
        saveDb($db);
        respond(200, [
            'ok' => true,
            'message' => 'Postingan berhasil dihapus.',
            'posts' => sortAndSanitizeSocialFeed($db['social_posts'], $viewerKey),
        ]);
        break;

    case 'admin_social_post':
        requireAdmin($input, $db);
        $title = cleanSocialText((string)($input['title'] ?? ''), 100);
        $content = cleanSocialText((string)($input['content'] ?? ''), 800);
        if ($title === '' || $content === '') {
            respond(400, ['ok' => false, 'message' => 'Judul dan isi info admin wajib diisi.']);
        }
        $category = normalizeSocialCategory((string)($input['category'] ?? 'info'));
        $region = cleanSocialText((string)($input['author_region'] ?? 'Nasional'), 80);
        $birdTag = cleanSocialText((string)($input['bird_tag'] ?? 'Info Resmi Admin'), 60);
        $authorName = cleanSocialText((string)($input['author_name'] ?? 'Admin Mendek Arena'), 50);
        $pinned = filter_var($input['pinned'] ?? true, FILTER_VALIDATE_BOOLEAN);
        $newPost = [
            'id' => 'post_admin_' . date('YmdHis') . '_' . bin2hex(random_bytes(3)),
            'author_key' => 'ADMIN',
            'author_name' => $authorName !== '' ? $authorName : 'Admin Mendek Arena',
            'author_region' => $region !== '' ? $region : 'Nasional',
            'bird_tag' => $birdTag,
            'category' => $category,
            'title' => $title,
            'content' => $content,
            'pinned' => $pinned,
            'is_admin' => true,
            'liked_keys' => [],
            'comments' => [],
            'created_at' => date('c'),
        ];
        array_unshift($db['social_posts'], $newPost);
        $db['social_posts'] = trimSocialPostsStorage($db['social_posts']);
        saveDb($db);
        respond(200, [
            'ok' => true,
            'message' => 'Pengumuman resmi berhasil diterbitkan ke Komunitas APK.',
            'posts' => sortAndSanitizeSocialFeed($db['social_posts']),
        ]);
        break;

    case 'admin_social_toggle_pin':
        requireAdmin($input, $db);
        $postId = trim((string)($input['post_id'] ?? ''));
        foreach ($db['social_posts'] as $idx => $p) {
            if (($p['id'] ?? '') === $postId) {
                $db['social_posts'][$idx]['pinned'] = empty($p['pinned']);
                saveDb($db);
                respond(200, [
                    'ok' => true,
                    'message' => 'Status pin postingan diperbarui.',
                    'posts' => sortAndSanitizeSocialFeed($db['social_posts']),
                ]);
            }
        }
        respond(404, ['ok' => false, 'message' => 'Postingan tidak ditemukan.']);
        break;

    case 'admin_social_delete':
        requireAdmin($input, $db);
        $postId = trim((string)($input['post_id'] ?? ''));
        $commentId = trim((string)($input['comment_id'] ?? ''));
        if ($postId === '') {
            respond(400, ['ok' => false, 'message' => 'post_id wajib diisi.']);
        }
        foreach ($db['social_posts'] as $idx => $p) {
            if (($p['id'] ?? '') === $postId) {
                if ($commentId !== '') {
                    $comments = is_array($p['comments'] ?? null) ? $p['comments'] : [];
                    $db['social_posts'][$idx]['comments'] = array_values(
                        array_filter($comments, fn($c) => ($c['id'] ?? '') !== $commentId)
                    );
                    saveDb($db);
                    respond(200, [
                        'ok' => true,
                        'message' => 'Komentar dihapus.',
                        'posts' => sortAndSanitizeSocialFeed($db['social_posts']),
                    ]);
                }
                array_splice($db['social_posts'], $idx, 1);
                saveDb($db);
                respond(200, [
                    'ok' => true,
                    'message' => 'Postingan berhasil dihapus.',
                    'posts' => sortAndSanitizeSocialFeed($db['social_posts']),
                ]);
            }
        }
        respond(404, ['ok' => false, 'message' => 'Postingan tidak ditemukan.']);
        break;

    default:
        respond(400, ['ok' => false, 'message' => 'Action tidak dikenali.']);
}
