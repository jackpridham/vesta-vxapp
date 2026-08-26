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
$edit_web_controller = read_cloudflare_ui_source($root.'/web/edit/web/index.php');
$edit_web_admin_template = read_cloudflare_ui_source($root.'/web/templates/admin/edit_web.html');
$edit_web_user_template = read_cloudflare_ui_source($root.'/web/templates/user/edit_web.html');
$web_api_controller = read_cloudflare_ui_source($root.'/web/api/index.php');
$custom_domains_helper = read_cloudflare_ui_source($root.'/web/inc/vx_custom_domains.php');
$custom_domains_js = read_cloudflare_ui_source($root.'/web/js/vx-custom-domains.js');

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
assert_cloudflare_ui_not_contains($add_web_controller, '/inc/vx_custom_domains.php', 'managed web creation still loads the edit-only custom-domain helper');
assert_cloudflare_ui_not_contains($add_web_controller, "\$_POST['v_aliases']", 'managed web creation still accepts crafted aliases');
assert_cloudflare_ui_contains($add_web_controller, "\$aliases = 'none';", 'managed web creation does not force an empty initial alias set');
assert_cloudflare_ui_not_contains($add_web_template, 'vx_custom_domains_render(', 'add-web template still exposes the edit-only alias component');
assert_cloudflare_ui_not_contains($add_web_template, "__('Aliases')", 'add-web template still exposes an Aliases label');
assert_cloudflare_ui_not_contains($add_web_template, 'name="v_aliases"', 'add-web template still posts aliases');
assert_cloudflare_ui_not_contains($add_web_template, 'name="v_dns"', 'managed add form still exposes legacy DNS support');
assert_cloudflare_ui_not_contains($add_web_template, 'name="v_mail"', 'managed add form still exposes incoherent mail support');
foreach (array('name="v_ssl"', 'name="v_letsencrypt"', 'name="v_ssl_crt"', 'name="v_ssl_key"', 'name="v_ssl_ca"') as $manual_ssl_field) {
    assert_cloudflare_ui_not_contains($add_web_template, $manual_ssl_field, 'managed add form exposes manual SSL field '.$manual_ssl_field);
}
assert_cloudflare_ui_contains($add_web_template, 'Cloudflare Origin CA — managed automatically', 'managed add form does not explain automatic SSL');
assert_cloudflare_ui_contains($add_web_controller, "\$_POST['v_ssl'] = '';", 'managed add controller does not discard crafted manual SSL input');
assert_cloudflare_ui_contains($add_web_controller, "\$_POST['v_letsencrypt'] = '';", 'managed add controller does not discard crafted Lets Encrypt input');

assert_cloudflare_ui_contains($alias_controller, "if (\$_SESSION['user'] != 'admin')", 'Cloudflare alias form is not admin-only');
assert_cloudflare_ui_contains($alias_controller, "(!isset(\$_POST['token']))", 'Cloudflare alias form lost its CSRF token presence check');
assert_cloudflare_ui_contains($alias_controller, "(\$_SESSION['token'] != \$_POST['token'])", 'Cloudflare alias form lost its CSRF token comparison');
assert_cloudflare_ui_contains($alias_controller, 'v-list-web-domains ".escapeshellarg($user)', 'Cloudflare alias form does not list domains for the resolved owner safely');
assert_cloudflare_ui_contains($alias_controller, 'array_key_exists($v_web_domain, $web_domains)', 'Cloudflare alias form does not enforce website ownership');
assert_cloudflare_ui_contains($alias_controller, 'v-list-vx-cloudflare-web-domain-status ', 'Cloudflare alias form does not filter for exact managed ownership');
assert_cloudflare_ui_contains($alias_controller, '$managed_status !== \'managed\'', 'Cloudflare alias form accepts non-managed lookalike websites');
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

