<?php

$root = dirname(__DIR__);
$failures = array();

function fail_cloudflare_ui_test($message)
{
    global $failures;
    $failures[] = $message;
}

function read_cloudflare_ui_source($path)
{
    if (!is_file($path)) {
        fail_cloudflare_ui_test('missing required file: '.$path);
        return '';
    }

    return file_get_contents($path);
}

function assert_cloudflare_ui_contains($source, $needle, $message)
{
    if (strpos($source, $needle) === false) {
        fail_cloudflare_ui_test($message);
    }
}

function assert_cloudflare_ui_not_contains($source, $needle, $message)
{
    if (strpos($source, $needle) !== false) {
        fail_cloudflare_ui_test($message);
    }
}

function assert_cloudflare_ui_matches($source, $pattern, $message)
{
    if (!preg_match($pattern, $source)) {
        fail_cloudflare_ui_test($message);
    }
}

$add_web_controller = read_cloudflare_ui_source($root.'/web/add/web/index.php');
$add_web_template = read_cloudflare_ui_source($root.'/web/templates/admin/add_web.html');
$alias_controller = read_cloudflare_ui_source($root.'/web/add/vx-cloudflare-domain/index.php');
$alias_template = read_cloudflare_ui_source($root.'/web/templates/admin/add_vx_cloudflare_domain.html');
$dns_template = read_cloudflare_ui_source($root.'/web/templates/admin/list_dns.html');
$server_controller = read_cloudflare_ui_source($root.'/web/edit/server/index.php');
$server_template = read_cloudflare_ui_source($root.'/web/templates/admin/edit_server.html');
$system_config_command = read_cloudflare_ui_source($root.'/bin/v-list-sys-config');

assert_cloudflare_ui_contains($add_web_controller, "(!isset(\$_POST['token']))", 'managed web creation lost its CSRF token presence check');
assert_cloudflare_ui_contains($add_web_controller, "(\$_SESSION['token'] != \$_POST['token'])", 'managed web creation lost its CSRF token comparison');
assert_cloudflare_ui_contains($add_web_controller, 'v-add-vx-managed-web-domain ', 'panel web creation does not use the managed allocator');
assert_cloudflare_ui_contains(
    $add_web_controller,
    'v-add-vx-managed-web-domain ".escapeshellarg($user)." ".$v_ip." no ".$aliases." ".$proxy_ext',
    'managed allocator arguments do not follow USER IP no ALIASES PROXY_EXT'
);
assert_cloudflare_ui_contains($add_web_controller, '$generated_domain = trim(implode("\\n", $output));', 'managed allocator output is not consumed as the generated hostname');
assert_cloudflare_ui_contains($add_web_controller, '$v_domain = escapeshellarg($generated_domain);', 'generated hostname is not escaped for follow-up commands');
assert_cloudflare_ui_not_contains($add_web_controller, "\$_POST['v_domain']", 'web creation still accepts a posted primary domain');
assert_cloudflare_ui_not_contains($add_web_controller, 'VESTA_CMD."v-add-web-domain ', 'panel web creation still calls the caller-supplied native create command');
foreach (array('v-add-dns-domain ', 'v-add-dns-on-web-alias ', 'v-restart-dns', 'v-add-mail-domain ') as $legacy_command) {
    assert_cloudflare_ui_not_contains($add_web_controller, $legacy_command, 'managed web creation still invokes '.$legacy_command);
}

if (preg_match('/name\s*=\s*["\']v_domain["\']/i', $add_web_template)) {
    fail_cloudflare_ui_test('add-web template still posts a primary domain');
}
assert_cloudflare_ui_contains($add_web_template, 'name="v_aliases"', 'custom domains are not exposed as the alias input');
assert_cloudflare_ui_contains($add_web_template, "__('Custom domains')", 'visible alias field is not labelled as custom domains');
if (strpos($add_web_template, 'name="v_aliases"') > strpos($add_web_template, "__('Advanced options')")) {
    fail_cloudflare_ui_test('custom domains remain hidden inside advanced options');
}
assert_cloudflare_ui_not_contains($add_web_template, 'name="v_dns"', 'managed add form still exposes legacy DNS support');
assert_cloudflare_ui_not_contains($add_web_template, 'name="v_mail"', 'managed add form still exposes incoherent mail support');

