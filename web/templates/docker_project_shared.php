<?php
  $project_query_owner = vx_docker_is_admin_actor()
      ? '&user='.urlencode($docker_project_owner)
      : '';
  $project_services = isset($docker_project['SERVICES'])
      && is_array($docker_project['SERVICES'])
      ? $docker_project['SERVICES']
      : array();
  $docker_project_can_mutate = vx_compose_actor_can_mutate_project(
      $docker_project,
      $user,
      $docker_project_owner
  );
  $docker_project_ingress = vx_compose_ingress_consumers_payload(
      $docker_project_owner,
      $docker_project_name,
      $user
  );
  $service_rows = vx_compose_view_services($docker_project);
  $endpoint_rows = vx_compose_view_endpoints($docker_project);
  $route_rows = vx_compose_view_routes($docker_project_routes);
  $ingress_view = vx_compose_view_ingress($docker_project_ingress);
  $health_view = vx_compose_view_health($docker_project_health);
  $resource_view = vx_compose_view_resources(
      $docker_project,
      $docker_project_stats
  );
  $revision_rows = vx_compose_view_revisions(
      $docker_project_revisions,
      $docker_project['REVISION']
  );
  $backup_rows = vx_compose_view_backups($docker_project_backups);
  $alert_rows = vx_compose_view_alerts($docker_project_alerts);
  $operation_rows = vx_compose_view_operations($docker_project_audit);
  $event_rows = vx_compose_view_events($docker_project_audit);
  $secret_names = is_array($docker_project_secrets)
      ? vx_compose_view_list(array_keys($docker_project_secrets))
      : array();
?>
<script>
  var dataset_values = [];
  dataset_values[1] = {
    url: '/ajax/docker/index.php',
    title: '<?=htmlspecialchars($docker_project_name, ENT_QUOTES)?>',
    container_name: '<?=htmlspecialchars($docker_project_name, ENT_QUOTES)?>',
    project: '<?=htmlspecialchars($docker_project_name, ENT_QUOTES)?>',
    owner: '<?=htmlspecialchars($docker_project_owner, ENT_QUOTES)?>'
  };
</script>