assert_cloudflare_ui_contains($edit_web_controller, 'v-list-vx-cloudflare-web-domain-status ', 'web edit does not resolve exact managed-domain ownership');
assert_cloudflare_ui_contains($edit_web_controller, "\$v_cloudflare_status === 'managed'", 'web edit does not recognize exact managed status');
assert_cloudflare_ui_contains($edit_web_controller, "\$v_cloudflare_status === 'degraded'", 'web edit does not fail closed for degraded managed metadata');
assert_cloudflare_ui_contains($edit_web_controller, '/inc/vx_custom_domains.php', 'web edit does not load the custom-domain helper');
assert_cloudflare_ui_contains($edit_web_controller, 'vx_custom_domains_normalize($data[$v_domain][\'ALIAS\'])', 'web edit does not hydrate the persisted alias schema');
assert_cloudflare_ui_contains($edit_web_controller, 'vx_custom_domains_validate($posted_aliases, $_GET[\'domain\']', 'web edit does not validate custom domains against the immutable primary');
$edit_validation_position = strpos($edit_web_controller, 'vx_custom_domains_validate($posted_aliases');
$edit_mutation_position = strpos($edit_web_controller, 'v-change-web-domain-ip ');
if ($edit_validation_position === false || $edit_mutation_position === false
    || $edit_validation_position > $edit_mutation_position) {
    fail_cloudflare_ui_test('web edit validates custom domains after native mutation');
}
foreach (array(
    "v-change-web-domain-sslcert",
    "v-delete-letsencrypt-domain",
    "v-delete-web-domain-ssl",
    "v-add-letsencrypt-domain",
    "v-add-web-domain-ssl"
) as $ssl_mutation) {
    $mutation_position = strpos($edit_web_controller, $ssl_mutation, strpos($edit_web_controller, '// Change SSL certificate'));
    if ($mutation_position === false) {
        fail_cloudflare_ui_test('missing expected native SSL mutation path: '.$ssl_mutation);
    }
}
assert_cloudflare_ui_contains($edit_web_controller, 'if ((!$v_cloudflare_managed)', 'managed SSL mutation paths are not controller-gated');
foreach (array($edit_web_admin_template, $edit_web_user_template) as $edit_template) {
    assert_cloudflare_ui_contains($edit_template, "__('Aliases')", 'edit template does not label custom domains as aliases');
    assert_cloudflare_ui_contains($edit_template, "vx_custom_domains_render(\$v_aliases, trim(\$v_domain, \"'\"));", 'edit template does not use the shared hydrated custom-domain component');
    assert_cloudflare_ui_not_contains($edit_template, 'name="v_aliases"', 'edit template retained its legacy alias textarea');
    assert_cloudflare_ui_contains($edit_template, 'if (!empty($v_cloudflare_managed))', 'managed SSL template branch is missing');
    assert_cloudflare_ui_contains($edit_template, 'Cloudflare Origin CA — managed automatically', 'managed SSL ownership is not shown');
    assert_cloudflare_ui_contains($edit_template, 'Manual replacement and Lets Encrypt are disabled', 'managed SSL controls are not explained');
}

assert_cloudflare_ui_contains($custom_domains_helper, 'name="v_aliases"', 'custom-domain component lost the scalar aliases field');
assert_cloudflare_ui_not_contains($custom_domains_helper, 'name="v_aliases[]"', 'custom-domain component posts an incompatible aliases array');
assert_cloudflare_ui_contains($custom_domains_helper, 'data-vx-custom-domain-input', 'custom-domain component lacks individual visible inputs');
assert_cloudflare_ui_contains($custom_domains_helper, 'data-vx-custom-domain-add', 'custom-domain component lacks its add control');
assert_cloudflare_ui_contains($custom_domains_helper, 'data-vx-custom-domain-remove', 'custom-domain component lacks its remove control');
assert_cloudflare_ui_not_contains($custom_domains_helper, 'Add each custom domain separately.', 'custom-domain component retained unnecessary explanatory text');
foreach (array('normalizeDomain', 'isValidDomain', 'serializeDomains', 'validateDomains') as $browser_contract) {
    assert_cloudflare_ui_contains($custom_domains_js, $browser_contract.': '.$browser_contract, 'custom-domain browser helper does not export '.$browser_contract);
}

assert_cloudflare_ui_contains($web_api_controller, "\$requested_cmd === 'v-add-web-domain'", 'web API does not identify native website creation');
assert_cloudflare_ui_contains($web_api_controller, "VX_MANAGED_DNS_PROVIDER'] !== 'cloudflare-managed'", 'web API does not fail closed outside managed provider mode');
assert_cloudflare_ui_contains($web_api_controller, 'Error: managed DNS provider is not ready', 'web API permits native product creation when the managed provider is unavailable');
assert_cloudflare_ui_contains($web_api_controller, "VESTA_CMD.'v-add-vx-managed-web-domain '", 'web API does not delegate to the server-owned allocator');
assert_cloudflare_ui_contains($web_api_controller, ".escapeshellarg(\$managed_user).' '", 'web API managed owner is not shell escaped');
assert_cloudflare_ui_contains($web_api_controller, ".escapeshellarg(\$managed_ip).' '", 'web API managed IP is not shell escaped');
assert_cloudflare_ui_contains($web_api_controller, "\$managed_ip = isset(\$_POST['arg3'])", 'web API did not discard the caller primary-domain argument');
if (!empty($failures)) {
    foreach ($failures as $failure) {
        fwrite(STDERR, "FAIL: ".$failure."\n");
    }
    exit(1);
}

echo "Cloudflare web UI source-contract tests passed.\n";
