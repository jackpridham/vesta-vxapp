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

function vx_docker_raw_post_value($name, $default = '')
{
    if (!isset($_POST[$name]) || is_array($_POST[$name])) {
        return $default;
    }

    return trim((string) $_POST[$name]);
}

function vx_docker_env_from_post()
{
    return vx_docker_textarea_to_stored_string(vx_docker_post_value('v_container_env'));
}

function vx_docker_mounts_from_post()
{
    return vx_docker_textarea_to_stored_string(vx_docker_post_value('v_container_mounts'));
}

function vx_docker_healthcheck_from_post()
{
    $container_port = vx_docker_container_port_from_post();
    $type = vx_docker_normalize_healthcheck_type(vx_docker_post_value('v_healthcheck_type', 'http'));
    $target = vx_docker_post_value('v_healthcheck_target');
    $interval = vx_docker_normalize_integer_string(vx_docker_post_value('v_healthcheck_interval', '60'), '60', 15, 3600);

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
    $alert_email = vx_docker_checkbox_to_yes_no('v_alert_email', 'no');

    return array(
        'CPU_ALERT_PCT' => vx_docker_normalize_integer_string(vx_docker_post_value('v_cpu_alert_pct', '85'), '85', 1, 1000),
        'MEM_ALERT_MB' => vx_docker_normalize_integer_string(vx_docker_post_value('v_mem_alert_mb', '1024'), '1024', 1, 1048576),
        'NET_ALERT_MBPS' => vx_docker_normalize_integer_string(vx_docker_post_value('v_net_alert_mbps', '50'), '50', 1, 100000),
        'ALERT_EMAIL' => $alert_email,
    );
}

function vx_docker_route_domain_options($account_user = null)
{
    if ($account_user === null || $account_user === '') {
        return array();
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
        if (!is_array($domain_data)) {
            $domain_data = array();
        }

        $options[] = array(
            'value' => $domain,
            'label' => $domain,
            'domain' => $domain,
            'owner' => $account_user,
            'suspended' => empty($domain_data['SUSPENDED']) ? 'no' : $domain_data['SUSPENDED'],
            'proxy' => empty($domain_data['PROXY']) ? '' : $domain_data['PROXY'],
            'proxy_mode' => empty($domain_data['PROXY_MODE']) ? '' : $domain_data['PROXY_MODE'],
            'proxy_target' => empty($domain_data['PROXY_TARGET']) ? '' : $domain_data['PROXY_TARGET'],
            'ssl' => empty($domain_data['SSL']) ? 'no' : $domain_data['SSL'],
            'letsencrypt' => empty($domain_data['LETSENCRYPT']) ? 'no' : $domain_data['LETSENCRYPT'],
            'backend' => empty($domain_data['BACKEND']) ? '' : $domain_data['BACKEND'],
            'ip' => empty($domain_data['IP']) ? '' : $domain_data['IP'],
            'data' => $domain_data,
        );
    }

    return $options;
}

function vx_docker_route_domain_is_owned($account_user, $domain_name)
{
    if ($account_user === null || $account_user === '' || $domain_name === '') {
        return false;
    }

    foreach (vx_docker_route_domain_options($account_user) as $domain_option) {
        if (!empty($domain_option['domain']) && $domain_option['domain'] === $domain_name) {
            return true;
        }
    }

    return false;
}

function vx_docker_find_domain_route($account_user, $domain_name)
{
    if ($account_user === null || $account_user === '' || $domain_name === '') {
        return array();
    }

    foreach (vx_docker_list_containers($account_user) as $container_name => $container_data) {
        if (!is_array($container_data)) {
            continue;
        }

        $container_domain = isset($container_data['DOMAIN']) ? trim((string) $container_data['DOMAIN']) : '';
        if ($container_domain !== $domain_name) {
            continue;
        }

        if (empty($container_data['NAME']) && is_string($container_name)) {
            $container_data['NAME'] = $container_name;
        }

        if (empty($container_data['OWNER'])) {
            $container_data['OWNER'] = $account_user;
        }

        return $container_data;
    }

    return array();
}

