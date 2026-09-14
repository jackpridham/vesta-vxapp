<?php
/* Focused PHP 5.6-compatible behavior checks for panel connection decisions. */
function __($value) { return $value; }
require dirname(__DIR__).'/web/inc/vx_domain_connections.php';

$failures = array();
function panel_assert($condition, $message) { global $failures; if (!$condition) $failures[] = $message; }

panel_assert(vx_domain_connection_ingress_ipv4(array('capabilities' => array('ingress' => array('ipv4' => array('192.0.2.10', '192.0.2.11'))))) === '192.0.2.10, 192.0.2.11', 'IPv4 capability arrays must render as addresses');
panel_assert(vx_domain_connection_quota_label('unlimited') === 'unlimited', 'unlimited quota must not become zero');
panel_assert(vx_domain_connection_quota_label('12') === '12', 'numeric quota must remain readable');
panel_assert(vx_domain_connection_action_allowed(false, 'retry'), 'disabled enrollment must allow retry');
panel_assert(vx_domain_connection_action_allowed(false, 'disconnect'), 'disabled enrollment must allow disconnect');
panel_assert(!vx_domain_connection_action_allowed(false, 'create'), 'disabled enrollment must reject new connections');
$request_id = vx_domain_connection_request_id();
panel_assert((bool) preg_match('/^panel-[a-f0-9]{64}$/', $request_id), 'request IDs must remain PHP 5.6-compatible hexadecimal values');
$v_domain_connection_enabled = false;
$v_domain_connection_target = 'connect.vxapp.io';
$v_domain_connection_ipv4 = '192.0.2.10, 192.0.2.11';
$v_domain_connection_quota_used = 3;
$v_domain_connection_quota_limit = vx_domain_connection_quota_label('unlimited');
$v_domain_connection_sites = array('s-example.vxapp.io' => array());
$web_domains = $v_domain_connection_sites;
$v_web_domain = '';
$v_cloudflare_domain = '';
$v_domain_connections = array('s-example.vxapp.io' => array(array(
    'hostname' => 'www.example.com', 'state' => 'pending_dns', 'lastCheckedAt' => null,
    'connectionID' => 'connection-1', 'proof' => array('recordName' => '_vx-verify.www.example.com', 'recordValue' => 'proof-token')
)));
$_SESSION = array('token' => 'test-token', 'back' => '');
ob_start(); include dirname(__DIR__).'/web/templates/admin/add_vx_cloudflare_domain.html'; $rendered = ob_get_clean();
panel_assert(strpos($rendered, 'value="Connect" class="button" disabled') !== false, 'disabled enrollment must disable only new connection submission');
panel_assert(strpos($rendered, 'value="Retry check"') !== false && strpos($rendered, 'value="Disconnect"') !== false, 'disabled enrollment must retain retry and disconnect controls');
panel_assert(strpos($rendered, '3/unlimited') !== false, 'template must present unlimited quota honestly');
panel_assert(strpos($rendered, '192.0.2.10, 192.0.2.11') !== false, 'template must render all IPv4 ingress values');
if ($failures) { fwrite(STDERR, implode("\n", $failures)."\n"); exit(1); }
echo "Domain connection panel behavior tests passed.\n";
