<?php
  $back = !empty($_SESSION['back']) ? "location.href='".$_SESSION['back']."'" : "location.href='/list/docker/'";
  $docker_status_value = isset($docker_details_container['STATUS']) && $docker_details_container['STATUS'] !== '' ? $docker_details_container['STATUS'] : 'unknown';
  $docker_health_value = isset($docker_details_container['HEALTH_STATUS']) && $docker_details_container['HEALTH_STATUS'] !== '' ? $docker_details_container['HEALTH_STATUS'] : 'unknown';
?>
    <script>
      window.DOCKER_EDIT = {
        token: '<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>',
        owner: '<?=htmlspecialchars($docker_form_owner, ENT_QUOTES)?>',
        name: '<?=htmlspecialchars($docker_container_name, ENT_QUOTES)?>',
        statsUrl: '/ajax/docker/actions/stats.php',
        healthUrl: '/ajax/docker/actions/health.php',
        alertsUrl: '/ajax/docker/actions/alerts.php',
        acknowledgeUrl: '/ajax/docker/actions/acknowledge_alert.php',
        pollIntervalMs: 30000
      };
    </script>

    <div class="docker-shell docker-shell--form">
      <section class="docker-hero docker-hero--compact">
        <div>
          <div class="docker-eyebrow"><?=__('Docker setup')?></div>
          <h1 class="docker-page-title"><?=__('Editing Docker Container')?></h1>
          <p class="docker-page-copy"><?=__('Tune the running container, verify health telemetry, and manage alert policy from the same page.')?></p>
        </div>
        <div class="docker-badge-group">
          <span class="docker-status-badge" data-status="<?=htmlspecialchars($docker_status_value, ENT_QUOTES)?>"><?=htmlentities($docker_status_value)?></span>
          <span class="docker-health-badge" data-health-state="<?=htmlspecialchars($docker_health_value, ENT_QUOTES)?>"><?=htmlentities($docker_health_value)?></span>
        </div>
      </section>

      <div id="docker-form-errors" class="docker-form-errors">
        <?php if (!empty($_SESSION['error_msg'])) { ?>
        <span class="vst-error"><?=htmlentities($_SESSION['error_msg'])?></span>
        <?php } ?>
      </div>

      <?php if ($docker_spawn_hash !== '') { ?>
      <section id="docker-simple-spawn-output" class="docker-form-card docker-form-card--wide">
        <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Simple Compose project update started')?></h2></div>
        <textarea disabled id="confirm-div-content-textarea-variable" class="vst-textinput ajax-newline" style="width:100%;height:420px;font-family:monospace;"></textarea>
        <script>
          startWatchingSpawnedAjaxProcess(
            '<?=htmlspecialchars($user, ENT_QUOTES)?>',
            '<?=htmlspecialchars($docker_spawn_hash, ENT_QUOTES)?>'
          );
        </script>
      </section>
      <?php } else { ?>
      <form id="docker-edit-form" method="post" name="v_edit_docker" class="docker-form <?=htmlentities($docker_status_value)?>">
        <input type="hidden" name="token" value="<?=$_SESSION['token']?>" />
        <input type="hidden" name="save" value="save" />

        <div class="docker-form-grid">
          <section class="docker-form-card docker-form-card--wide">
            <div class="docker-panel__header">
              <div>
                <div class="docker-eyebrow"><?=__('Overview')?></div>
                <h2 class="docker-panel__title"><?=__('Container state')?></h2>
              </div>
            </div>
            <div class="docker-metric-grid docker-metric-grid--compact">
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Owner')?></span><b class="docker-metric-card__value"><?=htmlentities($docker_form_owner)?></b></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Container')?></span><b class="docker-metric-card__value"><?=htmlentities($docker_form_values['v_container_name'])?></b></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Created')?></span><b class="docker-metric-card__value"><?=htmlentities(isset($docker_details_container['CREATED']) ? $docker_details_container['CREATED'] : __('No data'))?></b></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Updated')?></span><b class="docker-metric-card__value"><?=htmlentities(isset($docker_details_container['UPDATED']) ? $docker_details_container['UPDATED'] : __('No data'))?></b></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Proxy target')?></span><b id="docker-detail-proxy-target" class="docker-metric-card__value docker-mono"><?=htmlentities(isset($docker_details_container['PROXY_TARGET']) && $docker_details_container['PROXY_TARGET'] !== '' ? $docker_details_container['PROXY_TARGET'] : __('No data'))?></b></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Last health update')?></span><b id="docker-detail-health-updated" class="docker-metric-card__value"><?=htmlentities(isset($docker_details_container['LAST_HEALTH_AT']) && $docker_details_container['LAST_HEALTH_AT'] !== '' ? $docker_details_container['LAST_HEALTH_AT'] : __('No data'))?></b></article>
            </div>
          </section>

          <section class="docker-form-card">
            <div class="docker-panel__header">
              <div>
                <div class="docker-eyebrow"><?=__('Container')?></div>
                <h2 class="docker-panel__title"><?=__('Runtime basics')?></h2>
              </div>
            </div>
            <div class="docker-field-grid">
              <div class="docker-field">
                <label class="docker-field-label"><?=__('Owner')?></label>
                <input type="text" class="vst-input" value="<?=htmlentities($docker_form_owner)?>" disabled>
              </div>
              <div class="docker-field">
                <label class="docker-field-label"><?=__('Container Name')?></label>
                <input type="text" class="vst-input" value="<?=htmlentities($docker_form_values['v_container_name'])?>" disabled>
                <input type="hidden" name="v_container_name" value="<?=htmlentities($docker_form_values['v_container_name'])?>">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-edit-image"><?=__('Image')?></label>
                <input id="docker-edit-image" type="text" class="vst-input" name="v_container_image" value="<?=htmlentities($docker_form_values['v_container_image'])?>">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-edit-command"><?=__('Command')?> <span class="optional">(<?=__('optional')?>)</span></label>
                <input id="docker-edit-command" type="text" class="vst-input" name="v_container_command" value="<?=htmlentities($docker_form_values['v_container_command'])?>">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-edit-env"><?=__('Environment Variables')?></label>
                <textarea id="docker-edit-env" class="vst-textinput" name="v_container_env"><?=htmlentities($docker_form_values['v_container_env'])?></textarea>
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-edit-mounts"><?=__('Bind Mounts')?></label>
                <textarea id="docker-edit-mounts" class="vst-textinput" name="v_container_mounts"><?=htmlentities($docker_form_values['v_container_mounts'])?></textarea>
              </div>
            </div>
          </section>

          <section class="docker-form-card">
            <div class="docker-panel__header">
              <div>
                <div class="docker-eyebrow"><?=__('Routing')?></div>
                <h2 class="docker-panel__title"><?=__('Ingress and startup')?></h2>
              </div>
            </div>
            <div class="docker-field-grid">
              <div class="docker-field">
                <label class="docker-field-label" for="docker-edit-port"><?=__('Container Port')?></label>
                <input id="docker-edit-port" type="text" class="vst-input" name="v_container_port" value="<?=htmlentities($docker_form_values['v_container_port'])?>">
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-edit-restart-policy"><?=__('Restart Policy')?></label>
                <select id="docker-edit-restart-policy" class="vst-list docker-select" name="v_restart_policy">
                  <?php foreach (array('unless-stopped', 'always', 'on-failure', 'no') as $docker_restart_policy) { ?>
                  <option value="<?=$docker_restart_policy?>" <?php if ($docker_form_values['v_restart_policy'] === $docker_restart_policy) echo 'selected'; ?>><?=$docker_restart_policy?></option>
                  <?php } ?>
                </select>
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-edit-route-domain"><?=__('Route Domain')?></label>
                <select id="docker-edit-route-domain" class="vst-list docker-select" name="v_route_domain">
                  <option value=""><?=__('Do not attach a domain')?></option>
                  <?php foreach ($docker_route_domains as $docker_domain_option) { ?>
                  <option value="<?=htmlentities($docker_domain_option['value'])?>" <?php if ($docker_form_values['v_route_domain'] === $docker_domain_option['value']) echo 'selected'; ?>><?=htmlentities($docker_domain_option['label'])?></option>
                  <?php } ?>
                </select>
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-edit-route-path"><?=__('Route Path')?> <span class="optional">(<?=__('optional')?>)</span></label>
                <input id="docker-edit-route-path" type="text" class="vst-input" name="v_route_path" value="<?=htmlentities($docker_form_values['v_route_path'])?>" placeholder="/">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-check"><input type="checkbox" class="vst-checkbox" name="v_auto_start" value="yes" <?php if ($docker_form_values['v_auto_start'] === 'yes') echo 'checked=yes'; ?>> <?=__('Auto Start')?></label>
              </div>
            </div>
          </section>

          <section id="docker-live-metrics" class="docker-form-card docker-form-card--wide">
            <div class="docker-panel__header">
              <div>
                <div class="docker-eyebrow"><?=__('Monitoring')?></div>
                <h2 class="docker-panel__title"><?=__('Live Metrics')?></h2>
              </div>
            </div>
            <div class="docker-metric-grid">
              <article class="docker-metric-card"><span class="docker-metric-card__label">CPU</span><div id="docker-chart-cpu" class="docker-chart"><?=__('No metrics available yet.')?></div></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Memory')?></span><div id="docker-chart-mem" class="docker-chart"><?=__('No metrics available yet.')?></div></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label">RX</span><div id="docker-chart-rx" class="docker-chart"><?=__('No metrics available yet.')?></div></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label">TX</span><div id="docker-chart-tx" class="docker-chart"><?=__('No metrics available yet.')?></div></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Status')?></span><b id="docker-detail-status" class="docker-metric-card__value"><?=htmlentities(isset($docker_details_container['STATUS']) ? $docker_details_container['STATUS'] : __('No data'))?></b></article>
              <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Health status')?></span><b id="docker-detail-health-status" class="docker-metric-card__value docker-health-badge" data-health-state="<?=htmlspecialchars($docker_health_value, ENT_QUOTES)?>"><?=htmlentities(isset($docker_details_container['HEALTH_STATUS']) ? $docker_details_container['HEALTH_STATUS'] : __('No data'))?></b></article>
            </div>
          </section>

          <section id="docker-health-settings" class="docker-form-card">
            <div class="docker-panel__header">
              <div>
                <div class="docker-eyebrow"><?=__('Health')?></div>
                <h2 class="docker-panel__title"><?=__('Health Settings')?></h2>
              </div>
            </div>
            <div class="docker-field-grid">
              <div class="docker-field">
                <label class="docker-field-label" for="docker-edit-healthcheck-type"><?=__('Health Check Type')?></label>
                <select id="docker-edit-healthcheck-type" class="vst-list docker-select" name="v_healthcheck_type">
                  <?php foreach (array('http', 'tcp', 'docker', 'none') as $docker_health_type) { ?>
                  <option value="<?=$docker_health_type?>" <?php if ($docker_form_values['v_healthcheck_type'] === $docker_health_type) echo 'selected'; ?>><?=$docker_health_type?></option>
                  <?php } ?>
                </select>
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-edit-healthcheck-interval"><?=__('Health Check Interval')?></label>
                <input id="docker-edit-healthcheck-interval" type="text" class="vst-input" name="v_healthcheck_interval" value="<?=htmlentities($docker_form_values['v_healthcheck_interval'])?>">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-edit-healthcheck-target"><?=__('Health Check Target / Path')?></label>
                <input id="docker-edit-healthcheck-target" type="text" class="vst-input" name="v_healthcheck_target" value="<?=htmlentities($docker_form_values['v_healthcheck_target'])?>">
              </div>
            </div>
          </section>

          <section id="docker-alert-thresholds" class="docker-form-card">
            <div class="docker-panel__header">
              <div>
                <div class="docker-eyebrow"><?=__('Alerting')?></div>
                <h2 class="docker-panel__title"><?=__('Alert Thresholds')?></h2>
              </div>
            </div>
            <div class="docker-field-grid">
              <div class="docker-field">
                <label class="docker-field-label" for="docker-edit-cpu-alert"><?=__('CPU Alert Percent')?></label>
                <input id="docker-edit-cpu-alert" type="text" class="vst-input" name="v_cpu_alert_pct" value="<?=htmlentities($docker_form_values['v_cpu_alert_pct'])?>">
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-edit-mem-alert"><?=__('Memory Alert MB')?></label>
                <input id="docker-edit-mem-alert" type="text" class="vst-input" name="v_mem_alert_mb" value="<?=htmlentities($docker_form_values['v_mem_alert_mb'])?>">
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-edit-net-alert"><?=__('Network Alert MB/s')?></label>
                <input id="docker-edit-net-alert" type="text" class="vst-input" name="v_net_alert_mbps" value="<?=htmlentities($docker_form_values['v_net_alert_mbps'])?>">
              </div>
              <div class="docker-field">
                <label class="docker-check"><input type="checkbox" class="vst-checkbox" name="v_alert_email" value="yes" <?php if ($docker_form_values['v_alert_email'] === 'yes') echo 'checked=yes'; ?>> <?=__('Enable alert delivery')?></label>
              </div>
            </div>
          </section>

          <section id="docker-alerts-panel" class="docker-form-card docker-form-card--wide">
            <div class="docker-panel__header">
              <div>
                <div class="docker-eyebrow"><?=__('Alerts')?></div>
                <h2 class="docker-panel__title"><?=__('Docker Alerts')?></h2>
              </div>
            </div>
            <div class="docker-alerts-list"><div class="docker-alerts-empty"><?=__('No Docker alerts are active for this container.')?></div></div>
            <div class="docker-alert-actions">
              <button id="docker-alert-acknowledge" class="button docker-button docker-button--secondary" style="display:none;"><?=__('Acknowledge alert')?></button>
            </div>
          </section>
        </div>

        <div class="docker-form-actions">
          <input type="submit" class="button docker-button docker-button--primary" name="save" value="<?=__('Save')?>">
          <input type="button" class="button cancel docker-button docker-button--secondary" value="<?=__('Back')?>" onclick="<?=$back?>">
        </div>
      </form>
      <?php } ?>
    </div>
