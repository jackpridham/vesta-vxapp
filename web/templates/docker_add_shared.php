<?php
  $back = !empty($_SESSION['back']) ? "location.href='".$_SESSION['back']."'" : "location.href='/list/docker/'";
?>
    <div class="docker-shell docker-shell--form">
      <section class="docker-hero docker-hero--compact">
        <div>
          <div class="docker-eyebrow"><?=__('Docker setup')?></div>
          <h1 class="docker-page-title"><?=__('Adding Docker Container')?></h1>
          <p class="docker-page-copy"><?=__('Define the image, runtime route, health model, and alert policy in one place.')?></p>
        </div>
      </section>

      <div id="docker-form-errors" class="docker-form-errors">
        <?php if (!empty($_SESSION['error_msg'])) { ?>
        <span class="vst-error"><?=htmlentities($_SESSION['error_msg'])?></span>
        <?php } ?>
      </div>

      <?php if ($docker_spawn_hash !== '') { ?>
      <section id="docker-simple-spawn-output" class="docker-form-card docker-form-card--wide">
        <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Simple Compose project creation started')?></h2></div>
        <textarea disabled id="docker-simple-spawn-output-textarea" class="vst-textinput ajax-newline" style="width:100%;height:420px;font-family:monospace;"></textarea>
        <script>
          document.addEventListener('DOMContentLoaded', function() {
            startWatchingSpawnedAjaxProcess(
              <?=json_encode($user)?>,
              <?=json_encode($docker_spawn_hash)?>,
              '#docker-simple-spawn-output-textarea'
            );
          });
        </script>
      </section>
      <?php } else { ?>
      <form id="docker-create-form" name="v_add_docker" method="post" class="docker-form">
        <input type="hidden" name="token" value="<?=$_SESSION['token']?>" />
        <input type="hidden" name="ok" value="Add" />

        <div class="docker-form-grid">
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
                <label class="docker-field-label" for="docker-container-name"><?=__('Container Name')?></label>
                <input id="docker-container-name" type="text" class="vst-input" name="v_container_name" value="<?=htmlentities($docker_form_values['v_container_name'])?>">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-container-image"><?=__('Image')?></label>
                <input id="docker-container-image" type="text" class="vst-input" name="v_container_image" value="<?=htmlentities($docker_form_values['v_container_image'])?>" placeholder="nginx:stable">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-container-command"><?=__('Command')?> <span class="optional">(<?=__('optional')?>)</span></label>
                <input id="docker-container-command" type="text" class="vst-input" name="v_container_command" value="<?=htmlentities($docker_form_values['v_container_command'])?>">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-container-env"><?=__('Environment Variables')?></label>
                <textarea id="docker-container-env" class="vst-textinput" name="v_container_env"><?=htmlentities($docker_form_values['v_container_env'])?></textarea>
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-container-mounts"><?=__('Bind Mounts')?></label>
                <textarea id="docker-container-mounts" class="vst-textinput" name="v_container_mounts" placeholder="data:/srv/app/data"><?=htmlentities($docker_form_values['v_container_mounts'])?></textarea>
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
                <label class="docker-field-label" for="docker-container-port"><?=__('Container Port')?></label>
                <input id="docker-container-port" type="text" class="vst-input" name="v_container_port" value="<?=htmlentities($docker_form_values['v_container_port'])?>" placeholder="8080">
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-restart-policy"><?=__('Restart Policy')?></label>
                <select id="docker-restart-policy" class="vst-list docker-select" name="v_restart_policy">
                  <?php foreach (array('unless-stopped', 'always', 'on-failure', 'no') as $docker_restart_policy) { ?>
                  <option value="<?=$docker_restart_policy?>" <?php if ($docker_form_values['v_restart_policy'] === $docker_restart_policy) echo 'selected'; ?>><?=$docker_restart_policy?></option>
                  <?php } ?>
                </select>
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-route-domain"><?=__('Route Domain')?></label>
                <select id="docker-route-domain" class="vst-list docker-select" name="v_route_domain">
                  <option value=""><?=__('Do not attach a domain')?></option>
                  <?php foreach ($docker_route_domains as $docker_domain_option) { ?>
                  <option value="<?=htmlentities($docker_domain_option['value'])?>" <?php if ($docker_form_values['v_route_domain'] === $docker_domain_option['value']) echo 'selected'; ?>><?=htmlentities($docker_domain_option['label'])?></option>
                  <?php } ?>
                </select>
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-route-path"><?=__('Route Path')?> <span class="optional">(<?=__('optional')?>)</span></label>
                <input id="docker-route-path" type="text" class="vst-input" name="v_route_path" value="<?=htmlentities($docker_form_values['v_route_path'])?>" placeholder="/">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-check"><input type="checkbox" class="vst-checkbox" name="v_auto_start" value="yes" <?php if ($docker_form_values['v_auto_start'] === 'yes') echo 'checked=yes'; ?>> <?=__('Auto Start')?></label>
              </div>
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
                <label class="docker-field-label" for="docker-healthcheck-type"><?=__('Health Check Type')?></label>
                <select id="docker-healthcheck-type" class="vst-list docker-select" name="v_healthcheck_type">
                  <?php foreach (array('http', 'tcp', 'docker', 'none') as $docker_health_type) { ?>
                  <option value="<?=$docker_health_type?>" <?php if ($docker_form_values['v_healthcheck_type'] === $docker_health_type) echo 'selected'; ?>><?=$docker_health_type?></option>
                  <?php } ?>
                </select>
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-healthcheck-interval"><?=__('Health Check Interval')?></label>
                <input id="docker-healthcheck-interval" type="text" class="vst-input" name="v_healthcheck_interval" value="<?=htmlentities($docker_form_values['v_healthcheck_interval'])?>">
              </div>
              <div class="docker-field docker-field--full">
                <label class="docker-field-label" for="docker-healthcheck-target"><?=__('Health Check Target / Path')?></label>
                <input id="docker-healthcheck-target" type="text" class="vst-input" name="v_healthcheck_target" value="<?=htmlentities($docker_form_values['v_healthcheck_target'])?>" placeholder="http://127.0.0.1:8080/health">
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
                <label class="docker-field-label" for="docker-cpu-alert"><?=__('CPU Alert Percent')?></label>
                <input id="docker-cpu-alert" type="text" class="vst-input" name="v_cpu_alert_pct" value="<?=htmlentities($docker_form_values['v_cpu_alert_pct'])?>">
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-mem-alert"><?=__('Memory Alert MB')?></label>
                <input id="docker-mem-alert" type="text" class="vst-input" name="v_mem_alert_mb" value="<?=htmlentities($docker_form_values['v_mem_alert_mb'])?>">
              </div>
              <div class="docker-field">
                <label class="docker-field-label" for="docker-net-alert"><?=__('Network Alert MB/s')?></label>
                <input id="docker-net-alert" type="text" class="vst-input" name="v_net_alert_mbps" value="<?=htmlentities($docker_form_values['v_net_alert_mbps'])?>">
              </div>
              <div class="docker-field">
                <label class="docker-check"><input type="checkbox" class="vst-checkbox" name="v_alert_email" value="yes" <?php if ($docker_form_values['v_alert_email'] === 'yes') echo 'checked=yes'; ?>> <?=__('Enable alert delivery')?></label>
              </div>
            </div>
          </section>
        </div>

        <div class="docker-form-actions">
          <input type="submit" name="ok" value="<?=__('Add')?>" class="button docker-button docker-button--primary">
          <input type="button" class="button cancel docker-button docker-button--secondary" value="<?=__('Back')?>" onclick="<?=$back?>">
        </div>
      </form>
      <?php } ?>
    </div>
