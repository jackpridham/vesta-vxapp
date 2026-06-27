<?php
  $docker_manage_user = $docker_owner !== '' ? $docker_owner : 'admin';
  $docker_query = '';
  if ($_SESSION['user'] === 'admin' && $docker_owner !== '') {
      $docker_query = '?user='.urlencode($docker_owner);
  }
  $docker_add_href = '/add/docker/'.$docker_query;
  $docker_can_add_from_scope = !($_SESSION['user'] === 'admin' && $docker_owner === '');
  $docker_has_containers = !empty($data);
  $docker_primary_state = 'list';
  if (!$docker_available) {
      $docker_primary_state = 'unavailable';
  } elseif (!$docker_has_containers && !empty($docker_quota['reached'])) {
      $docker_primary_state = 'quota';
  } elseif (!$docker_has_containers) {
      $docker_primary_state = 'empty';
  }

  $docker_show_owner_groups = ($_SESSION['user'] === 'admin' && $docker_owner === '' && !empty($docker_grouped_data));
  $docker_render_card = function ($docker_key, $container) use (&$i) {
      ++$i;
      $docker_card_owner = isset($container['OWNER']) ? $container['OWNER'] : '';
      $docker_card_name = isset($container['NAME']) ? $container['NAME'] : $docker_key;
      $docker_card_id = 'docker-card-'.$docker_card_owner.'-'.$docker_card_name;
      $docker_card_status = isset($container['STATUS']) ? $container['STATUS'] : '';
      $docker_health_status = isset($container['HEALTH_STATUS']) && $container['HEALTH_STATUS'] !== '' ? $container['HEALTH_STATUS'] : 'unknown';
      $docker_query_owner = ($_SESSION['user'] === 'admin') ? '&user='.urlencode($docker_card_owner) : '';
      $docker_action = ($docker_card_status === 'running') ? 'stop' : 'start';
?>
          <script>
            dataset_values[<?=$i?>] = {
              url: '/ajax/docker/index.php',
              title: '<?=htmlspecialchars($docker_card_name, ENT_QUOTES)?>',
              container_name: '<?=htmlspecialchars($docker_card_name, ENT_QUOTES)?>',
              owner: '<?=htmlspecialchars($docker_card_owner, ENT_QUOTES)?>'
            };
            window.DOCKER_LIST.containers.push({
              owner: '<?=htmlspecialchars($docker_card_owner, ENT_QUOTES)?>',
              name: '<?=htmlspecialchars($docker_card_name, ENT_QUOTES)?>',
              healthStatus: '<?=htmlspecialchars($docker_health_status, ENT_QUOTES)?>',
              lastHealthAt: '<?=htmlspecialchars(isset($container['LAST_HEALTH_AT']) ? $container['LAST_HEALTH_AT'] : '', ENT_QUOTES)?>'
            });
          </script>
          <article id="<?=htmlspecialchars($docker_card_id, ENT_QUOTES)?>" class="l-unit <?php if ($docker_card_status !== 'running') echo 'l-unit--suspended'; ?>" data-owner="<?=htmlspecialchars($docker_card_owner, ENT_QUOTES)?>" data-name="<?=htmlspecialchars($docker_card_name, ENT_QUOTES)?>">
            <div class="l-unit-toolbar clearfix">
              <div class="l-unit-toolbar__col l-unit-toolbar__col--right noselect">
                <div class="actions-panel clearfix">
                  <div class="actions-panel__col actions-panel__edit shortcut-enter" key-action="href"><a href="/edit/docker/?container=<?=urlencode($docker_card_name)?><?=$docker_query_owner?>"><?=__('edit')?> <i></i></a><span class="shortcut enter">&nbsp;&#8629;</span></div>
                  <div class="actions-panel__col actions-panel__<?=$docker_action?> shortcut-s" key-action="href"><a href="/<?=$docker_action?>/docker/?container=<?=urlencode($docker_card_name)?><?=$docker_query_owner?>&token=<?=$_SESSION['token']?>"><?=__($docker_action)?> <i></i></a><span class="shortcut">&nbsp;S</span></div>
                  <div class="actions-panel__col actions-panel__restart shortcut-r" key-action="href"><a href="/restart/docker/?container=<?=urlencode($docker_card_name)?><?=$docker_query_owner?>&token=<?=$_SESSION['token']?>"><?=__('restart')?> <i></i></a><span class="shortcut">&nbsp;R</span></div>
                  <div class="actions-panel__col actions-panel__delete shortcut-delete" key-action="href"><a href="/delete/docker/?container=<?=urlencode($docker_card_name)?><?=$docker_query_owner?>&token=<?=$_SESSION['token']?>"><?=__('delete')?> <i></i></a><span class="shortcut delete">&nbsp;Del</span></div>
                  <div class="actions-panel__col actions-panel__logs" style="background-color: #cae1e5;"><a href="javascript:void(0)" onclick="more_button_click(<?=$i?>)"><?=__('Docker')?> <i></i></a><span class="shortcut more">&nbsp;&#8629;</span></div>
                </div>
              </div>
            </div>

            <div class="l-unit__col l-unit__col--left clearfix">
              <div class="l-unit__date"><?=htmlspecialchars(isset($container['UPDATED']) ? $container['UPDATED'] : '', ENT_QUOTES)?></div>
              <div class="l-unit__suspended"><?=__('stopped')?></div>
            </div>
            <div class="l-unit__col l-unit__col--right">
              <div class="l-unit__name small-2">
                <?=htmlspecialchars($docker_card_name, ENT_QUOTES)?>
                <span><?=htmlspecialchars(isset($container['IMAGE']) ? $container['IMAGE'] : '', ENT_QUOTES)?></span>
              </div>
              <div class="l-unit__stats">
                <table>
                  <tr>
                    <td>
                      <div class="l-unit__stat-cols clearfix">
                        <div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Owner')?>:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b><?=htmlspecialchars($docker_card_owner, ENT_QUOTES)?></b></div>
                      </div>
                    </td>
                    <td>
                      <div class="l-unit__stat-cols clearfix">
                        <div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Status')?>:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b class="docker-card-status"><?=htmlspecialchars($docker_card_status, ENT_QUOTES)?></b></div>
                      </div>
                    </td>
                    <td>
                      <div class="l-unit__stat-cols clearfix last">
                        <div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Route')?>:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b><?=htmlspecialchars(isset($container['DOMAIN']) && $container['DOMAIN'] !== '' ? $container['DOMAIN'] : __('none'), ENT_QUOTES)?></b></div>
                      </div>
                    </td>
                  </tr>
                  <tr>
                    <td>
                      <div class="l-unit__stat-cols clearfix">
                        <div class="l-unit__stat-col l-unit__stat-col--left">CPU:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b class="docker-card-latest-cpu"><?=__('No data')?></b></div>
                      </div>
                    </td>
                    <td>
                      <div class="l-unit__stat-cols clearfix">
                        <div class="l-unit__stat-col l-unit__stat-col--left">Memory:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b class="docker-card-latest-mem"><?=__('No data')?></b></div>
                      </div>
                    </td>
                    <td>
                      <div class="l-unit__stat-cols clearfix last">
                        <div class="l-unit__stat-col l-unit__stat-col--left">RX / TX:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b><span class="docker-card-latest-rx"><?=__('No data')?></span> / <span class="docker-card-latest-tx"><?=__('No data')?></span></b></div>
                      </div>
                    </td>
                  </tr>
                  <tr>
                    <td>
                      <div class="l-unit__stat-cols clearfix">
                        <div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Health')?>:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b class="docker-card-health-badge"><?=htmlspecialchars($docker_health_status, ENT_QUOTES)?></b></div>
                      </div>
                    </td>
                    <td>
                      <div class="l-unit__stat-cols clearfix">
                        <div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Alerts')?>:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b class="docker-card-alert-count">0</b></div>
                      </div>
                    </td>
                    <td>
                      <div class="l-unit__stat-cols clearfix last">
                        <div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Last health check')?>:</div>
                        <div class="l-unit__stat-col l-unit__stat-col--right"><b class="docker-card-health-updated"><?=htmlspecialchars(isset($container['LAST_HEALTH_AT']) && $container['LAST_HEALTH_AT'] !== '' ? $container['LAST_HEALTH_AT'] : __('No data'), ENT_QUOTES)?></b></div>
                      </div>
                    </td>
                  </tr>
                </table>
              </div>
            </div>
          </article>
<?php
  };