assert_cloudflare_ui_contains($alias_controller, "if (\$_SESSION['user'] != 'admin')", 'Cloudflare alias form is not admin-only');
assert_cloudflare_ui_contains($alias_controller, "(!isset(\$_POST['token']))", 'Cloudflare alias form lost its CSRF token presence check');
assert_cloudflare_ui_contains($alias_controller, "(\$_SESSION['token'] != \$_POST['token'])", 'Cloudflare alias form lost its CSRF token comparison');
assert_cloudflare_ui_contains($alias_controller, 'v-list-web-domains ".escapeshellarg($user)', 'Cloudflare alias form does not list domains for the resolved owner safely');
assert_cloudflare_ui_contains($alias_controller, 'array_key_exists($v_web_domain, $web_domains)', 'Cloudflare alias form does not enforce website ownership');
assert_cloudflare_ui_contains(
    $alias_controller,
    'v-add-vx-cloudflare-web-alias ".escapeshellarg($user)." ".escapeshellarg($v_web_domain)." ".escapeshellarg($v_cloudflare_domain)',
    'Cloudflare alias mutation does not escape every owner/domain argument'
);
assert_cloudflare_ui_not_contains($alias_controller, 'curl ', 'Cloudflare alias form must not mutate external DNS');
assert_cloudflare_ui_contains($alias_template, 'name="token" value="<?=$_SESSION[\'token\']?>"', 'Cloudflare alias template lost its CSRF token');
assert_cloudflare_ui_contains($alias_template, 'name="v_web_domain"', 'Cloudflare alias template lacks the owned website selector');
assert_cloudflare_ui_contains($alias_template, 'name="v_cloudflare_domain"', 'Cloudflare alias template lacks the custom domain input');

assert_cloudflare_ui_contains($dns_template, '/add/vx-cloudflare-domain/', 'DNS toolbar lacks the Cloudflare domain action');
assert_cloudflare_ui_contains($dns_template, 'l-sort__create-btn2', 'DNS toolbar does not use the adjacent create-button style');
assert_cloudflare_ui_contains($dns_template, 'left:85px; bottom:-23px', 'DNS toolbar does not position the Cloudflare action beside the existing button');
assert_cloudflare_ui_contains($dns_template, "<div id=\"tooltip\"><?=__('Add Cloudflare Domain')?></div>", 'DNS toolbar Cloudflare action lacks visible text');
assert_cloudflare_ui_contains($dns_template, "if (\$_SESSION['user'] == 'admin')", 'DNS toolbar Cloudflare action is not visibly admin-gated');

assert_cloudflare_ui_contains($server_controller, 'v-change-vx-dns-provider ".escapeshellarg($requested_dns_provider)', 'provider selection does not use the bounded provider adapter safely');
assert_cloudflare_ui_not_contains($server_controller, 'v-change-sys-config-value VX_MANAGED_DNS_PROVIDER', 'provider selection bypasses the provider adapter');
assert_cloudflare_ui_contains($server_controller, 'v-list-vx-cloudflare-status', 'server configuration does not read sanitized Cloudflare status');
assert_cloudflare_ui_contains($server_controller, '$v_cloudflare_status === \'ready\'', 'Cloudflare status is not reduced to a safe configured flag');
assert_cloudflare_ui_contains($server_template, 'name="v_dns_provider"', 'server DNS section lacks the provider selector');
assert_cloudflare_ui_contains($server_template, 'value="local"', 'provider selector lacks local mode');
assert_cloudflare_ui_contains($server_template, 'value="cloudflare-managed"', 'provider selector lacks Cloudflare-managed mode');
assert_cloudflare_ui_contains($server_template, '$v_cloudflare_configured ? __(\'Configured\') : __(\'Not configured\')', 'server DNS section does not show sanitized configuration state');
assert_cloudflare_ui_contains($system_config_command, '"VX_MANAGED_DNS_PROVIDER":', 'system config JSON does not reload the managed provider into the server page');
assert_cloudflare_ui_contains($system_config_command, 'case "${VX_MANAGED_DNS_PROVIDER:-local}"', 'system config does not bound the managed provider value');
assert_cloudflare_ui_contains($system_config_command, 'cloudflare-managed)', 'system config does not accept the managed provider value');
assert_cloudflare_ui_contains($system_config_command, '*) VX_MANAGED_DNS_PROVIDER=local', 'system config does not default an unknown provider to local');
foreach (array('API token', 'Zone ID', 'Account email', 'Authorization:') as $protected_label) {
    assert_cloudflare_ui_not_contains($server_template, $protected_label, 'server template exposes protected Cloudflare detail: '.$protected_label);
}

if (!empty($failures)) {
    foreach ($failures as $failure) {
        fwrite(STDERR, "FAIL: ".$failure."\n");
    }
    exit(1);
}

echo "Cloudflare web UI source-contract tests passed.\n";