function vx_docker_route_matches_domain_record($container, $domain_data)
{
    if (!is_array($container) || !is_array($domain_data)) {
        return false;
    }

    $linked_target = isset($container['PROXY_TARGET']) ? trim((string) $container['PROXY_TARGET']) : '';
    if ($linked_target === '') {
        return false;
    }

    $proxy_template = isset($domain_data['PROXY']) ? trim((string) $domain_data['PROXY']) : '';
    $proxy_mode = empty($domain_data['PROXY_MODE']) ? 'proxy' : trim((string) $domain_data['PROXY_MODE']);
    $proxy_target = isset($domain_data['PROXY_TARGET']) ? trim((string) $domain_data['PROXY_TARGET']) : '';
    $proxy_profile = empty($domain_data['PROXY_PROFILE']) ? 'standard' : trim((string) $domain_data['PROXY_PROFILE']);
    $proxy_preserve_host = empty($domain_data['PROXY_PRESERVE_HOST']) ? 'yes' : trim((string) $domain_data['PROXY_PRESERVE_HOST']);
    $proxy_timeout = empty($domain_data['PROXY_TIMEOUT']) ? '60' : trim((string) $domain_data['PROXY_TIMEOUT']);
    $proxy_headers = isset($domain_data['PROXY_HEADERS']) ? trim((string) $domain_data['PROXY_HEADERS']) : '';

    return $proxy_template === 'vx-proxy'
        && $proxy_mode === 'proxy'
        && $proxy_target === $linked_target
        && $proxy_profile === 'application'
        && $proxy_preserve_host === 'yes'
        && $proxy_timeout === '60'
        && $proxy_headers === '';
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
        'CONTAINER_PORT' => vx_docker_container_port_from_post(),
        'DOMAIN' => vx_docker_post_value('v_route_domain'),
        'ROUTE_PATH' => vx_docker_route_path_from_post(),
        'AUTO_START' => vx_docker_checkbox_to_yes_no('v_auto_start', 'no'),
        'RESTART_POLICY' => vx_docker_normalize_restart_policy(vx_docker_post_value('v_restart_policy', 'unless-stopped')),
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
        $payload[] = $key.'="'.vx_docker_escape_spec_value($value).'"';
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

function vx_docker_textarea_lines($raw)
{
    if ($raw === '') {
        return array();
    }

    $raw = str_replace("\r", "\n", $raw);
    $lines = preg_split('/\n+/', $raw);
    if (!is_array($lines)) {
        return array();
    }

    $values = array();
    foreach ($lines as $line) {
        $line = trim((string) $line);
        if ($line !== '') {
            $values[] = $line;
        }
    }

    return $values;
}

function vx_docker_escape_spec_value($value)
{
    return str_replace(
        array('\\', '"', '$', '`'),
        array('\\\\', '\\"', '\\$', '\\`'),
        (string) $value
    );
}

function vx_docker_checkbox_to_yes_no($name, $default = 'no')
{
    if (!isset($_POST[$name])) {
        return $default;
    }

    return vx_docker_boolean_post_value($name) ? 'yes' : 'no';
}

function vx_docker_integer_post_is_valid($name, $default, $min, $max)
{
    $raw_value = vx_docker_raw_post_value($name, $default);
    $normalized_value = vx_docker_normalize_integer_string($raw_value, '', $min, $max);

    return $normalized_value !== '';
}

function vx_docker_boolean_post_value($name)
{
    $value = strtolower(vx_docker_post_value($name));

    return in_array($value, array('1', 'true', 'yes', 'on'), true);
}

function vx_docker_container_port_from_post()
{
    return vx_docker_normalize_integer_string(vx_docker_post_value('v_container_port'), '', 1, 65535);
}

function vx_docker_route_path_from_post()
{
    $path = vx_docker_post_value('v_route_path');
    if ($path === '' || $path === '/') {
        return '';
    }

    if (strpos($path, '/') !== 0) {
        $path = '/'.$path;
    }

    $path = substr($path, 0, 128);
    if (preg_match('/[\s?#]/', $path)) {
        return '';
    }

    return $path;
}

function vx_docker_normalize_healthcheck_type($type)
{
    $type = strtolower(trim((string) $type));

    if (!in_array($type, array('http', 'tcp', 'docker', 'none'), true)) {
        return 'http';
    }

    return $type;
}

function vx_docker_normalize_restart_policy($policy)
{
    $policy = trim((string) $policy);

    if (!in_array($policy, array('no', 'on-failure', 'always', 'unless-stopped'), true)) {
        return 'unless-stopped';
    }

    return $policy;
}

function vx_docker_normalize_yes_no($value, $default)
{
    $value = strtolower(trim((string) $value));
    if ($value !== 'yes' && $value !== 'no') {
        return $default;
    }

    return $value;
}

function vx_docker_normalize_integer_string($value, $default, $min, $max)
{
    $value = trim((string) $value);
    if ($value === '' || !preg_match('/^\d+$/', $value)) {
        return $default;
    }

    $integer_value = (int) $value;
    if ($integer_value < $min || $integer_value > $max) {
        return $default;
    }

    return (string) $integer_value;
}

function vx_docker_collect_form_errors($owner)
{
    $errors = array();

    $raw_container_name = vx_docker_raw_post_value('v_container_name');
    $container_name = vx_docker_post_value('v_container_name');
    if ($container_name === '') {
        $errors[] = __('Field "%s" can not be blank.', __('container name'));
    } elseif ($raw_container_name !== $container_name) {
        $errors[] = __('Docker container name may only contain lowercase letters, numbers, and hyphens.');
    }

    if (vx_docker_post_value('v_container_image') === '') {
        $errors[] = __('Field "%s" can not be blank.', __('image'));
    }

    $raw_container_port = vx_docker_raw_post_value('v_container_port');
    $container_port = vx_docker_container_port_from_post();
    if ($container_port === '') {
        if ($raw_container_port === '') {
            $errors[] = __('Field "%s" can not be blank.', __('container port'));
        } else {
            $errors[] = __('Container port must be between 1 and 65535.');
        }
    }

    $route_domain = vx_docker_post_value('v_route_domain');
    if ($route_domain !== '' && !vx_docker_route_domain_is_owned($owner, $route_domain)) {
        $errors[] = __('Only domains owned by this user can be routed to this container');
    }

    $raw_route_path = vx_docker_raw_post_value('v_route_path');
    $normalized_route_path = vx_docker_route_path_from_post();
    if ($raw_route_path !== '' && $raw_route_path !== '/' && $normalized_route_path === '') {
        $errors[] = __('Route path must start with / and may not contain spaces, ? or #.');
    } elseif ($normalized_route_path !== '') {
        $errors[] = __('Docker route path routing is not available yet.');
    }

    $raw_restart_policy = vx_docker_raw_post_value('v_restart_policy', 'unless-stopped');
    if (vx_docker_normalize_restart_policy($raw_restart_policy) !== $raw_restart_policy) {
        $errors[] = __('Restart policy is invalid.');
    }

    $raw_healthcheck_type = vx_docker_raw_post_value('v_healthcheck_type', 'http');
    $healthcheck_type = vx_docker_normalize_healthcheck_type($raw_healthcheck_type);
    if ($healthcheck_type !== $raw_healthcheck_type) {
        $errors[] = __('Health check type is invalid.');
    }

    if (!vx_docker_integer_post_is_valid('v_healthcheck_interval', '60', 15, 3600)) {
        $errors[] = __('Health check interval must be between 15 and 3600 seconds.');
    }

    $raw_healthcheck_target = vx_docker_raw_post_value('v_healthcheck_target');
    if ($healthcheck_type === 'http' && $raw_healthcheck_target !== '' && !vx_docker_is_valid_http_healthcheck_target($raw_healthcheck_target)) {
        $errors[] = __('Health check target must be a full http:// or https:// URL.');
    }

    if ($healthcheck_type === 'tcp') {
        if ($raw_healthcheck_target === '') {
            $errors[] = __('Health check target is required for TCP checks.');
        } elseif (!preg_match('/^[A-Za-z0-9.-]+:[0-9]{1,5}$/', $raw_healthcheck_target)) {
            $errors[] = __('Health check target must use host:port for TCP checks.');
        }
    }

    if (!vx_docker_integer_post_is_valid('v_cpu_alert_pct', '85', 1, 1000)) {
        $errors[] = __('CPU alert threshold must be between 1 and 1000.');
    }

    if (!vx_docker_integer_post_is_valid('v_mem_alert_mb', '1024', 1, 1048576)) {
        $errors[] = __('Memory alert threshold must be between 1 and 1048576 MB.');
    }

    if (!vx_docker_integer_post_is_valid('v_net_alert_mbps', '50', 1, 100000)) {
        $errors[] = __('Network alert threshold must be between 1 and 100000 Mbps.');
    }

    foreach (vx_docker_textarea_lines(vx_docker_raw_post_value('v_container_env')) as $env_line) {
        if (!preg_match('/^[A-Z0-9_][A-Z0-9_]*=.*$/', $env_line)) {
            $errors[] = __('Environment variables must use KEY=value with uppercase letters, numbers, and underscores in the key.');
            break;
        }
    }

    foreach (vx_docker_textarea_lines(vx_docker_raw_post_value('v_container_mounts')) as $mount_line) {
        $mount_separator = strpos($mount_line, ':');
        $mount_name = ($mount_separator === false) ? false : substr($mount_line, 0, $mount_separator);
        $mount_path = ($mount_separator === false) ? false : substr($mount_line, $mount_separator + 1);
        if (
            $mount_name === false
            || $mount_name === ''
            || $mount_path === false
            || $mount_path === ''
            || !preg_match('/^[a-z0-9][a-z0-9_-]{0,63}$/', $mount_name)
            || strpos($mount_path, '/') !== 0
        ) {
            $errors[] = __('Bind mounts must use name:/absolute/path.');
            break;
        }
    }

    return array_values(array_unique($errors));
}

function vx_docker_is_valid_http_healthcheck_target($target)
{
    $target = trim((string) $target);
    if ($target === '' || filter_var($target, FILTER_VALIDATE_URL) === false) {
        return false;
    }

    $scheme = parse_url($target, PHP_URL_SCHEME);
    return in_array($scheme, array('http', 'https'), true);
}

function vx_docker_current_actor()
{
    global $myvesta_logged_user, $user;

    if (isset($myvesta_logged_user) && $myvesta_logged_user !== '') {
        return $myvesta_logged_user;
    }

    if (isset($user) && $user !== '') {
        return $user;
    }

    return isset($_SESSION['user']) ? $_SESSION['user'] : '';
}

function vx_docker_is_admin_actor()
{
    global $myvesta_admin_look;

    return vx_docker_current_actor() === 'admin' && empty($myvesta_admin_look);
}

function vx_docker_resolve_owner_from_request($default_owner = '', $allow_admin_override = true)
{
    if ($allow_admin_override && vx_docker_is_admin_actor() && isset($_REQUEST['user']) && !is_array($_REQUEST['user'])) {
        return trim((string) $_REQUEST['user']);
    }

    return $default_owner;
}

function vx_docker_user_exists($owner, $users = null)
{
    $owner = trim((string) $owner);
    if ($owner === '') {
        return false;
    }

    if (!is_array($users) || empty($users)) {
        $users = vx_docker_list_users();
    }

    return isset($users[$owner]) && is_array($users[$owner]);
}

function vx_docker_assert_actor_can_access_owner($owner, $acting_user = null)
{
    if ($acting_user === null || $acting_user === '') {
        $acting_user = vx_docker_current_actor();
    }

    if ($acting_user !== 'admin' && $acting_user !== $owner) {
        return false;
    }

    return true;
}

function vx_docker_exec_json($command)
{
    $output = array();
    $return_var = 0;
    exec($command, $output, $return_var);
    if ($return_var !== 0) {
        return array(null, $return_var, $output);
    }

    $data = json_decode(implode('', $output), true);
    if (!is_array($data)) {
        $data = array();
    }

    return array($data, $return_var, $output);
}

function vx_docker_get_engine_state()
{
    list($docker_state) = vx_docker_exec_json(VESTA_CMD."v-check-docker-engine json");
    if (!is_array($docker_state)) {
        $docker_state = array();
    }

    return $docker_state;
}

function vx_docker_is_engine_available($docker_state = null)
{
    if (!is_array($docker_state)) {
        $docker_state = vx_docker_get_engine_state();
    }

    return !empty($docker_state['DOCKER_AVAILABLE']) && $docker_state['DOCKER_AVAILABLE'] === 'yes';
}

function vx_docker_is_daemon_available($docker_state = null)
{
    if (!is_array($docker_state)) {
        $docker_state = vx_docker_get_engine_state();
    }

    return !empty($docker_state['DOCKER_DAEMON_AVAILABLE']) && $docker_state['DOCKER_DAEMON_AVAILABLE'] === 'yes';
}

function vx_docker_list_containers($scope_owner)
{
    list($containers) = vx_docker_exec_json(
        VESTA_CMD."v-list-docker-containers ".escapeshellarg($scope_owner)." json"
    );

    if (!is_array($containers)) {
        return array();
    }

    return $containers;
}

function vx_docker_filter_containers_by_owner($containers, $owner)
{
    if ($owner === '' || !is_array($containers)) {
        return is_array($containers) ? $containers : array();
    }

    $filtered_containers = array();
    foreach ($containers as $container_key => $container_data) {
        if (!is_array($container_data)) {
            continue;
        }

        $container_owner = isset($container_data['OWNER']) ? trim((string) $container_data['OWNER']) : '';
        if ($container_owner === $owner) {
            $filtered_containers[$container_key] = $container_data;
        }
    }

    return $filtered_containers;
}

function vx_docker_get_container($owner, $name)
{
    list($container) = vx_docker_exec_json(
        VESTA_CMD."v-list-docker-container "
        .escapeshellarg($owner)
        ." "
        .escapeshellarg($name)
        ." json"
    );

    if (!is_array($container) || empty($container[$name]) || !is_array($container[$name])) {
        return array();
    }

    return $container[$name];
}

function vx_docker_resolve_accessible_container($owner, $name, $acting_user = null)
{
    if (!vx_docker_assert_actor_can_access_owner($owner, $acting_user)) {
        return array();
    }

    $name = trim((string) $name);
    if ($name === '') {
        return array();
    }

    $container = vx_docker_get_container($owner, $name);
    if (empty($container)) {
        return array();
    }

    if (empty($container['OWNER'])) {
        $container['OWNER'] = $owner;
    }

    if (empty($container['NAME'])) {
        $container['NAME'] = $name;
    }

    return $container;
}

function vx_docker_list_users()
{
    list($users) = vx_docker_exec_json(VESTA_CMD."v-list-users json");
    if (!is_array($users)) {
        return array();
    }

    ksort($users);
    return $users;
}

function vx_docker_get_user_panel($owner)
{
    list($data) = vx_docker_exec_json(VESTA_CMD."v-list-user ".escapeshellarg($owner)." json");
    if (!is_array($data) || empty($data[$owner]) || !is_array($data[$owner])) {
        return array();
    }

    return $data[$owner];
}

function vx_docker_get_quota_state($owner, $user_panel = null)
{
    if (!is_array($user_panel) || empty($user_panel)) {
        $user_panel = vx_docker_get_user_panel($owner);
    }

    $limit_raw = isset($user_panel['DOCKER_CONTAINERS']) ? trim((string) $user_panel['DOCKER_CONTAINERS']) : '';
    $used_raw = isset($user_panel['U_DOCKER_CONTAINERS']) ? trim((string) $user_panel['U_DOCKER_CONTAINERS']) : '0';

    $limit = null;
    if ($limit_raw !== '' && strtolower($limit_raw) !== 'unlimited') {
        $limit = (int) $limit_raw;
    }

    $used = (int) $used_raw;

    return array(
        'limit' => $limit,
        'used' => $used,
        'reached' => ($limit !== null && $used >= $limit),
    );
}

function vx_docker_textarea_from_stored_string($value)
{
    $value = trim((string) $value);
    if ($value === '') {
        return '';
    }

    return str_replace('||', "\n", $value);
}

function vx_docker_form_defaults($container = array())
{
    return array(
        'v_container_name' => isset($container['NAME']) ? $container['NAME'] : '',
        'v_container_image' => isset($container['IMAGE']) ? $container['IMAGE'] : '',
        'v_container_command' => isset($container['COMMAND']) ? $container['COMMAND'] : '',
        'v_container_env' => vx_docker_textarea_from_stored_string(isset($container['ENV']) ? $container['ENV'] : ''),
        'v_container_mounts' => vx_docker_textarea_from_stored_string(isset($container['MOUNTS']) ? $container['MOUNTS'] : ''),
        'v_container_port' => isset($container['CONTAINER_PORT']) ? $container['CONTAINER_PORT'] : '',
        'v_route_domain' => isset($container['DOMAIN']) ? $container['DOMAIN'] : '',
        'v_route_path' => isset($container['ROUTE_PATH']) ? $container['ROUTE_PATH'] : '',
        'v_auto_start' => isset($container['AUTO_START']) ? $container['AUTO_START'] : 'yes',
        'v_restart_policy' => isset($container['RESTART_POLICY']) ? $container['RESTART_POLICY'] : 'unless-stopped',
        'v_healthcheck_type' => isset($container['HEALTHCHECK_TYPE']) ? $container['HEALTHCHECK_TYPE'] : 'http',
        'v_healthcheck_target' => isset($container['HEALTHCHECK_TARGET']) ? $container['HEALTHCHECK_TARGET'] : '',
        'v_healthcheck_interval' => isset($container['HEALTHCHECK_INTERVAL']) ? $container['HEALTHCHECK_INTERVAL'] : '60',
        'v_cpu_alert_pct' => isset($container['CPU_ALERT_PCT']) ? $container['CPU_ALERT_PCT'] : '85',
        'v_mem_alert_mb' => isset($container['MEM_ALERT_MB']) ? $container['MEM_ALERT_MB'] : '1024',
        'v_net_alert_mbps' => isset($container['NET_ALERT_MBPS']) ? $container['NET_ALERT_MBPS'] : '50',
        'v_alert_email' => isset($container['ALERT_EMAIL']) ? $container['ALERT_EMAIL'] : 'yes',
    );
}

function vx_docker_alerts_file($owner)
{
    return '/usr/local/vesta/data/users/'.$owner.'/docker-alerts.conf';
}

function vx_docker_alerts_lock_file($owner)
{
    return vx_docker_alerts_file($owner).'.lock';
}

function vx_docker_parse_alert_record($line)
{
    $record = array();
    if (preg_match_all("/([A-Z_]+)='([^']*)'/", $line, $matches, PREG_SET_ORDER)) {
        foreach ($matches as $match) {
            $record[$match[1]] = $match[2];
        }
    }

    return $record;
}

function vx_docker_list_alerts_for_owner($owner)
{
    $path = vx_docker_alerts_file($owner);
    if (!file_exists($path)) {
        return array();
    }

    $lines = file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!is_array($lines)) {
        return array();
    }

    $alerts = array();
    foreach ($lines as $line) {
        $alert = vx_docker_parse_alert_record($line);
        if (!empty($alert)) {
            $alerts[] = $alert;
        }
    }

    usort($alerts, function ($left, $right) {
        $left_seen = isset($left['LAST_SEEN']) ? $left['LAST_SEEN'] : '';
        $right_seen = isset($right['LAST_SEEN']) ? $right['LAST_SEEN'] : '';
        return strcmp($right_seen, $left_seen);
    });

    return $alerts;
}

