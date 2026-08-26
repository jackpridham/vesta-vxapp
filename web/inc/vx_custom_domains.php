<?php

const VX_CUSTOM_DOMAINS_MAX = 199;

function vx_custom_domains_values($raw)
{
    if ($raw === null || $raw === '') {
        return array();
    }
    if (!is_string($raw) && !is_numeric($raw)) {
        return array();
    }

    $tokens = preg_split('/[\s,]+/', trim((string) $raw), -1, PREG_SPLIT_NO_EMPTY);
    if (!is_array($tokens)) {
        return array();
    }

    $domains = array();
    foreach ($tokens as $token) {
        $domain = strtolower(rtrim(trim($token), '.'));
        if ($domain !== '') {
            $domains[] = $domain;
        }
    }
    return $domains;
}

function vx_custom_domains_normalize($raw)
{
    return implode("\n", vx_custom_domains_values($raw));
}

function vx_custom_domain_is_valid($domain)
{
    if (!is_string($domain) || $domain === '' || strlen($domain) > 253) {
        return false;
    }
    if (strpos($domain, '.') === false || strpos($domain, '..') !== false) {
        return false;
    }
    if (!preg_match('/^[a-z0-9.-]+$/D', $domain)) {
        return false;
    }
    if (filter_var($domain, FILTER_VALIDATE_IP) !== false) {
        return false;
    }

    $labels = explode('.', $domain);
    $last_label = end($labels);
    if (!preg_match('/[a-z]/D', $last_label)) {
        return false;
    }
    foreach ($labels as $label) {
        if (strlen($label) < 1 || strlen($label) > 63) {
            return false;
        }
        if (!preg_match('/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/D', $label)) {
            return false;
        }
    }
    return true;
}

function vx_custom_domains_validate($raw, $primary_domain = '', &$error_message = null)
{
    $error_message = '';
    if ($raw !== null && !is_string($raw) && !is_numeric($raw)) {
        $error_message = 'Invalid custom domain data.';
        return false;
    }

    $domains = vx_custom_domains_values($raw);
    if (count($domains) > VX_CUSTOM_DOMAINS_MAX) {
        $error_message = 'A website can have at most 199 custom domains.';
        return false;
    }

    $primary_domain = strtolower(rtrim(trim((string) $primary_domain), '.'));
    $seen = array();
    foreach ($domains as $domain) {
        if (!vx_custom_domain_is_valid($domain)) {
            $error_message = 'Enter a valid custom domain, such as example.com.';
            return false;
        }
        if ($primary_domain !== '' && $domain === $primary_domain) {
            $error_message = 'The primary domain cannot also be a custom domain.';
            return false;
        }
        if (isset($seen[$domain])) {
            $error_message = 'Each custom domain can only be added once.';
            return false;
        }
        $seen[$domain] = true;
    }
    return true;
}

function vx_custom_domains_escape($value)
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function vx_custom_domains_render($raw, $primary_domain = '')
{
    static $assets_rendered = false;

    $domains = vx_custom_domains_values($raw);
    if (empty($domains)) {
        $domains = array('');
    }
    $domain_count = count($domains);
    $serialized = implode("\n", array_filter($domains, 'strlen'));
    $primary_domain = strtolower(rtrim(trim((string) $primary_domain), '.'));

    if (!$assets_rendered) {
        $assets_rendered = true;
        ?>
        <style>
            .vx-custom-domains { width: 458px; max-width: 100%; }
            .vx-custom-domains__row { display: flex; align-items: flex-start; margin: 0 0 8px; width: 100%; }
            .vx-custom-domains__input.vst-input { box-sizing: border-box; flex: 1 1 auto; height: 45px; margin: 0; min-width: 0; width: auto; }
            .vx-custom-domains__button { border: 0; border-radius: 50%; color: #fff; flex: 0 0 38px; font-size: 14px; height: 38px; line-height: 38px; margin: 3px 0 0 8px; padding: 0; text-align: center; }
            .vx-custom-domains__button--add { background: #23b7e5; }
            .vx-custom-domains__button--add:hover, .vx-custom-domains__button--add:focus { background: #19a9d5; }
            .vx-custom-domains__button--remove { background: #f05050; }
            .vx-custom-domains__button--remove:hover, .vx-custom-domains__button--remove:focus { background: #e13c3c; }
            .vx-custom-domains__button[hidden] { display: none; }
            .vx-custom-domains__input.is-invalid { border-color: #f05050; }
            .vx-custom-domains__error { color: #f05050; display: none; font-size: 12px; margin: 2px 0 8px; }
            .vx-custom-domains__error.is-visible { display: block; }
            .vx-custom-domains__serialized { display: none; }
        </style>
        <script defer src="/js/vx-custom-domains.js?<?=vx_custom_domains_escape(JS_LATEST_UPDATE)?>"></script>
        <?php
    }
    ?>
    <div class="vx-custom-domains"
         data-vx-custom-domains
         data-primary-domain="<?=vx_custom_domains_escape($primary_domain)?>"
         data-max-domains="<?=VX_CUSTOM_DOMAINS_MAX?>"
         data-invalid-message="<?=vx_custom_domains_escape(__('Enter a valid custom domain, such as example.com.'))?>"
         data-duplicate-message="<?=vx_custom_domains_escape(__('Each custom domain can only be added once.'))?>"
         data-empty-message="<?=vx_custom_domains_escape(__('Enter a domain or remove this field.'))?>"
         data-primary-message="<?=vx_custom_domains_escape(__('The primary domain cannot also be a custom domain.'))?>"
         data-limit-message="<?=vx_custom_domains_escape(__('A website can have at most 199 custom domains.'))?>">
        <div class="vx-custom-domains__rows" data-vx-custom-domain-rows>
            <?php foreach ($domains as $domain_index => $domain) { ?>
                <div class="vx-custom-domains__row" data-vx-custom-domain-row>
                    <input type="text"
                           class="vst-input vx-custom-domains__input"
                           data-vx-custom-domain-input
                           value="<?=vx_custom_domains_escape($domain)?>"
                           placeholder="example.com"
                           maxlength="253"
                           inputmode="url"
                           autocomplete="off"
                           autocapitalize="none"
                           spellcheck="false"
                           aria-label="<?=vx_custom_domains_escape(__('Custom domain'))?>">
                    <button type="button" class="vx-custom-domains__button vx-custom-domains__button--remove" data-vx-custom-domain-remove aria-label="<?=vx_custom_domains_escape(__('Remove custom domain'))?>"<?php if ($domain_count === 1 && $domain === '') { ?> hidden<?php } ?>>
                        <i class="fas fa-minus" aria-hidden="true"></i>
                    </button>
                    <button type="button" class="vx-custom-domains__button vx-custom-domains__button--add" data-vx-custom-domain-add aria-label="<?=vx_custom_domains_escape(__('Add another custom domain'))?>"<?php if ($domain_index !== $domain_count - 1 || $domain_count >= VX_CUSTOM_DOMAINS_MAX) { ?> hidden<?php } ?>>
                        <i class="fas fa-plus" aria-hidden="true"></i>
                    </button>
                </div>
            <?php } ?>
        </div>
        <div class="vx-custom-domains__error" data-vx-custom-domain-error role="alert" aria-live="polite"></div>
        <textarea class="vx-custom-domains__serialized" name="v_aliases" id="v_aliases" tabindex="-1" aria-hidden="true"><?=vx_custom_domains_escape($serialized)?></textarea>
    </div>
    <?php
}
