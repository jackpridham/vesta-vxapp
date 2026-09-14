<?php

/* Read-only presentation helpers for native customer-domain connections. */
function vx_domain_connections_json($owner, $technical)
{
    $output = array();
    exec(VESTA_CMD.'v-list-vx-web-domain-connections '.escapeshellarg($owner).' '.escapeshellarg($technical).' json', $output, $return_var);
    if ($return_var !== 0) return array();
    $data = json_decode(implode('', $output), true);
    return is_array($data) && isset($data['connections']) && is_array($data['connections']) ? $data['connections'] : array();
}
function vx_domain_connection_capability()
{
    $output = array(); exec(VESTA_CMD.'v-list-vx-web-domain-connection-capability json', $output, $return_var);
    if ($return_var !== 0) return array();
    $data = json_decode(implode('', $output), true); return is_array($data) ? $data : array();
}
function vx_domain_connection_ingress_ipv4($capability)
{
    $values = isset($capability['capabilities']['ingress']['ipv4']) ? $capability['capabilities']['ingress']['ipv4'] : array();
    if (!is_array($values)) $values = array($values);
    $values = array_filter($values, 'is_string');
    return implode(', ', $values);
}
function vx_domain_connection_quota_label($quota)
{
    $quota = trim((string) $quota);
    if (strtolower($quota) === 'unlimited') return __('unlimited');
    return preg_match('/^[0-9]+$/', $quota) ? $quota : '';
}
function vx_domain_connection_action_allowed($enrollment_enabled, $action)
{
    return $enrollment_enabled || $action === 'retry' || $action === 'disconnect';
}
function vx_domain_connection_request_id()
{
    if (function_exists('openssl_random_pseudo_bytes')) {
        $bytes = openssl_random_pseudo_bytes(32, $strong);
        if ($bytes !== false && $strong) return 'panel-'.bin2hex($bytes);
    }
    return 'panel-'.hash('sha256', uniqid('', true).mt_rand());
}
function vx_domain_connection_child_parent($row)
{
    return isset($row['VX_CONNECTION_PARENT']) && is_string($row['VX_CONNECTION_PARENT']) ? trim($row['VX_CONNECTION_PARENT']) : '';
}
function vx_domain_connection_find_child_parent($owner, $hostname)
{
    $output = array(); exec(VESTA_CMD.'v-list-web-domain '.escapeshellarg($owner).' '.escapeshellarg($hostname).' json', $output, $return_var);
    if ($return_var !== 0) return '';
    $data = json_decode(implode('', $output), true);
    return is_array($data) && isset($data[$hostname]) ? vx_domain_connection_child_parent($data[$hostname]) : '';
}
function vx_domain_connection_render($connections)
{
    if (empty($connections)) return;
    ?><div class="vst-text" style="padding-top: 8px; color: #555;"><b><?php print __('Connected domains');?></b><ul style="margin: 5px 0 0 18px;">
    <?php foreach ($connections as $connection) { ?><li><?=htmlspecialchars((string) $connection['hostname'], ENT_QUOTES, 'UTF-8')?> — <?=htmlspecialchars((string) $connection['state'], ENT_QUOTES, 'UTF-8')?><?php if (!empty($connection['lastCheckedAt'])) { ?> (<?=__('last checked')?> <?=htmlspecialchars((string) $connection['lastCheckedAt'], ENT_QUOTES, 'UTF-8')?>)<?php } ?></li><?php } ?>
    </ul><?=__('These native child domains are managed from this technical site. The technical URL remains available.')?></div><?php
}