function vx_docker_list_alerts_for_scope($owner = '')
{
    $alerts = array();

    if ($owner !== '') {
        return vx_docker_list_alerts_for_owner($owner);
    }

    foreach (vx_docker_list_managed_container_owners() as $user_name) {
        $alerts = array_merge($alerts, vx_docker_list_alerts_for_owner($user_name));
    }

    usort($alerts, function ($left, $right) {
        $left_seen = isset($left['LAST_SEEN']) ? $left['LAST_SEEN'] : '';
        $right_seen = isset($right['LAST_SEEN']) ? $right['LAST_SEEN'] : '';
        return strcmp($right_seen, $left_seen);
    });

    return $alerts;
}

function vx_docker_list_managed_container_owners()
{
    $owners = array();

    foreach (array_keys(vx_docker_list_users()) as $user_name) {
        if (vx_docker_metadata_exists($user_name)) {
            $owners[] = $user_name;
        }
    }

    return $owners;
}

function vx_docker_acknowledge_alert_record($owner, $aid)
{
    $path = vx_docker_alerts_file($owner);
    if (!file_exists($path)) {
        return false;
    }

    $lock_path = vx_docker_alerts_lock_file($owner);
    if (@file_put_contents($lock_path, '', FILE_APPEND) === false) {
        return false;
    }

    $handle = fopen($lock_path, 'c+');
    if ($handle === false) {
        return false;
    }

    if (!flock($handle, LOCK_EX)) {
        fclose($handle);
        return false;
    }

    $contents = @file_get_contents($path);
    $lines = preg_split("/\r?\n/", (string) $contents);
    if (!is_array($lines)) {
        flock($handle, LOCK_UN);
        fclose($handle);
        return false;
    }

    $updated = false;
    foreach ($lines as $index => $line) {
        if ($line === '') {
            continue;
        }

        $record = vx_docker_parse_alert_record($line);
        if (!empty($record['AID']) && (string) $record['AID'] === (string) $aid) {
            $lines[$index] = preg_replace("/ACK='[^']*'/", "ACK='yes'", $line, 1, $count);
            if ($count === 0) {
                $lines[$index] = rtrim($line)." ACK='yes'";
            }
            $updated = true;
            break;
        }
    }

    if (!$updated) {
        flock($handle, LOCK_UN);
        fclose($handle);
        return false;
    }

    $tmp_path = $path.'.tmp.'.getmypid().'.'.uniqid('', true);
    $payload = implode("\n", array_filter($lines, 'strlen'))."\n";
    if (file_put_contents($tmp_path, $payload, LOCK_EX) === false || !rename($tmp_path, $path)) {
        @unlink($tmp_path);
        flock($handle, LOCK_UN);
        fclose($handle);
        return false;
    }

    flock($handle, LOCK_UN);
    fclose($handle);
    return true;
}