?>
    <div class="l-center">
      <div class="l-sort clearfix noselect">
        <?php if ($docker_available && empty($docker_quota['reached']) && $docker_can_add_from_scope) { ?>
        <a href="<?=$docker_add_href?>" class="l-sort__create-btn" title="<?=__('Add Docker Container')?>"><div id="add-icon"></div><div id="tooltip"><?=__('Add Docker Container')?></div></a>
        <?php } else { ?>
        <a href="/list/docker/<?=$docker_query?>" class="l-sort__create-btn edit" title="<?=__('Docker')?>"><div id="add-icon"></div><div id="tooltip"><?=__('Docker')?></div></a>
        <?php } ?>

        <div class="l-sort-toolbar clearfix">
          <table>
            <tr>
              <td class="step-right">
                <a class="vst" href="/list/server/"><?=__('Server')?></a>
              </td>
              <td class="step-right">
                <a class="vst" href="/list/docker/<?=$docker_query?>"><?=__('refresh')?></a>
              </td>
              <?php if ($_SESSION['user'] === 'admin' && !$docker_available) { ?>
              <td class="step-right">
                <a class="vst" href="javascript:void(0)" onclick="more_button_click(0)"><?=__('Install Docker')?></a>
              </td>
              <?php } ?>
              <?php if ($_SESSION['user'] === 'admin' && !empty($docker_owner_filter_options)) { ?>
              <td class="step-right">
                <form method="get" action="/list/docker/" style="display:inline;">
                  <select name="user" class="vst-list" style="min-width: 160px;" onchange="this.form.submit()">
                    <option value=""><?=__('All Users')?></option>
                    <?php foreach ($docker_owner_filter_options as $docker_filter_user => $docker_filter_data) { ?>
                    <option value="<?=htmlspecialchars($docker_filter_user, ENT_QUOTES)?>" <?php if ($docker_owner === $docker_filter_user) echo 'selected'; ?>><?=htmlspecialchars($docker_filter_user, ENT_QUOTES)?></option>
                    <?php } ?>
                  </select>
                </form>
              </td>
              <?php } ?>
            </tr>
          </table>
        </div>
      </div>
    </div>

    <div class="l-separator"></div>

    <script>
      var dataset_values = [];
      window.DOCKER_LIST = {
        token: '<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>',
        actorIsAdmin: <?=$_SESSION['user'] === 'admin' ? 'true' : 'false'?>,
        ownerScope: '<?=htmlspecialchars($docker_owner, ENT_QUOTES)?>',
        currentUser: '<?=htmlspecialchars($user, ENT_QUOTES)?>',
        dockerAvailable: <?=$docker_available ? 'true' : 'false'?>,
        dockerDaemonAvailable: <?=$docker_daemon_available ? 'true' : 'false'?>,
        quotaReached: <?=!empty($docker_quota['reached']) ? 'true' : 'false'?>,
        primaryState: '<?=htmlspecialchars($docker_primary_state, ENT_QUOTES)?>',
        statsUrl: '/ajax/docker/actions/stats.php',
        healthUrl: '/ajax/docker/actions/health.php',
        alertsUrl: '/ajax/docker/actions/alerts.php',
        acknowledgeUrl: '/ajax/docker/actions/acknowledge_alert.php',
        pollIntervalMs: 60000,
        containers: []
      };
    </script>

    <?php if ($_SESSION['user'] === 'admin' && !$docker_available) { ?>
    <script>
      dataset_values[0] = {
        url: '/ajax/docker/index.php',
        title: 'Docker'
      };
    </script>
    <?php } ?>

    <div class="l-center units" <?php if ($docker_primary_state !== 'unavailable') echo 'style="display:none;"'; ?>>
      <div id="docker-unavailable-state" class="l-unit l-unit--error">
        <div class="l-unit__col l-unit__col--right">
          <div class="l-unit__name separate"><?=__('Docker is not installed')?></div>
          <div class="l-unit__stats">
            <table>
              <tr>
                <td><?=__('Install Docker from the panel to start managing containers.')?></td>
              </tr>
            </table>
          </div>
        </div>
      </div>
    </div>

    <div class="l-center units" <?php if ($docker_primary_state !== 'empty') echo 'style="display:none;"'; ?>>
      <div id="docker-empty-state" class="l-unit">
        <div class="l-unit__col l-unit__col--right">
          <div class="l-unit__name separate"><?=__('No Docker containers are managed in this scope yet.')?></div>
          <div class="l-unit__stats">
            <table>
              <tr>
                <td><?=__('Create a managed container to start routing and monitoring it from the panel.')?></td>
              </tr>
            </table>
          </div>
        </div>
      </div>
    </div>

    <div class="l-center units" <?php if ($docker_primary_state !== 'quota') echo 'style="display:none;"'; ?>>
      <div id="docker-quota-reached-state" class="l-unit l-unit--suspended">
        <div class="l-unit__col l-unit__col--right">
          <div class="l-unit__name separate"><?=__('Docker container quota is reached')?></div>
          <div class="l-unit__stats">
            <table>
              <tr>
                <td><?=__('This account is already using its allowed number of managed Docker containers.')?></td>
              </tr>
            </table>
          </div>
        </div>
      </div>
    </div>

    <div id="docker-list-state" class="l-center units" <?php if ($docker_primary_state !== 'list') echo 'style="display:none;"'; ?>>
      <div class="l-center">
        <?php if ($docker_available && !$docker_daemon_available) { ?>
        <div class="notice notice-warning" style="margin-bottom: 12px;"><?=__('Docker daemon is unavailable. Runtime actions may fail until the service returns, but managed metadata is still shown below.')?></div>
        <?php } ?>
        <div id="docker-owner-filter">
          <?php if ($_SESSION['user'] === 'admin') { ?>
          <span class="vst-text"><b><?=__('Owner scope')?>:</b> <?=htmlspecialchars($docker_owner !== '' ? $docker_owner : __('All Users'), ENT_QUOTES)?></span>
          <?php } ?>
        </div>
        <div id="docker-list-toolbar" style="margin: 14px 0;">
          <span class="vst-text"><b><?=__('Managed Docker containers')?>:</b> <?=count($data)?></span>
          <?php if ($_SESSION['user'] === 'admin' && $docker_owner === '') { ?>
          <span class="vst-text" style="margin-left: 12px;"><?=__('Select an owner scope to add a Docker container.')?></span>
          <?php } ?>
          <?php if (!empty($docker_quota['reached'])) { ?>
          <span class="vst-error" style="margin-left: 12px;"><?=__('Quota reached for this owner scope.')?></span>
          <?php } ?>
        </div>
      </div>

      <div id="docker-list-cards">
        <?php if ($docker_show_owner_groups) { ?>
          <?php foreach ($docker_grouped_data as $docker_group_owner => $docker_group_containers) { ?>
          <section class="docker-owner-group" data-owner="<?=htmlspecialchars($docker_group_owner, ENT_QUOTES)?>">
            <div class="l-unit" style="margin-bottom: 12px;">
              <div class="l-unit__col l-unit__col--right">
                <div class="l-unit__name separate"><?=htmlspecialchars($docker_group_owner, ENT_QUOTES)?></div>
                <div class="l-unit__stats">
                  <table>
                    <tr>
                      <td><?=count($docker_group_containers)?> <?=__('containers')?></td>
                    </tr>
                  </table>
                </div>
              </div>
            </div>
            <?php foreach ($docker_group_containers as $docker_key => $container) { ?>
              <?php $docker_render_card($docker_key, $container); ?>
            <?php } ?>
          </section>
          <?php } ?>
        <?php } else { ?>
          <?php foreach ($data as $docker_key => $container) { ?>
            <?php $docker_render_card($docker_key, $container); ?>
          <?php } ?>
        <?php } ?>
      </div>
    </div>

    <section id="docker-health-dashboard" class="l-center units" style="margin-top: 18px; <?php if ($docker_primary_state !== 'list') echo 'display:none;'; ?>">
      <div class="l-unit">
        <div class="l-unit__col l-unit__col--right">
          <div class="l-unit__name separate"><?=__('Docker health dashboard')?></div>
          <div class="l-unit__stats">
            <table>
              <tr>
                <td><div class="l-unit__stat-cols clearfix"><div class="l-unit__stat-col l-unit__stat-col--left">CPU:</div><div class="l-unit__stat-col l-unit__stat-col--right"><b id="docker-card-cpu"><?=__('No data')?></b></div></div></td>
                <td><div class="l-unit__stat-cols clearfix"><div class="l-unit__stat-col l-unit__stat-col--left">Memory:</div><div class="l-unit__stat-col l-unit__stat-col--right"><b id="docker-card-mem"><?=__('No data')?></b></div></div></td>
                <td><div class="l-unit__stat-cols clearfix last"><div class="l-unit__stat-col l-unit__stat-col--left">RX:</div><div class="l-unit__stat-col l-unit__stat-col--right"><b id="docker-card-rx"><?=__('No data')?></b></div></div></td>
              </tr>
              <tr>
                <td><div class="l-unit__stat-cols clearfix"><div class="l-unit__stat-col l-unit__stat-col--left">TX:</div><div class="l-unit__stat-col l-unit__stat-col--right"><b id="docker-card-tx"><?=__('No data')?></b></div></div></td>
                <td><div class="l-unit__stat-cols clearfix"><div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Health state')?>:</div><div class="l-unit__stat-col l-unit__stat-col--right"><b id="docker-card-health-status"><?=__('No data')?></b></div></div></td>
                <td><div class="l-unit__stat-cols clearfix last"><div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Last health update')?>:</div><div class="l-unit__stat-col l-unit__stat-col--right"><b id="docker-card-health-updated"><?=__('No data')?></b></div></div></td>
              </tr>
              <tr>
                <td colspan="3"><div class="l-unit__stat-cols clearfix"><div class="l-unit__stat-col l-unit__stat-col--left"><?=__('Open alerts')?>:</div><div class="l-unit__stat-col l-unit__stat-col--right"><b id="docker-card-alert-count">0</b></div></div></td>
              </tr>
            </table>
          </div>
        </div>
      </div>
    </section>

    <section id="docker-alerts-panel" class="l-center units" style="margin-top: 18px; <?php if ($docker_primary_state !== 'list') echo 'display:none;'; ?>">
      <div class="l-unit">
        <div class="l-unit__col l-unit__col--right">
          <div class="l-unit__name separate"><?=__('Docker alerts')?></div>
          <div class="l-unit__stats docker-alerts-list">
            <p class="docker-alerts-empty"><?=__('No Docker alerts are active in this scope.')?></p>
          </div>
          <button id="docker-alert-acknowledge" class="button" style="display:none; margin-top: 10px;"><?=__('Acknowledge alert')?></button>
        </div>
      </div>
    </section>

    <div id="vstobjects">
      <div class="l-separator"></div>
      <div class="l-center">
        <div class="l-unit-ft">
          <div class="l-unit__col l-unit__col--left clearfix"></div>
          <div class="data-count l-unit__col l-unit__col--right clearfix"><?=count($data)?> <?=__('containers')?></div>
        </div>
      </div>
    </div>
