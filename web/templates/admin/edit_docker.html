<?php
  $docker_edit_query = ($_SESSION['user'] === 'admin') ? '&user='.urlencode($docker_form_owner) : '';
  $back = !empty($_SESSION['back']) ? "location.href='".$_SESSION['back']."'" : "location.href='/list/docker/'";
?>
    <div class="l-center edit">
      <div class="l-sort clearfix">
        <div class="l-sort-toolbar clearfix float-left">
          <span class="title edit"><b><?=__('Editing Docker Container')?></b></span>
        </div>
      </div>
    </div>

    <div class="l-separator"></div>

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

    <div class="l-center">
      <div id="docker-form-errors">
        <?php if (!empty($_SESSION['error_msg'])) { ?>
        <span class="vst-error"><?=htmlentities($_SESSION['error_msg'])?></span>
        <?php } ?>
      </div>

      <div id="docker-edit-form">
        <form id="vstobjects" method="post" name="v_edit_docker" class="<?=htmlentities(isset($docker_details_container['STATUS']) ? $docker_details_container['STATUS'] : '')?>">
          <input type="hidden" name="token" value="<?=$_SESSION['token']?>" />
          <input type="hidden" name="save" value="save" />

          <table class="data">
            <tr class="data-add">
              <td class="data-dotted">
                <table class="data-col1">
                  <tr>
                    <td>
                      <a class="data-date"><?=htmlentities(isset($docker_details_container['CREATED']) ? $docker_details_container['CREATED'] : '')?></a><br>
                      <a class="data-date"><?=htmlentities(isset($docker_details_container['UPDATED']) ? $docker_details_container['UPDATED'] : '')?></a>
                    </td>
                  </tr>
                  <tr><td class="data-active"><b><?=htmlentities(isset($docker_details_container['STATUS']) ? $docker_details_container['STATUS'] : '')?></b></td></tr>
                </table>
              </td>
              <td class="data-dotted">
                <table class="data-col2">
                  <tr><td class="vst-text step-top"><?=__('Owner')?></td></tr>
                  <tr><td><input type="text" size="20" class="vst-input" value="<?=htmlentities($docker_form_owner)?>" disabled></td></tr>
                  <tr><td class="vst-text input-label"><?=__('Container Name')?></td></tr>
                  <tr>
                    <td>
                      <input type="text" size="20" class="vst-input" value="<?=htmlentities($docker_form_values['v_container_name'])?>" disabled>
                      <input type="hidden" name="v_container_name" value="<?=htmlentities($docker_form_values['v_container_name'])?>">
                    </td>
                  </tr>
                  <tr><td class="vst-text input-label"><?=__('Image')?></td></tr>
                  <tr><td><input type="text" size="20" class="vst-input" name="v_container_image" value="<?=htmlentities($docker_form_values['v_container_image'])?>"></td></tr>
                  <tr><td class="vst-text input-label"><?=__('Command')?> <span class="optional">(<?=__('optional')?>)</span></td></tr>
                  <tr><td><input type="text" size="20" class="vst-input" name="v_container_command" value="<?=htmlentities($docker_form_values['v_container_command'])?>"></td></tr>
                  <tr><td class="vst-text input-label"><?=__('Environment Variables')?></td></tr>
                  <tr><td><textarea class="vst-textinput" name="v_container_env"><?=htmlentities($docker_form_values['v_container_env'])?></textarea></td></tr>
                  <tr><td class="vst-text input-label"><?=__('Bind Mounts')?></td></tr>
                  <tr><td><textarea class="vst-textinput" name="v_container_mounts"><?=htmlentities($docker_form_values['v_container_mounts'])?></textarea></td></tr>
                  <tr><td class="vst-text input-label"><?=__('Container Port')?></td></tr>
                  <tr><td><input type="text" size="20" class="vst-input" name="v_container_port" value="<?=htmlentities($docker_form_values['v_container_port'])?>"></td></tr>
                  <tr><td class="vst-text input-label"><?=__('Route Domain')?></td></tr>
                  <tr>
                    <td>
                      <select class="vst-list" name="v_route_domain">
                        <option value=""><?=__('Do not attach a domain')?></option>
                        <?php foreach ($docker_route_domains as $docker_domain_option) { ?>
                        <option value="<?=htmlentities($docker_domain_option['value'])?>" <?php if ($docker_form_values['v_route_domain'] === $docker_domain_option['value']) echo 'selected'; ?>><?=htmlentities($docker_domain_option['label'])?></option>
                        <?php } ?>
                      </select>
                    </td>
                  </tr>
                  <tr><td class="vst-text input-label"><?=__('Route Path')?> <span class="optional">(<?=__('optional')?>)</span></td></tr>
                  <tr><td><input type="text" size="20" class="vst-input" name="v_route_path" value="<?=htmlentities($docker_form_values['v_route_path'])?>" placeholder="/"></td></tr>
                  <tr><td class="vst-text input-label"><?=__('Restart Policy')?></td></tr>
                  <tr>
                    <td>
                      <select class="vst-list" name="v_restart_policy">
                        <?php foreach (array('unless-stopped', 'always', 'on-failure', 'no') as $docker_restart_policy) { ?>
                        <option value="<?=$docker_restart_policy?>" <?php if ($docker_form_values['v_restart_policy'] === $docker_restart_policy) echo 'selected'; ?>><?=$docker_restart_policy?></option>
                        <?php } ?>
                      </select>
                    </td>
                  </tr>
                  <tr><td class="vst-text input-label"><label><input type="checkbox" class="vst-checkbox" name="v_auto_start" value="yes" <?php if ($docker_form_values['v_auto_start'] === 'yes') echo 'checked=yes'; ?>> <?=__('Auto Start')?></label></td></tr>
                </table>

                <section id="docker-live-metrics">
                  <table class="data-col2">
                    <tr><td class="vst-text step-top"><b><?=__('Live Metrics')?></b></td></tr>
                    <tr><td><div id="docker-chart-cpu"><?=__('No metrics available yet.')?></div></td></tr>
                    <tr><td><div id="docker-chart-mem"><?=__('No metrics available yet.')?></div></td></tr>
                    <tr><td><div id="docker-chart-rx"><?=__('No metrics available yet.')?></div></td></tr>
                    <tr><td><div id="docker-chart-tx"><?=__('No metrics available yet.')?></div></td></tr>
                    <tr><td><div id="docker-detail-status"><?=htmlentities(isset($docker_details_container['STATUS']) ? $docker_details_container['STATUS'] : __('No data'))?></div></td></tr>
                    <tr><td><div id="docker-detail-health-status"><?=htmlentities(isset($docker_details_container['HEALTH_STATUS']) ? $docker_details_container['HEALTH_STATUS'] : __('No data'))?></div></td></tr>
                    <tr><td><div id="docker-detail-health-updated"><?=htmlentities(isset($docker_details_container['LAST_HEALTH_AT']) && $docker_details_container['LAST_HEALTH_AT'] !== '' ? $docker_details_container['LAST_HEALTH_AT'] : __('No data'))?></div></td></tr>
                    <tr><td><div id="docker-detail-proxy-target"><?=htmlentities(isset($docker_details_container['PROXY_TARGET']) && $docker_details_container['PROXY_TARGET'] !== '' ? $docker_details_container['PROXY_TARGET'] : __('No data'))?></div></td></tr>
                  </table>
                </section>

                <section id="docker-health-settings">
                  <table class="data-col2">
                    <tr><td class="vst-text step-top"><b><?=__('Health Settings')?></b></td></tr>
                    <tr><td class="vst-text input-label"><?=__('Health Check Type')?></td></tr>
                    <tr>
                      <td>
                        <select class="vst-list" name="v_healthcheck_type">
                          <?php foreach (array('http', 'tcp', 'docker', 'none') as $docker_health_type) { ?>
                          <option value="<?=$docker_health_type?>" <?php if ($docker_form_values['v_healthcheck_type'] === $docker_health_type) echo 'selected'; ?>><?=$docker_health_type?></option>
                          <?php } ?>
                        </select>
                      </td>
                    </tr>
                    <tr><td class="vst-text input-label"><?=__('Health Check Target / Path')?></td></tr>
                    <tr><td><input type="text" size="20" class="vst-input" name="v_healthcheck_target" value="<?=htmlentities($docker_form_values['v_healthcheck_target'])?>"></td></tr>
                    <tr><td class="vst-text input-label"><?=__('Health Check Interval')?></td></tr>
                    <tr><td><input type="text" size="20" class="vst-input" name="v_healthcheck_interval" value="<?=htmlentities($docker_form_values['v_healthcheck_interval'])?>"></td></tr>
                  </table>
                </section>

                <section id="docker-alert-thresholds">
                  <table class="data-col2">
                    <tr><td class="vst-text step-top"><b><?=__('Alert Thresholds')?></b></td></tr>
                    <tr><td class="vst-text input-label"><?=__('CPU Alert Percent')?></td></tr>
                    <tr><td><input type="text" size="20" class="vst-input" name="v_cpu_alert_pct" value="<?=htmlentities($docker_form_values['v_cpu_alert_pct'])?>"></td></tr>
                    <tr><td class="vst-text input-label"><?=__('Memory Alert MB')?></td></tr>
                    <tr><td><input type="text" size="20" class="vst-input" name="v_mem_alert_mb" value="<?=htmlentities($docker_form_values['v_mem_alert_mb'])?>"></td></tr>
                    <tr><td class="vst-text input-label"><?=__('Network Alert MB/s')?></td></tr>
                    <tr><td><input type="text" size="20" class="vst-input" name="v_net_alert_mbps" value="<?=htmlentities($docker_form_values['v_net_alert_mbps'])?>"></td></tr>
                    <tr><td class="vst-text input-label"><label><input type="checkbox" class="vst-checkbox" name="v_alert_email" value="yes" <?php if ($docker_form_values['v_alert_email'] === 'yes') echo 'checked=yes'; ?>> <?=__('Enable alert delivery')?></label></td></tr>
                  </table>
                </section>

                <section id="docker-alerts-panel">
                  <table class="data-col2">
                    <tr><td class="vst-text step-top"><b><?=__('Docker Alerts')?></b></td></tr>
                    <tr><td><div class="docker-alerts-list"><div class="docker-alerts-empty"><?=__('No Docker alerts are active for this container.')?></div></div></td></tr>
                    <tr><td><button id="docker-alert-acknowledge" class="button" style="display:none;"><?=__('Acknowledge alert')?></button></td></tr>
                  </table>
                </section>

                <table class="data-col2">
                  <tr>
                    <td class="step-top" width="116px"><input type="submit" class="button" name="save" value="<?=__('Save')?>"></td>
                    <td class="step-top"><input type="button" class="button cancel" value="<?=__('Back')?>" onclick="<?=$back?>"></td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </form>
      </div>
    </div>