function vx_docker_stats_payload($owner, $name, $period = '5m')
{
    $periods = array('5m', '1h', '1d', '7d');
    if (!in_array($period, $periods, true)) {
        $period = '5m';
    }

    $fallback = array(
        'OWNER' => $owner,
        'NAME' => $name,
        'PERIOD' => $period,
        'CPU_PCT' => array(),
        'MEM_MB' => array(),
        'RX_MBPS' => array(),
        'TX_MBPS' => array(),
        'LATEST' => array(
            'CPU_PCT' => null,
            'MEM_MB' => null,
            'RX_MBPS' => null,
            'TX_MBPS' => null,
        ),
    );

    $output = array();
    $return_var = 0;
    exec(
        VESTA_CMD."v-list-docker-container-stats "
        .escapeshellarg($owner)." "
        .escapeshellarg($name)." "
        .escapeshellarg($period)." json",
        $output,
        $return_var
    );

    if ($return_var !== 0) {
        return $fallback;
    }

    $payload = json_decode(implode('', $output), true);
    if (!is_array($payload)) {
        return $fallback;
    }

    return $payload;
}

function vx_docker_health_payload($container)
{
    return array(
        'OWNER' => isset($container['OWNER']) ? $container['OWNER'] : '',
        'NAME' => isset($container['NAME']) ? $container['NAME'] : '',
        'STATUS' => isset($container['STATUS']) ? $container['STATUS'] : '',
        'HEALTH_STATUS' => isset($container['HEALTH_STATUS']) && $container['HEALTH_STATUS'] !== '' ? $container['HEALTH_STATUS'] : 'unknown',
        'LAST_HEALTH_AT' => isset($container['LAST_HEALTH_AT']) ? $container['LAST_HEALTH_AT'] : '',
    );
}
