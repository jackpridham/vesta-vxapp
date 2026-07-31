<?php
  $project_query_owner = vx_docker_is_admin_actor()
      ? '&user='.urlencode($docker_project_owner)
      : '';
  $project_services = isset($docker_project['SERVICES'])
      && is_array($docker_project['SERVICES'])
      ? $docker_project['SERVICES']
      : array();
  $project_images = isset($docker_project['IMAGES'])
      && is_array($docker_project['IMAGES'])
      ? $docker_project['IMAGES']
      : array();
  $docker_project_can_mutate = vx_compose_actor_can_mutate_project(
      $docker_project,
      $user,
      $docker_project_owner
  );
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

<div class="docker-shell docker-shell--form">
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
    <a class="button docker-button docker-button--secondary" href="/restart/docker/?container=<?=urlencode($docker_project_name)?><?=$project_query_owner?>&token=<?=$_SESSION['token']?>"><?=__('Restart')?></a>
    <?php } ?>
    <a class="button docker-button docker-button--primary" href="javascript:void(0)" onclick="more_button_click(1)"><?=__('Project actions')?></a>
  </div>

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
  </div>

  <div class="docker-form-grid">
    <section class="docker-form-card docker-form-card--wide">
      <div class="docker-panel__header">
        <div>
          <div class="docker-eyebrow"><?=__('Definition')?></div>
          <h2 class="docker-panel__title"><?=__('Services and immutable images')?></h2>
        </div>
      </div>
      <div class="docker-stat"><b><?=__('Services')?>:</b> <?=htmlspecialchars(implode(', ', $project_services), ENT_QUOTES)?></div>
      <div class="docker-stat"><b><?=__('Images')?>:</b> <?=htmlspecialchars(implode(', ', $project_images), ENT_QUOTES)?></div>
      <?php if (!empty($docker_project['IMAGE_IDENTITIES']) && is_array($docker_project['IMAGE_IDENTITIES'])) { ?>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project['IMAGE_IDENTITIES']), ENT_QUOTES)?></pre>
      <?php } ?>
      <?php if (!empty($docker_project['SERVICE_SUMMARY']) && is_array($docker_project['SERVICE_SUMMARY'])) { ?>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project['SERVICE_SUMMARY']), ENT_QUOTES)?></pre>
      <?php } ?>
    </section>

    <section class="docker-form-card">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Routes')?></h2></div>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_routes), ENT_QUOTES)?></pre>
    </section>
    <section class="docker-form-card">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Secret references')?></h2></div>
      <p><?=__('Only secret names and metadata are displayed; values are never returned.')?></p>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_secrets), ENT_QUOTES)?></pre>
    </section>
    <section class="docker-form-card">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Health')?></h2></div>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_health), ENT_QUOTES)?></pre>
    </section>
    <section class="docker-form-card">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Recent metrics')?></h2></div>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_stats), ENT_QUOTES)?></pre>
    </section>
    <section class="docker-form-card">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Alerts')?></h2></div>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_alerts), ENT_QUOTES)?></pre>
    </section>
    <section class="docker-form-card">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Available rollback revisions')?></h2></div>
      <p><?=htmlspecialchars(implode(', ', $docker_project_revisions), ENT_QUOTES)?></p>
    </section>
    <section class="docker-form-card">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Managed backups')?></h2></div>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_backups), ENT_QUOTES)?></pre>
    </section>
    <section class="docker-form-card docker-form-card--wide">
      <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Audit trail')?></h2></div>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($docker_project_audit), ENT_QUOTES)?></pre>
    </section>
  </div>
</div>
