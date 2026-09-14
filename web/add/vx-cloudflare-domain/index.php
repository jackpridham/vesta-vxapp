<?php
error_reporting(NULL);
ob_start();
$TAB = 'DNS';

// Main include
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");

// Check user
if ($_SESSION['user'] != 'admin') {
    header("Location: /list/dns/");
    exit;
}

include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_domain_connections.php");

// List web domains owned by the selected account.
exec (VESTA_CMD."v-list-web-domains ".escapeshellarg($user)." json", $output, $return_var);
$web_domains = json_decode(implode('', $output), true);
$web_domains = is_array($web_domains) ? $web_domains : array();
unset($output);

$v_domain_connection_capability = vx_domain_connection_capability();
$v_domain_connection_enabled = !empty($v_domain_connection_capability['capabilities']['enrollmentEnabled']);
$v_domain_connection_target = isset($v_domain_connection_capability['capabilities']['connectionTarget']) ? (string) $v_domain_connection_capability['capabilities']['connectionTarget'] : '';
$v_domain_connection_ipv4 = isset($v_domain_connection_capability['capabilities']['ingress']['ipv4']) ? (string) $v_domain_connection_capability['capabilities']['ingress']['ipv4'] : '';
$v_domain_connection_quota_used = count($web_domains);
$v_domain_connection_quota_limit = isset($panel[$user]['WEB_DOMAINS']) ? (int) $panel[$user]['WEB_DOMAINS'] : 0;
$v_domain_connection_sites = array();
foreach ($web_domains as $listed_domain => $details) {
    if (vx_domain_connection_child_parent($details) !== '') continue;
    exec(VESTA_CMD.'v-list-vx-cloudflare-web-domain-status '.escapeshellarg($user).' '.escapeshellarg($listed_domain), $output, $return_var);
    $managed_status = trim(implode("\n", $output)); unset($output);
    if ($return_var === 0 && ($managed_status === 'managed' || $managed_status === 'degraded')) $v_domain_connection_sites[$listed_domain] = $details;
}

// Check POST request
if (!empty($_POST['ok'])) {

    // Check token
    if ((!isset($_POST['token'])) || ($_SESSION['token'] != $_POST['token'])) {
        header('location: /login/');
        exit();
    }

    $v_web_domain = isset($_POST['v_web_domain']) && !is_array($_POST['v_web_domain'])
        ? trim($_POST['v_web_domain'])
        : '';
    $v_cloudflare_domain = isset($_POST['v_cloudflare_domain']) && !is_array($_POST['v_cloudflare_domain']) ? trim($_POST['v_cloudflare_domain']) : '';
    $v_connection_id = isset($_POST['v_connection_id']) && !is_array($_POST['v_connection_id']) ? trim($_POST['v_connection_id']) : '';

    // Check empty fields
    if (!array_key_exists($v_web_domain, $v_domain_connection_sites)) $_SESSION['error_msg'] = __('The selected technical site is not owned by this account.');
    elseif (!$v_domain_connection_enabled || $v_domain_connection_target === '') $_SESSION['error_msg'] = __('Domain enrollment is disabled. Configure the DNS-only connection target and enable enrollment before accepting customer domains.');
    elseif ($v_connection_id !== '') {
        $hash = trim((string) shell_exec(VESTA_CMD.'v-spawn-ajax-process '.escapeshellarg($_SESSION['user']).' /usr/local/vesta/bin/v-reconcile-vx-web-domain-connection '.escapeshellarg($user).' '.escapeshellarg($v_web_domain).' '.escapeshellarg($v_connection_id)));
        $_SESSION['ok_msg'] = $hash === '' ? __('Connection check could not be queued.') : __('Connection check queued. Refresh this page for its latest status.');
    } elseif ($v_cloudflare_domain === '') $_SESSION['error_msg'] = __('Field "%s" can not be blank.', __('domain'));
    else {
        try { $request_id = 'panel-'.bin2hex(random_bytes(16)); } catch (Exception $exception) { $request_id = 'panel-'.uniqid('', true); }
        exec(VESTA_CMD.'v-add-vx-web-domain-connection '.escapeshellarg($user).' '.escapeshellarg($v_web_domain).' '.escapeshellarg($v_cloudflare_domain).' '.escapeshellarg($request_id).' json', $output, $return_var);
        $created = json_decode(implode('', $output), true); unset($output);
        if ($return_var !== 0 || empty($created['connection']['connectionID'])) $_SESSION['error_msg'] = __('The domain connection could not be created. Check that the hostname is public and available.');
        else {
            $connection_id = $created['connection']['connectionID'];
            shell_exec(VESTA_CMD.'v-spawn-ajax-process '.escapeshellarg($_SESSION['user']).' /usr/local/vesta/bin/v-reconcile-vx-web-domain-connection '.escapeshellarg($user).' '.escapeshellarg($v_web_domain).' '.escapeshellarg($connection_id));
            $_SESSION['ok_msg'] = __('Domain proof created. Copy the TXT record below; a background check has been queued.');
        }
    }
}

$v_domain_connections = array();
foreach ($v_domain_connection_sites as $domain => $details) $v_domain_connections[$domain] = vx_domain_connections_json($user, $domain);

render_page($user, $TAB, 'add_vx_cloudflare_domain');

// Flush session messages
unset($_SESSION['error_msg']);
unset($_SESSION['ok_msg']);
