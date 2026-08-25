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

// List web domains owned by the selected account.
exec (VESTA_CMD."v-list-web-domains ".escapeshellarg($user)." json", $output, $return_var);
$web_domains = json_decode(implode('', $output), true);
$web_domains = is_array($web_domains) ? $web_domains : array();
unset($output);

// Only exact VX-owned managed websites may receive Cloudflare aliases. This
// keeps caller-created lookalike hostnames out of the selection surface.
foreach (array_keys($web_domains) as $listed_domain) {
    exec (VESTA_CMD."v-list-vx-cloudflare-web-domain-status ".escapeshellarg($user)." ".escapeshellarg($listed_domain), $output, $return_var);
    $managed_status = trim(implode("\n", $output));
    unset($output);
    if (($return_var != 0) || ($managed_status !== 'managed')) {
        unset($web_domains[$listed_domain]);
    }
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
    $v_cloudflare_domain = isset($_POST['v_cloudflare_domain']) && !is_array($_POST['v_cloudflare_domain'])
        ? strtolower(trim($_POST['v_cloudflare_domain']))
        : '';

    // Check empty fields
    if (empty($v_web_domain)) $errors[] = __('web domain');
    if (empty($v_cloudflare_domain)) $errors[] = __('custom domain');
    if (!empty($errors[0])) {
        $_SESSION['error_msg'] = __('Field "%s" can not be blank.',implode(', ', $errors));
    }
    // The selected website must belong to the account whose domains were listed.
    if (empty($_SESSION['error_msg']) && !array_key_exists($v_web_domain, $web_domains)) {
        $_SESSION['error_msg'] = __('The selected web domain is not owned by this account.');
    }

    // Attach the already-configured custom domain as a local web alias only.
    if (empty($_SESSION['error_msg'])) {
        exec (VESTA_CMD."v-add-vx-cloudflare-web-alias ".escapeshellarg($user)." ".escapeshellarg($v_web_domain)." ".escapeshellarg($v_cloudflare_domain), $output, $return_var);
        check_return_code($return_var,$output);
        unset($output);
    }

    if (empty($_SESSION['error_msg'])) {
        $_SESSION['ok_msg'] = __('Cloudflare domain %s was attached to %s.',htmlentities($v_cloudflare_domain),htmlentities($v_web_domain));
        unset($v_cloudflare_domain);
    }
}

render_page($user, $TAB, 'add_vx_cloudflare_domain');

// Flush session messages
unset($_SESSION['error_msg']);
unset($_SESSION['ok_msg']);
