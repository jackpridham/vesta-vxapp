<?php

function vx_harbor_panel_command_json($command, $arguments = array())
{
    $parts = array(VESTA_CMD.$command);
    foreach ($arguments as $argument) {
        $parts[] = escapeshellarg((string) $argument);
    }
    $output = array();
    $status = 0;
    exec(implode(' ', $parts), $output, $status);
    if ($status !== 0 || strlen(implode('', $output)) > 1048576) {
        return array();
    }
    $value = json_decode(implode('', $output), true);
    return is_array($value) ? $value : array();
}

function vx_harbor_admin_panel_status()
{
    $status = vx_harbor_panel_command_json('v-list-harbor-registry', array('json'));
    $allowed = array('MODE', 'HEALTH', 'CERTIFICATE_STATE', 'BACKUP_AGE_SECONDS', 'PENDING_OPERATIONS', 'FAILED_OPERATIONS', 'STORAGE_USED_BYTES', 'STORAGE_TOTAL_BYTES');
    return array_intersect_key($status, array_flip($allowed));
}

function vx_harbor_tenant_panel_status($owner, $project)
{
    if (!preg_match('/^[a-z0-9][a-z0-9_-]{0,31}$/', $owner)
        || !preg_match('/^[a-z0-9][a-z0-9-]{0,62}$/', $project)) {
        return array();
    }
    $status = vx_harbor_panel_command_json('v-list-user-harbor-registry', array($owner, $project, 'json'));
    $allowed = array('MANAGED', 'STATE', 'REGISTRY', 'NAMESPACE', 'QUOTA_MB', 'USED_MB', 'HEALTH', 'FRESHNESS', 'PUBLISHER_ENABLED');
    return array_intersect_key($status, array_flip($allowed));
}

define('VX_COMPOSE_PACKAGE_MAX_VALUE', '2147483647');

function vx_compose_package_fields()
{
    return array(
        'DOCKER_PROJECTS',
        'DOCKER_SERVICES',
        'DOCKER_CPUS',
        'DOCKER_MEMORY_MB',
        'DOCKER_PIDS',
        'DOCKER_STORAGE_MB',
        'DOCKER_REGISTRY_MB',
        'DOCKER_PORTS',
        'DOCKER_SECRETS',
        'DOCKER_VOLUMES',
    );
}

function vx_compose_package_integer_normalize($value)
{
    if (strlen($value) > strlen(VX_COMPOSE_PACKAGE_MAX_VALUE)
        || preg_match('/^[0-9]+$/', $value) !== 1) {
        return false;
    }

    $normalized = ltrim($value, '0');
    if ($normalized === '') {
        $normalized = '0';
    }
    $maximum = VX_COMPOSE_PACKAGE_MAX_VALUE;
    if (strlen($normalized) > strlen($maximum)
        || (strlen($normalized) === strlen($maximum)
            && strcmp($normalized, $maximum) > 0)) {
        return false;
    }

    return $normalized;
}

function vx_compose_package_normalize($values)
{
    if (!is_array($values)) {
        return false;
    }

    $normalized = array();
    foreach (vx_compose_package_fields() as $field) {
        if (!array_key_exists($field, $values) || !is_scalar($values[$field])) {
            $value = '0';
        } else {
            $value = trim((string) $values[$field]);
        }

        if ($value !== 'unlimited') {
            if ($field === 'DOCKER_CPUS') {
                if (strlen($value) > strlen(VX_COMPOSE_PACKAGE_MAX_VALUE) + 4
                    || preg_match('/^([0-9]+)(\.[0-9]{1,3})?$/', $value, $parts) !== 1) {
                    return false;
                }
                $integer = vx_compose_package_integer_normalize($parts[1]);
                if ($integer === false) {
                    return false;
                }
                $value = $integer.(isset($parts[2]) ? $parts[2] : '');
            } else {
                $value = vx_compose_package_integer_normalize($value);
                if ($value === false) {
                    return false;
                }
            }
        }
        $normalized[$field] = $value;
    }

    return $normalized;
}

function vx_compose_package_lines($values)
{
    $normalized = vx_compose_package_normalize($values);
    if ($normalized === false) {
        return false;
    }

    $lines = array();
    foreach (vx_compose_package_fields() as $field) {
        $lines[] = $field."='".$normalized[$field]."'";
    }

    return implode("\n", $lines)."\n";
}
