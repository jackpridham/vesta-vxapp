<?php
  $docker_query = '';
  if ($docker_actor_is_admin && $docker_owner !== '') {
      $docker_query = '?user='.urlencode($docker_owner);
  }
  $docker_add_href = '/add/docker/'.$docker_query;
  $docker_can_add_from_scope = !($docker_actor_is_admin && $docker_owner === '');
  $docker_has_containers = !empty($data);
  $docker_primary_state = 'list';
  if (!$docker_available) {
      $docker_primary_state = 'unavailable';
  } elseif (!$docker_has_containers && !empty($docker_quota['reached'])) {
      $docker_primary_state = 'quota';
  } elseif (!$docker_has_containers) {
      $docker_primary_state = 'empty';
  }

  $docker_show_owner_groups = ($docker_actor_is_admin && $docker_owner === '' && !empty($docker_grouped_data));
  $docker_scope_label = $docker_actor_is_admin ? ($docker_owner !== '' ? $docker_owner : __('All Users')) : $user;
  $docker_quota_limit = (isset($docker_quota['limit']) && $docker_quota['limit'] !== null && $docker_quota['limit'] !== '') ? $docker_quota['limit'] : __('Unlimited');
  $docker_quota_used = isset($docker_quota['used']) ? (int) $docker_quota['used'] : 0;
  $docker_total_containers = count($data);
  $docker_all_visible_projects_mutable = true;
  foreach ($data as $docker_visible_project) {
      $docker_visible_owner = isset($docker_visible_project['OWNER'])
          ? (string) $docker_visible_project['OWNER']
          : '';
      if (!vx_compose_actor_can_mutate_project(
          $docker_visible_project,
          $user,
          $docker_visible_owner
      )) {
          $docker_all_visible_projects_mutable = false;
          break;
      }
  }
  $docker_render_card = function ($docker_key, $container) use (
      &$i,
      $docker_actor_is_admin,
      $user
  ) {
      ++$i;
      $docker_card_owner = isset($container['OWNER']) ? $container['OWNER'] : '';
      $docker_card_name = isset($container['NAME']) ? $container['NAME'] : $docker_key;
      $docker_card_id = 'docker-card-'.$docker_card_owner.'-'.$docker_card_name;
      $docker_card_status = isset($container['STATUS']) ? $container['STATUS'] : '';
      $docker_health_status = isset($container['HEALTH_STATUS']) && $container['HEALTH_STATUS'] !== '' ? $container['HEALTH_STATUS'] : 'unknown';
      $docker_route_count = isset($container['PROJECT_ROUTE_COUNT'])
          ? (int) $container['PROJECT_ROUTE_COUNT']
          : 0;
      $docker_managed_targets = !empty($container['MANAGED_ROUTE_TARGETS'])
          && is_array($container['MANAGED_ROUTE_TARGETS'])
          ? implode(', ', $container['MANAGED_ROUTE_TARGETS'])
          : __('No managed route targets');
      $docker_endpoint_displays = array();
      if (!empty($container['PUBLISHED_ENDPOINTS'])
          && is_array($container['PUBLISHED_ENDPOINTS'])) {
          foreach ($container['PUBLISHED_ENDPOINTS'] as $docker_endpoint) {
              if (is_array($docker_endpoint)
                  && !empty($docker_endpoint['DISPLAY'])) {
                  $docker_endpoint_displays[] = (string) $docker_endpoint['DISPLAY'];
              }
          }
      }
      $docker_published_endpoints = !empty($docker_endpoint_displays)
          ? implode(', ', $docker_endpoint_displays)
          : __('No published endpoints');
      $docker_restart_policy = isset($container['RESTART_POLICY']) && $container['RESTART_POLICY'] !== '' ? $container['RESTART_POLICY'] : __('No restart policy');
      $docker_query_owner = $docker_actor_is_admin ? '&user='.urlencode($docker_card_owner) : '';
      $docker_action = ($docker_card_status === 'running') ? 'stop' : 'start';
      $docker_card_can_mutate = vx_compose_actor_can_mutate_project(
          $container,
          $user,
          $docker_card_owner
      );
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
              lastHealthAt: '<?=htmlspecialchars(isset($container['LAST_HEALTH_AT']) ? $container['LAST_HEALTH_AT'] : '', ENT_QUOTES)?>',
              healthFreshness: '<?=htmlspecialchars(isset($container['HEALTH_FRESHNESS']) ? $container['HEALTH_FRESHNESS'] : 'unavailable', ENT_QUOTES)?>'
            });
          </script>
          <article id="<?=htmlspecialchars($docker_card_id, ENT_QUOTES)?>" class="l-unit docker-card <?php if ($docker_card_status !== 'running') echo 'l-unit--suspended'; ?>" data-owner="<?=htmlspecialchars($docker_card_owner, ENT_QUOTES)?>" data-name="<?=htmlspecialchars($docker_card_name, ENT_QUOTES)?>" data-status="<?=htmlspecialchars($docker_card_status !== '' ? $docker_card_status : 'unknown', ENT_QUOTES)?>">
            <div class="docker-card__header">
              <div class="docker-card__title-group">
                <div class="docker-eyebrow"><?=__('Managed Compose project')?></div>
                <div class="docker-card__title-row">
                  <div>
                    <h3 class="docker-card__title"><?=htmlspecialchars($docker_card_name, ENT_QUOTES)?></h3>
                    <p class="docker-card__image"><?=htmlspecialchars(isset($container['IMAGE']) ? $container['IMAGE'] : '', ENT_QUOTES)?></p>
                  </div>
                  <div class="docker-badge-group">
                    <span class="docker-status-badge docker-card-status" data-status="<?=htmlspecialchars($docker_card_status !== '' ? $docker_card_status : 'unknown', ENT_QUOTES)?>"><?=htmlspecialchars($docker_card_status !== '' ? $docker_card_status : __('unknown'), ENT_QUOTES)?></span>
                    <span class="docker-health-badge docker-card-health-badge" role="status" aria-live="polite" aria-label="<?=htmlspecialchars('Health '.$docker_health_status.'; observation '.(isset($container['HEALTH_FRESHNESS']) ? $container['HEALTH_FRESHNESS'] : 'unavailable'), ENT_QUOTES)?>" data-health-state="<?=htmlspecialchars($docker_health_status, ENT_QUOTES)?>" data-freshness="<?=htmlspecialchars(isset($container['HEALTH_FRESHNESS']) ? $container['HEALTH_FRESHNESS'] : 'unavailable', ENT_QUOTES)?>"><?=htmlspecialchars($docker_health_status, ENT_QUOTES)?></span>
                  </div>
                </div>
              </div>
            </div>
            <div class="l-unit-toolbar clearfix docker-card__toolbar">
              <div class="l-unit-toolbar__col l-unit-toolbar__col--right noselect">
                <div class="actions-panel clearfix docker-actions">
                  <div class="actions-panel__col actions-panel__edit shortcut-enter" key-action="href"><a href="/list/docker/project/?project=<?=urlencode($docker_card_name)?><?=$docker_query_owner?>"><?=__('details')?></a><span class="shortcut enter">&nbsp;&#8629;</span></div>
                  <?php if ($docker_card_can_mutate) { ?>
                  <div class="actions-panel__col actions-panel__<?=$docker_action?> shortcut-s" key-action="href"><a href="/<?=$docker_action?>/docker/?container=<?=urlencode($docker_card_name)?><?=$docker_query_owner?>&token=<?=$_SESSION['token']?>"><?=__($docker_action)?></a><span class="shortcut">&nbsp;S</span></div>
                  <div class="actions-panel__col actions-panel__restart shortcut-r" key-action="href"><a href="/restart/docker/?container=<?=urlencode($docker_card_name)?><?=$docker_query_owner?>&token=<?=$_SESSION['token']?>"><?=__('restart')?></a><span class="shortcut">&nbsp;R</span></div>
                  <?php } ?>
                  <div class="actions-panel__col actions-panel__logs shortcut-more"><a href="javascript:void(0)" onclick="more_button_click(<?=$i?>)"><?=__('Project actions')?></a><span class="shortcut more">&nbsp;&#8629;</span></div>
                </div>
              </div>
            </div>
            <div class="docker-card__stats">
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Owner')?></span>
                <b class="docker-stat__value"><?=htmlspecialchars($docker_card_owner, ENT_QUOTES)?></b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Services')?></span>
                <b class="docker-stat__value"><?=htmlspecialchars(isset($container['SERVICE_COUNT']) ? $container['SERVICE_COUNT'] : 0, ENT_QUOTES)?></b>
                <span class="docker-stat__meta"><?=htmlspecialchars(isset($container['SERVICES']) ? implode(', ', $container['SERVICES']) : '', ENT_QUOTES)?></span>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Revision')?></span>
                <b class="docker-stat__value"><?=htmlspecialchars(isset($container['REVISION']) ? $container['REVISION'] : 0, ENT_QUOTES)?></b>
                <span class="docker-stat__meta"><?=htmlspecialchars(isset($container['PROFILE']) ? $container['PROFILE'] : 'standard', ENT_QUOTES)?></span>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Runtime drift')?></span>
                <b class="docker-stat__value"><?=!empty($container['DRIFT']['MATCH']) ? __('Exact') : __('Review')?></b>
                <span class="docker-stat__meta"><?=htmlspecialchars(isset($container['DRIFT']['DRIFT_DIGEST']) ? substr((string) $container['DRIFT']['DRIFT_DIGEST'], 0, 12) : __('unavailable'), ENT_QUOTES)?></span>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Last operation')?></span>
                <b class="docker-stat__value"><?=htmlspecialchars(isset($container['LAST_OPERATION']['ACTION']) ? $container['LAST_OPERATION']['ACTION'] : __('None'), ENT_QUOTES)?></b>
                <span class="docker-stat__meta"><?=htmlspecialchars(isset($container['LAST_OPERATION']['RESULT']) ? $container['LAST_OPERATION']['RESULT'] : '', ENT_QUOTES)?></span>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Project routes')?></span>
                <b class="docker-stat__value"><?=htmlspecialchars($docker_route_count, ENT_QUOTES)?></b>
                <span class="docker-stat__meta"><?=htmlspecialchars($docker_managed_targets, ENT_QUOTES)?></span>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Published endpoints')?></span>
                <b class="docker-stat__value docker-mono"><?=htmlspecialchars($docker_published_endpoints, ENT_QUOTES)?></b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label">CPU</span>
                <b class="docker-stat__value docker-card-latest-cpu"><?=__('No data')?></b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Memory')?></span>
                <b class="docker-stat__value docker-card-latest-mem"><?=__('No data')?></b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label">RX / TX</span>
                <b class="docker-stat__value"><span class="docker-card-latest-rx"><?=__('No data')?></span> / <span class="docker-card-latest-tx"><?=__('No data')?></span></b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Alerts')?></span>
                <b class="docker-stat__value docker-card-alert-count">0</b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Restart policy')?></span>
                <b class="docker-stat__value"><?=htmlspecialchars($docker_restart_policy, ENT_QUOTES)?></b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Last health check')?></span>
                <b class="docker-stat__value docker-card-health-updated"><?=htmlspecialchars(isset($container['LAST_HEALTH_AT']) && $container['LAST_HEALTH_AT'] !== '' ? $container['LAST_HEALTH_AT'] : __('No data'), ENT_QUOTES)?></b>
              </div>
              <div class="docker-stat">
                <span class="docker-stat__label"><?=__('Updated')?></span>
                <b class="docker-stat__value"><?=htmlspecialchars(isset($container['UPDATED']) ? $container['UPDATED'] : __('No data'), ENT_QUOTES)?></b>
              </div>
            </div>
          </article>
