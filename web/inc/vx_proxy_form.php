<?php

function vx_proxy_post_value($name, $default = '')
{
    return isset($_POST[$name]) ? trim($_POST[$name]) : $default;
}

function vx_proxy_headers_from_post()
{
    $raw = vx_proxy_post_value('v_proxy_headers');
    if ($raw === '') {
        return '';
    }

    $raw = str_replace("\r", "\n", $raw);
    $lines = preg_split('/\n+/', $raw);
    $headers = array();
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line !== '') {
            $headers[] = $line;
        }
    }

    return implode('||', $headers);
}

function vx_proxy_headers_to_text($headers)
{
    return str_replace('||', "\n", $headers);
}

function vx_proxy_long_flags_from_post()
{
    $target = vx_proxy_post_value('v_proxy_target');
    if ($target === '') {
        return '';
    }

    $mode = vx_proxy_post_value('v_proxy_mode', 'proxy');
    $profile = vx_proxy_post_value('v_proxy_profile', 'standard');
    $preserve_host = vx_proxy_post_value('v_proxy_preserve_host', 'yes');
    $timeout = vx_proxy_post_value('v_proxy_timeout', '60');
    $headers = vx_proxy_headers_from_post();

    $flags = " --proxy-target ".escapeshellarg($target);
    $flags .= " --proxy-mode ".escapeshellarg($mode);
    $flags .= " --proxy-profile ".escapeshellarg($profile);
    $flags .= " --proxy-preserve-host ".escapeshellarg($preserve_host);
    $flags .= " --proxy-timeout ".escapeshellarg($timeout);
    if ($headers !== '') {
        foreach (explode('||', $headers) as $header) {
            $flags .= " --header ".escapeshellarg($header);
        }
    }

    return $flags;
}

function vx_proxy_change_args_from_post()
{
    $mode = vx_proxy_post_value('v_proxy_mode', 'proxy');
    $target = vx_proxy_post_value('v_proxy_target');
    $profile = vx_proxy_post_value('v_proxy_profile', 'standard');
    $preserve_host = vx_proxy_post_value('v_proxy_preserve_host', 'yes');
    $timeout = vx_proxy_post_value('v_proxy_timeout', '60');
    $headers = vx_proxy_headers_from_post();

    return escapeshellarg($mode)." ".escapeshellarg($target)." ".escapeshellarg($profile)." ".
        escapeshellarg($preserve_host)." ".escapeshellarg($timeout)." ".escapeshellarg($headers);
}