<div class="docker-shell docker-shell--form docker-project-console">
  <section class="docker-hero docker-hero--compact">
    <div>
      <div class="docker-eyebrow"><?=__('Docker Compose project')?></div>
      <h1 class="docker-page-title"><?=htmlspecialchars($docker_project_name, ENT_QUOTES)?></h1>
      <p class="docker-page-copy">
        <?=htmlspecialchars(isset($docker_project['COMPOSE_PROJECT']) ? $docker_project['COMPOSE_PROJECT'] : '', ENT_QUOTES)?>
      </p>
    </div>
    <div class="docker-badge-group">
      <span class="docker-status-badge" data-status="<?=htmlspecialchars($docker_project['STATUS'], ENT_QUOTES)?>"><?=htmlspecialchars($docker_project['STATE'], ENT_QUOTES)?></span>
      <span class="docker-health-badge" role="status" aria-live="polite" aria-label="<?=htmlspecialchars('Health '.$docker_project['HEALTH_STATUS'].'; observation '.(isset($docker_project_health['FRESHNESS']) ? $docker_project_health['FRESHNESS'] : 'unavailable'), ENT_QUOTES)?>" data-health-state="<?=htmlspecialchars($docker_project['HEALTH_STATUS'], ENT_QUOTES)?>" data-freshness="<?=htmlspecialchars(isset($docker_project_health['FRESHNESS']) ? $docker_project_health['FRESHNESS'] : 'unavailable', ENT_QUOTES)?>"><?=htmlspecialchars($docker_project['HEALTH_STATUS'], ENT_QUOTES)?></span>
    </div>
  </section>

  <div class="docker-hero__actions">
    <a class="button docker-button docker-button--secondary" href="/list/docker/?user=<?=urlencode($docker_project_owner)?>"><?=__('Back to projects')?></a>
    <?php if ($docker_project_can_mutate && !empty($docker_project['IS_SIMPLE'])) { ?>
    <a class="button docker-button docker-button--secondary" href="/edit/docker/?container=<?=urlencode($docker_project_name)?><?=$project_query_owner?>"><?=__('Simple settings')?></a>
    <?php } ?>
    <?php if ($docker_project_can_mutate) { ?>
    <a class="button docker-button docker-button--secondary" href="/edit/docker/project/?project=<?=urlencode($docker_project_name)?>&user=<?=urlencode($docker_project_owner)?>"><?=__('Advanced update')?></a>
    <a class="button docker-button docker-button--danger" title="<?=__('Impact: briefly interrupts every service in this project.')?>" href="/restart/docker/?container=<?=urlencode($docker_project_name)?><?=$project_query_owner?>&token=<?=$_SESSION['token']?>"><?=__('Restart project')?></a>
    <?php } ?>
    <a class="button docker-button docker-button--primary" href="javascript:void(0)" onclick="more_button_click(1)"><?=__('Project actions')?></a>
  </div>

  <?php if ($docker_project_can_mutate) { ?>
  <aside class="docker-impact-note" aria-label="<?=__('Mutation impact')?>">
    <strong><?=__('Mutation impact')?></strong>
    <span><?=__('Restart, rollback, restore, recreate, and remove actions can interrupt running services. Confirmation and exact project scope are required in Project actions.')?></span>
  </aside>
  <?php } ?>

  <div class="docker-overview-grid">
    <article class="docker-overview-card">
      <span class="docker-overview-card__label"><?=__('Owner')?></span>
      <strong class="docker-overview-card__value"><?=htmlspecialchars($docker_project_owner, ENT_QUOTES)?></strong>
      <p class="docker-overview-card__meta"><?=__('Explicit project owner scope.')?></p>
    </article>
    <article class="docker-overview-card">
      <span class="docker-overview-card__label"><?=__('Services')?></span>
      <strong class="docker-overview-card__value"><?=count($project_services)?></strong>
      <p class="docker-overview-card__meta"><?=htmlspecialchars(implode(', ', $project_services), ENT_QUOTES)?></p>
    </article>
    <article class="docker-overview-card">
      <span class="docker-overview-card__label"><?=__('Revision')?></span>
      <strong class="docker-overview-card__value"><?=htmlspecialchars($docker_project['REVISION'], ENT_QUOTES)?></strong>
      <p class="docker-overview-card__meta"><?=htmlspecialchars($docker_project['PROFILE'], ENT_QUOTES)?> <?=__('profile')?></p>
    </article>
    <article class="docker-overview-card">
      <span class="docker-overview-card__label"><?=__('Ingress consumers')?></span>
      <strong class="docker-overview-card__value"><?=$ingress_view['count']?></strong>
      <p class="docker-overview-card__meta"><?=__('Redacted native-domain consumers.')?></p>
    </article>
  </div>

  <div class="docker-console-grid">
    <section class="docker-panel docker-console-panel docker-console-panel--wide">
      <div class="docker-panel__header">
        <div>
          <div class="docker-eyebrow"><?=__('Runtime map')?></div>
          <h2 class="docker-panel__title"><?=__('Services and endpoints')?></h2>
        </div>
        <p class="docker-panel__copy"><?=__('Immutable images, healthcheck coverage, and bound ports from the current validated definition.')?></p>
      </div>
      <div class="docker-table-scroll">
        <table class="docker-data-table">
          <thead><tr><th><?=__('Service')?></th><th><?=__('Image')?></th><th><?=__('Published ports')?></th><th><?=__('Healthcheck')?></th></tr></thead>
          <tbody>
          <?php if (empty($service_rows)) { ?>
            <tr><td colspan="4" class="docker-empty-cell"><?=__('No service summary is available.')?></td></tr>
          <?php } else { foreach ($service_rows as $row) { ?>
            <tr><th scope="row"><?=$row['service']?></th><td class="docker-mono"><?=$row['image']?></td><td><?php if (empty($row['ports'])) { ?>—<?php } else { foreach ($row['ports'] as $port) { ?><span class="docker-code-chip"><?=$port?></span><?php } } ?></td><td><?=$row['healthcheck']?></td></tr>
          <?php } } ?>
          </tbody>
        </table>
      </div>
      <?php if (!empty($endpoint_rows)) { ?>
      <div class="docker-endpoint-grid">
        <?php foreach ($endpoint_rows as $row) { ?>
        <article class="docker-endpoint-card"><span><?=$row['service']?></span><strong class="docker-mono"><?=$row['published']?></strong><small><?=$row['protocol']?></small></article>
        <?php } ?>
      </div>
      <?php } ?>
      <details class="docker-advanced-json">
        <summary><?=__('Advanced JSON')?></summary>
        <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json(array('SERVICE_SUMMARY' => isset($docker_project['SERVICE_SUMMARY']) ? $docker_project['SERVICE_SUMMARY'] : array(), 'IMAGE_IDENTITIES' => isset($docker_project['IMAGE_IDENTITIES']) ? $docker_project['IMAGE_IDENTITIES'] : array())), ENT_QUOTES)?></pre>
      </details>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Network')?></div><h2 class="docker-panel__title"><?=__('Managed routes')?></h2></div></div>
      <div class="docker-table-scroll"><table class="docker-data-table docker-data-table--stack">
        <thead><tr><th><?=__('Domain')?></th><th><?=__('Service')?></th><th><?=__('Target')?></th><th><?=__('Path')?></th></tr></thead>
        <tbody><?php if (empty($route_rows)) { ?><tr><td colspan="4" class="docker-empty-cell"><?=__('No managed routes.')?></td></tr><?php } else { foreach ($route_rows as $row) { ?><tr><th scope="row"><?=$row['domain']?></th><td><?=$row['service']?></td><td class="docker-mono"><?=$row['target']?></td><td><?=$row['path']?></td></tr><?php } } ?></tbody>
      </table></div>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_routes), ENT_QUOTES)?></pre></details>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Native ingress')?></div><h2 class="docker-panel__title"><?=__('Ingress consumers')?></h2></div></div>
      <?php if (empty($ingress_view['rows'])) { ?>
      <p class="docker-empty-copy"><?=__('No consumer metadata is visible to this actor.')?></p>
      <?php } else { ?>
      <div class="docker-table-scroll"><table class="docker-data-table docker-data-table--stack"><thead><tr><th><?=__('Consumer')?></th><th><?=__('Domain')?></th><th><?=__('Target')?></th><th><?=__('Health')?></th><th><?=__('Header names')?></th></tr></thead><tbody><?php foreach ($ingress_view['rows'] as $row) { ?><tr><th scope="row"><?=$row['consumer']?></th><td><?=$row['domain']?></td><td class="docker-mono"><?=$row['target']?></td><td><?=$row['health']?></td><td><?=$row['headers']?></td></tr><?php } ?></tbody></table></div>
      <?php } ?>
      <p class="docker-privacy-note"><?=__('BusinessGUID values remain in their native authority; this panel shows only permitted redacted metadata and header names.')?></p>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_ingress), ENT_QUOTES)?></pre></details>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Readiness')?></div><h2 class="docker-panel__title"><?=__('Health')?></h2></div><span class="docker-health-badge" data-health-state="<?=$health_view['status']?>"><?=$health_view['status']?></span></div>
      <dl class="docker-key-values"><div><dt><?=__('Observed')?></dt><dd><?=$health_view['observed']?></dd></div><div><dt><?=__('Freshness')?></dt><dd><?=$health_view['freshness']?></dd></div><div><dt><?=__('Source')?></dt><dd><?=$health_view['source']?></dd></div></dl>
      <?php if (!empty($health_view['services'])) { ?><div class="docker-table-scroll"><table class="docker-data-table docker-data-table--stack"><thead><tr><th><?=__('Service')?></th><th><?=__('Status')?></th><th><?=__('Restarts')?></th></tr></thead><tbody><?php foreach ($health_view['services'] as $row) { ?><tr><th scope="row"><?=$row['service']?></th><td><?=$row['status']?></td><td><?=$row['restarts']?></td></tr><?php } ?></tbody></table></div><?php } ?>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_health), ENT_QUOTES)?></pre></details>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Capacity')?></div><h2 class="docker-panel__title"><?=__('Resources')?></h2></div></div>
      <div class="docker-resource-grid">
        <article><span><?=__('CPU now')?></span><strong><?=$resource_view['cpu_now']?></strong><small><?=__('Limit')?> <?=$resource_view['cpu_limit']?></small></article>
        <article><span><?=__('Memory now')?></span><strong><?=$resource_view['memory_now']?></strong><small><?=__('Limit')?> <?=$resource_view['memory_limit']?></small></article>
        <article><span><?=__('Storage limit')?></span><strong><?=$resource_view['storage_limit']?></strong><small><?=__('Managed allocation')?></small></article>
        <article><span><?=__('PID limit')?></span><strong><?=$resource_view['pids_limit']?></strong><small><?=__('Per project policy')?></small></article>
      </div>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_stats), ENT_QUOTES)?></pre></details>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Recovery')?></div><h2 class="docker-panel__title"><?=__('Revisions')?></h2></div></div>
      <div class="docker-revision-list"><?php if (empty($revision_rows)) { ?><p class="docker-empty-copy"><?=__('No rollback revisions are available.')?></p><?php } else { foreach ($revision_rows as $row) { ?><span class="docker-revision-chip<?php if ($row['current']) echo ' docker-revision-chip--current'; ?>">r<?=$row['revision']?><?php if ($row['current']) { ?> · <?=__('current')?><?php } ?></span><?php } } ?></div>
      <p class="docker-impact-copy"><?=__('Rollback replaces desired state and can interrupt running services. Use Project actions to review and confirm the exact revision.')?></p>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Recovery')?></div><h2 class="docker-panel__title"><?=__('Managed backups')?></h2></div></div>
      <div class="docker-table-scroll"><table class="docker-data-table docker-data-table--stack"><thead><tr><th><?=__('Archive')?></th><th><?=__('Created')?></th><th><?=__('Bytes')?></th></tr></thead><tbody><?php if (empty($backup_rows)) { ?><tr><td colspan="3" class="docker-empty-cell"><?=__('No managed backups are available.')?></td></tr><?php } else { foreach ($backup_rows as $row) { ?><tr><th scope="row" class="docker-mono"><?=$row['archive']?></th><td><?=$row['created']?></td><td><?=$row['bytes']?></td></tr><?php } } ?></tbody></table></div>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_backups), ENT_QUOTES)?></pre></details>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Protection')?></div><h2 class="docker-panel__title"><?=__('Secret references')?></h2></div></div>
      <p class="docker-privacy-note"><?=__('Only secret names and metadata are displayed; values are never returned.')?></p>
      <div class="docker-chip-list"><?php if (empty($secret_names)) { ?><span class="docker-empty-copy"><?=__('No managed secret references.')?></span><?php } else { foreach ($secret_names as $secret) { ?><span class="docker-code-chip"><?=$secret?></span><?php } } ?></div>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_secrets), ENT_QUOTES)?></pre></details>
    </section>

    <section class="docker-panel docker-console-panel docker-console-panel--wide">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Attention')?></div><h2 class="docker-panel__title"><?=__('Alerts')?></h2></div><span class="docker-count-badge"><?=count($alert_rows)?></span></div>
      <div class="docker-alert-stack"><?php if (empty($alert_rows)) { ?><p class="docker-empty-copy"><?=__('No alerts are recorded for this project.')?></p><?php } else { foreach ($alert_rows as $row) { ?><article class="docker-alert-item" data-status="<?=$row['status']?>"><div><strong><?=$row['type']?></strong><span><?=$row['status']?> · <?=$row['opened']?></span></div><p><?=$row['message']?></p><small><?=__('Acknowledged')?>: <?=$row['acknowledged']?></small></article><?php } } ?></div>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_alerts), ENT_QUOTES)?></pre></details>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Activity')?></div><h2 class="docker-panel__title"><?=__('Recent operations')?></h2></div></div>
      <div class="docker-table-scroll"><table class="docker-data-table docker-data-table--stack"><thead><tr><th><?=__('Action')?></th><th><?=__('Result')?></th><th><?=__('Time')?></th><th><?=__('Duration')?></th></tr></thead><tbody><?php if (empty($operation_rows)) { ?><tr><td colspan="4" class="docker-empty-cell"><?=__('No operations are recorded.')?></td></tr><?php } else { foreach ($operation_rows as $row) { ?><tr><th scope="row"><?=$row['action']?></th><td><span class="docker-result-badge" data-result="<?=$row['result']?>"><?=$row['result']?></span></td><td><?=$row['timestamp']?></td><td><?=$row['duration']?></td></tr><?php } } ?></tbody></table></div>
    </section>

    <section class="docker-panel docker-console-panel">
      <div class="docker-panel__header"><div><div class="docker-eyebrow"><?=__('Audit')?></div><h2 class="docker-panel__title"><?=__('Events')?></h2></div></div>
      <ol class="docker-event-list"><?php if (empty($event_rows)) { ?><li class="docker-empty-copy"><?=__('No audit events are recorded.')?></li><?php } else { foreach ($event_rows as $row) { ?><li><span class="docker-event-list__marker"></span><div><strong><?=$row['event']?></strong><small><?=$row['timestamp']?> · <?=$row['actor']?></small><p><?=$row['details']?></p></div></li><?php } } ?></ol>
      <details class="docker-advanced-json"><summary><?=__('Advanced JSON')?></summary><pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_audit), ENT_QUOTES)?></pre></details>
    </section>
  </div>
</div>