<?php
  };
?>
    <script>
      var dataset_values = [];
      window.DOCKER_LIST = {
        token: '<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>',
        actorIsAdmin: <?=$docker_actor_is_admin ? 'true' : 'false'?>,
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
    <?php if ($docker_actor_is_admin && !$docker_available) { ?>
    <script>
      dataset_values[0] = {
        url: '/ajax/docker/index.php',
        title: 'Docker'
      };
    </script>
    <?php } ?>

    <div class="docker-shell docker-shell--list">
      <section class="docker-hero">
        <div>
          <div class="docker-eyebrow"><?=__('Docker Panel')?></div>
          <h1 class="docker-page-title"><?=__('Compose projects')?></h1>
          <p class="docker-page-copy"><?=__('Constrained multi-service projects with managed routing, revisions, health, and runtime visibility.')?></p>
        </div>
        <div class="docker-hero__actions">
          <?php if ($docker_available && empty($docker_quota['reached']) && $docker_can_add_from_scope) { ?>
          <a href="<?=$docker_add_href?>" class="button docker-button docker-button--primary" title="<?=__('Add simple Compose project')?>"><?=__('Add simple project')?></a>
          <?php } ?>
          <?php if ($docker_available && empty($docker_quota['reached']) && $docker_can_add_from_scope) { ?>
          <a href="/add/docker/project/<?=$docker_query?>" class="button docker-button docker-button--secondary"><?=__('Advanced Compose')?></a>
          <?php } ?>
          <a href="/list/docker/<?=$docker_query?>" class="button docker-button docker-button--secondary"><?=__('refresh')?></a>
          <a href="/list/server/" class="button docker-button docker-button--secondary"><?=__('Server')?></a>
          <?php if ($docker_actor_is_admin && !$docker_available) { ?>
          <a href="javascript:void(0)" class="button docker-button docker-button--secondary" onclick="more_button_click(0)"><?=__('Install Docker')?></a>
          <?php } ?>
          <?php if ($docker_actor_is_admin && !empty($docker_owner_filter_options)) { ?>
          <form method="get" action="/list/docker/" class="docker-scope-form">
            <label class="docker-field-label" for="docker-owner-select"><?=__('Owner scope')?></label>
            <select id="docker-owner-select" name="user" class="vst-list docker-select" onchange="this.form.submit()">
              <option value=""><?=__('All Users')?></option>
              <?php foreach ($docker_owner_filter_options as $docker_filter_user => $docker_filter_data) { ?>
              <option value="<?=htmlspecialchars($docker_filter_user, ENT_QUOTES)?>" <?php if ($docker_owner === $docker_filter_user) echo 'selected'; ?>><?=htmlspecialchars($docker_filter_user, ENT_QUOTES)?></option>
              <?php } ?>
            </select>
          </form>
          <?php } ?>
        </div>
      </section>

      <div class="docker-overview-grid">
        <?php if ($docker_actor_is_admin && !empty($harbor_admin_status)) { ?>
        <article class="docker-overview-card" data-harbor-admin-status>
          <span class="docker-overview-card__label"><?=__('Managed registry')?></span>
          <strong class="docker-overview-card__value"><?=htmlspecialchars(($harbor_admin_status['MODE'] ?? 'disabled').' / '.($harbor_admin_status['HEALTH'] ?? 'unavailable'), ENT_QUOTES)?></strong>
          <p class="docker-overview-card__meta"><?=htmlspecialchars(__('Certificate').': '.($harbor_admin_status['CERTIFICATE_STATE'] ?? 'unavailable').' · '.__('Storage').': '.($harbor_admin_status['STORAGE_USED_BYTES'] ?? 0).'/'.($harbor_admin_status['STORAGE_TOTAL_BYTES'] ?? 0).' B · '.__('Provider backup').': '.__('disabled for this release').' · '.__('Pending/failed').': '.($harbor_admin_status['PENDING_OPERATIONS'] ?? 0).'/'.($harbor_admin_status['FAILED_OPERATIONS'] ?? 0), ENT_QUOTES)?></p>
        </article>
        <?php } elseif (!$docker_actor_is_admin && !empty($harbor_tenant_status)) { ?>
        <article class="docker-overview-card" data-harbor-tenant-status>
          <span class="docker-overview-card__label"><?=__('Managed registry')?></span>
          <strong class="docker-overview-card__value"><?=htmlspecialchars(($harbor_tenant_status['REGISTRY'] ?? '').'/'.($harbor_tenant_status['NAMESPACE'] ?? ''), ENT_QUOTES)?></strong>
          <p class="docker-overview-card__meta"><?=htmlspecialchars(__('Quota/usage').': '.($harbor_tenant_status['USED_MB'] ?? 0).'/'.($harbor_tenant_status['QUOTA_MB'] ?? 0).' MB · '.__('Runtime').': '.($harbor_tenant_status['STATE'] ?? 'unavailable').' · '.($harbor_tenant_status['FRESHNESS'] ?? 'unavailable'), ENT_QUOTES)?></p>
          <p class="docker-overview-card__meta" data-harbor-publisher-cli><?=__('Rotate publisher access through v-docker registry-publisher-rotate and the tenant Harbor guide; the panel never accepts credential material.')?></p>
          <button type="button" class="button" onclick="more_button_click(901)" data-harbor-publisher-disable><?=__('Disable publisher')?></button>
        </article>
        <script>
          dataset_values[901] = {url:'/ajax/docker/router.php',harbor_publisher:'1',publisher_action:'disable'};
        </script>
        <?php } ?>
        <article class="docker-overview-card">
          <span class="docker-overview-card__label"><?=__('Owner scope')?></span>
          <strong class="docker-overview-card__value"><?=htmlspecialchars($docker_scope_label, ENT_QUOTES)?></strong>
          <p class="docker-overview-card__meta"><?=__('Current panel scope for Docker management.')?></p>
        </article>
        <article class="docker-overview-card">
          <span class="docker-overview-card__label"><?=__('Compose projects')?></span>
          <strong class="docker-overview-card__value"><?=$docker_total_containers?></strong>
          <p class="docker-overview-card__meta"><?=__('Validated project inventory available to this view.')?></p>
        </article>
        <article class="docker-overview-card">
          <span class="docker-overview-card__label"><?=__('Quota')?></span>
          <strong class="docker-overview-card__value"><?=$docker_quota_used?> / <?=htmlspecialchars($docker_quota_limit, ENT_QUOTES)?></strong>
          <p class="docker-overview-card__meta"><?php if (!empty($docker_quota['reached'])) { ?><?=__('This owner scope is at capacity.')?><?php } else { ?><?=__('Capacity remains for additional managed containers.')?><?php } ?></p>
        </article>
      </div>

      <?php if (!empty($docker_quota['dimensions']) && is_array($docker_quota['dimensions'])) { ?>
      <section class="docker-section" aria-labelledby="docker-quota-dimensions-title">
        <div class="docker-section__header">
          <div>
            <h2 id="docker-quota-dimensions-title"><?=__('Compose quota dimensions')?></h2>
            <p><?=__('Authoritative owner usage against the effective package limits.')?></p>
          </div>
        </div>
        <div class="docker-overview-grid">
          <?php foreach ($docker_quota['dimensions'] as $docker_quota_dimension) { ?>
          <article class="docker-overview-card">
            <span class="docker-overview-card__label"><?=htmlspecialchars($docker_quota_dimension['label'], ENT_QUOTES)?></span>
            <strong class="docker-overview-card__value"><?=htmlspecialchars($docker_quota_dimension['used'], ENT_QUOTES)?> / <?=htmlspecialchars(strtolower($docker_quota_dimension['limit']) === 'unlimited' ? __('Unlimited') : $docker_quota_dimension['limit'], ENT_QUOTES)?></strong>
            <p class="docker-overview-card__meta"><?=htmlspecialchars($docker_quota_dimension['unit'], ENT_QUOTES)?></p>
          </article>
          <?php } ?>
        </div>
      </section>
      <?php } ?>

      <section id="docker-unavailable-state" class="docker-state docker-state--warning" <?php if ($docker_primary_state !== 'unavailable') echo 'style="display:none;"'; ?>>
        <div class="docker-state__title"><?=__('Docker is not installed')?></div>
        <p class="docker-state__copy"><?=__('Install Docker from the panel to start managing containers.')?></p>
      </section>

      <section id="docker-empty-state" class="docker-state" <?php if ($docker_primary_state !== 'empty') echo 'style="display:none;"'; ?>>
        <div class="docker-state__title"><?=__('No Compose projects are managed in this scope yet.')?></div>
        <p class="docker-state__copy"><?=__('Create a project to start routing and monitoring it from the panel.')?></p>
      </section>

      <section id="docker-quota-reached-state" class="docker-state docker-state--muted" <?php if ($docker_primary_state !== 'quota') echo 'style="display:none;"'; ?>>
        <div class="docker-state__title"><?=__('Docker container quota is reached')?></div>
        <p class="docker-state__copy"><?=__('This account is already using its allowed number of managed Docker containers.')?></p>
      </section>

      <section id="docker-list-state" class="docker-list-shell" <?php if ($docker_primary_state !== 'list') echo 'style="display:none;"'; ?>>
        <?php if ($docker_available && !$docker_daemon_available) { ?>
        <div class="docker-inline-notice"><?=__('Docker daemon is unavailable. Runtime actions may fail until the service returns, but managed metadata is still shown below.')?></div>
        <?php } ?>
        <div id="docker-owner-filter" class="docker-list-meta">
          <?php if ($docker_actor_is_admin) { ?>
          <span class="docker-list-meta__item"><b><?=__('Owner scope')?>:</b> <?=htmlspecialchars($docker_scope_label, ENT_QUOTES)?></span>
          <?php } ?>
        </div>
        <div id="docker-list-toolbar" class="docker-list-meta">
          <span class="docker-list-meta__item"><b><?=__('Managed Compose projects')?>:</b> <?=$docker_total_containers?></span>
          <?php if ($docker_actor_is_admin && $docker_owner === '') { ?>
          <span class="docker-list-meta__item"><?=__('Select an owner scope to add a Docker container.')?></span>
          <?php } ?>
          <?php if (!empty($docker_quota['reached'])) { ?>
          <span class="docker-list-meta__item docker-list-meta__item--warning"><?=__('Quota reached for this owner scope.')?></span>
          <?php } ?>
        </div>

        <div id="docker-list-cards">
          <?php if ($docker_show_owner_groups) { ?>
            <?php foreach ($docker_grouped_data as $docker_group_owner => $docker_group_containers) { ?>
            <section class="docker-owner-group" data-owner="<?=htmlspecialchars($docker_group_owner, ENT_QUOTES)?>">
              <div class="docker-owner-group__header">
                <div>
                  <div class="docker-eyebrow"><?=__('Owner group')?></div>
                  <h2 class="docker-owner-group__title"><?=htmlspecialchars($docker_group_owner, ENT_QUOTES)?></h2>
                </div>
                <div class="docker-owner-group__count"><?=count($docker_group_containers)?> <?=__('projects')?></div>
              </div>
              <div class="docker-card-grid">
                <?php foreach ($docker_group_containers as $docker_key => $container) { ?>
                  <?php $docker_render_card($docker_key, $container); ?>
                <?php } ?>
              </div>
            </section>
            <?php } ?>
          <?php } else { ?>
          <div class="docker-card-grid">
            <?php foreach ($data as $docker_key => $container) { ?>
              <?php $docker_render_card($docker_key, $container); ?>
            <?php } ?>
          </div>
          <?php } ?>
        </div>
      </section>

      <section id="docker-health-dashboard" class="docker-panel" <?php if ($docker_primary_state !== 'list') echo 'style="display:none;"'; ?>>
        <div class="docker-panel__header">
          <div>
            <div class="docker-eyebrow"><?=__('Dashboard')?></div>
            <h2 class="docker-panel__title"><?=__('Docker health dashboard')?></h2>
          </div>
          <p class="docker-panel__copy"><?=__('Aggregated metrics refresh automatically so the list view stays useful during active operations.')?></p>
        </div>
        <div class="docker-metric-grid">
          <article class="docker-metric-card"><span class="docker-metric-card__label">CPU</span><b id="docker-card-cpu" class="docker-metric-card__value"><?=__('No data')?></b></article>
          <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Memory')?></span><b id="docker-card-mem" class="docker-metric-card__value"><?=__('No data')?></b></article>
          <article class="docker-metric-card"><span class="docker-metric-card__label">RX</span><b id="docker-card-rx" class="docker-metric-card__value"><?=__('No data')?></b></article>
          <article class="docker-metric-card"><span class="docker-metric-card__label">TX</span><b id="docker-card-tx" class="docker-metric-card__value"><?=__('No data')?></b></article>
          <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Health state')?></span><b id="docker-card-health-status" class="docker-metric-card__value docker-health-badge" role="status" aria-live="polite" aria-label="<?=__('Health unknown; observation unavailable')?>" data-health-state="unknown" data-freshness="unavailable"><?=__('No data')?></b></article>
          <article class="docker-metric-card"><span class="docker-metric-card__label"><?=__('Last health update')?></span><b id="docker-card-health-updated" class="docker-metric-card__value"><?=__('No data')?></b></article>
          <article class="docker-metric-card docker-metric-card--wide"><span class="docker-metric-card__label"><?=__('Open alerts')?></span><b id="docker-card-alert-count" class="docker-metric-card__value">0</b></article>
        </div>
      </section>

      <section id="docker-alerts-panel" class="docker-panel" <?php if ($docker_primary_state !== 'list') echo 'style="display:none;"'; ?>>
        <div class="docker-panel__header">
          <div>
            <div class="docker-eyebrow"><?=__('Alerts')?></div>
            <h2 class="docker-panel__title"><?=__('Docker alerts')?></h2>
          </div>
          <p class="docker-panel__copy"><?=__('Open health and threshold notifications across the active owner scope.')?></p>
        </div>
        <div class="docker-alerts-list">
          <p class="docker-alerts-empty"><?=__('No Docker alerts are active in this scope.')?></p>
        </div>
        <div class="docker-alert-actions">
          <?php if ($docker_all_visible_projects_mutable) { ?>
          <button id="docker-alert-acknowledge" class="button docker-button docker-button--secondary" style="display:none;"><?=__('Acknowledge alert')?></button>
          <?php } ?>
        </div>
      </section>

      <div id="vstobjects" class="docker-footer-meta">
        <div class="data-count"><?=count($data)?> <?=__('projects')?></div>
      </div>
    </div>
