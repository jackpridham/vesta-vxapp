<?php

function vx_docker_post_value($name, $default = '')
{
    if (!isset($_POST[$name]) || is_array($_POST[$name])) {
        return $default;
    }

    $value = trim((string) $_POST[$name]);
    if ($name === 'v_container_name') {
        $value = strtolower($value);
        $value = preg_replace('/[\s_]+/', '-', $value);
        $value = preg_replace('/[^a-z0-9-]/', '', $value);
        $value = preg_replace('/-+/', '-', $value);
        $value = trim($value, '-');
        $value = substr($value, 0, 63);
    }

    return $value;
}

function vx_docker_env_from_post()
{
    return vx_docker_textarea_to_stored_string(vx_docker_post_value('v_env'));
}

function vx_docker_mounts_from_post()
{
    return vx_docker_textarea_to_stored_string(vx_docker_post_value('v_mounts'));
}

function vx_docker_healthcheck_from_post()
{
    $container_port = vx_docker_post_value('v_container_port');
    $type = strtolower(vx_docker_post_value('v_healthcheck_type', 'http'));
    $target = vx_docker_post_value('v_healthcheck_target');
    $interval = vx_docker_post_value('v_healthcheck_interval', '60');

    if ($interval === '') {
        $interval = '60';
    }

    if ($type === 'none' || $type === 'docker') {
        $target = '';
    } elseif ($type === 'http' && $target === '' && $container_port !== '') {
        $target = 'http://127.0.0.1:'.$container_port.'/health';
    }

    return array(
        'HEALTHCHECK_TYPE' => $type,
        'HEALTHCHECK_TARGET' => $target,
        'HEALTHCHECK_INTERVAL' => $interval,
    );
}

function vx_docker_alert_thresholds_from_post()
{
    $alert_email = vx_docker_post_value('v_alert_email', 'yes');
    if ($alert_email !== 'yes' && $alert_email !== 'no') {
        $alert_email = vx_docker_boolean_post_value('v_alert_email') ? 'yes' : 'no';
    }

    return array(
        'CPU_ALERT_PCT' => vx_docker_post_value('v_cpu_alert_pct', '85') ?: '85',
        'MEM_ALERT_MB' => vx_docker_post_value('v_mem_alert_mb', '1024') ?: '1024',
        'NET_ALERT_MBPS' => vx_docker_post_value('v_net_alert_mbps', '50') ?: '50',
        'ALERT_EMAIL' => $alert_email,
    );
}

function vx_docker_route_domain_options($account_user = null)
{
    global $user;

    if ($account_user === null || $account_user === '') {
        $account_user = $user;
    }

    $options = array();
    $output = array();
    $return_var = 0;
    exec(VESTA_CMD."v-list-web-domains ".escapeshellarg($account_user)." json", $output, $return_var);
    if ($return_var !== 0) {
        return $options;
    }

    $domains = json_decode(implode('', $output), true);
    if (!is_array($domains)) {
        return $options;
    }

    ksort($domains);
    foreach ($domains as $domain => $domain_data) {
        $options[] = array(
            'value' => $domain,
            'label' => $domain,
        );
    }

    return $options;
}

function vx_docker_spec_from_post()
{
    $healthcheck = vx_docker_healthcheck_from_post();
    $alerts = vx_docker_alert_thresholds_from_post();

    $spec = array(
        'NAME' => vx_docker_post_value('v_container_name'),
        'IMAGE' => vx_docker_post_value('v_container_image'),
        'COMMAND' => vx_docker_post_value('v_container_command'),
        'ENV' => vx_docker_env_from_post(),
        'MOUNTS' => vx_docker_mounts_from_post(),
        'CONTAINER_PORT' => vx_docker_post_value('v_container_port'),
        'DOMAIN' => vx_docker_post_value('v_route_domain'),
        'ROUTE_PATH' => vx_docker_post_value('v_route_path'),
        'AUTO_START' => vx_docker_checkbox_to_yes_no('v_auto_start', 'yes'),
        'RESTART_POLICY' => vx_docker_post_value('v_restart_policy', 'unless-stopped'),
        'HEALTHCHECK_TYPE' => $healthcheck['HEALTHCHECK_TYPE'],
        'HEALTHCHECK_TARGET' => $healthcheck['HEALTHCHECK_TARGET'],
        'HEALTHCHECK_INTERVAL' => $healthcheck['HEALTHCHECK_INTERVAL'],
        'CPU_ALERT_PCT' => $alerts['CPU_ALERT_PCT'],
        'MEM_ALERT_MB' => $alerts['MEM_ALERT_MB'],
        'NET_ALERT_MBPS' => $alerts['NET_ALERT_MBPS'],
        'ALERT_EMAIL' => $alerts['ALERT_EMAIL'],
    );

    return vx_docker_build_spec_payload($spec);
}

function vx_docker_write_spec_file($tmpdir, $spec)
{
    $path = rtrim($tmpdir, '/').'/docker.spec';
    file_put_contents($path, $spec);
    return $path;
}

function vx_docker_build_spec_payload($spec)
{
    $payload = array();

    foreach ($spec as $key => $value) {
        $payload[] = $key."='".vx_docker_escape_spec_value($value)."'";
    }

    return implode("\n", $payload)."\n";
}

function vx_docker_textarea_to_stored_string($raw)
{
    if ($raw === '') {
        return '';
    }

    $raw = str_replace("\r", "\n", $raw);
    $lines = preg_split('/\n+/', $raw);
    $values = array();
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line !== '') {
            $values[] = $line;
        }
    }

    return implode('||', $values);
}

function vx_docker_escape_spec_value($value)
{
    return str_replace("'", "\\'", (string) $value);
}

function vx_docker_checkbox_to_yes_no($name, $default = 'no')
{
    if (!isset($_POST[$name])) {
        return $default;
    }

    return vx_docker_boolean_post_value($name) ? 'yes' : 'no';
}

function vx_docker_boolean_post_value($name)
{
    $value = strtolower(vx_docker_post_value($name));

    return in_array($value, array('1', 'true', 'yes', 'on'), true);
}
