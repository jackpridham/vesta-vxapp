<?php

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

        if ($field === 'DOCKER_CPUS') {
            $pattern = '/^(unlimited|[0-9]+(?:\.[0-9]{1,3})?)$/';
        } else {
            $pattern = '/^(unlimited|[0-9]+)$/';
        }
        if (preg_match($pattern, $value) !== 1) {
            return false;
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
