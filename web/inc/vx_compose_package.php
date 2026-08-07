<?php

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
