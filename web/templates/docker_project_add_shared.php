<div class="docker-shell docker-shell--form">
  <section class="docker-hero docker-hero--compact">
    <div>
      <div class="docker-eyebrow"><?=__('Owner-scoped deployment workflow')?></div>
      <h1 class="docker-page-title"><?=__('Add Compose project')?></h1>
      <p class="docker-page-copy"><?=__('The definition is canonicalized and checked by the deny-first policy before it is saved. Deployment is a separate project action.')?></p>
    </div>
  </section>

  <?php if (!empty($_SESSION['error_msg'])) { ?>
  <div class="docker-form-errors"><span class="vst-error"><?=htmlspecialchars($_SESSION['error_msg'], ENT_QUOTES)?></span></div>
  <?php } ?>

  <?php if ($compose_spawn_hash !== '') { ?>
  <section id="compose-spawn-output" class="docker-form-card docker-form-card--wide">
    <div class="docker-panel__header">
      <h2 class="docker-panel__title"><?=__('Deployment started')?></h2>
    </div>
    <textarea disabled id="confirm-div-content-textarea-variable" class="vst-textinput ajax-newline" style="width:100%;height:420px;font-family:monospace;"></textarea>
    <script>
      startWatchingSpawnedAjaxProcess(
        '<?=htmlspecialchars($user, ENT_QUOTES)?>',
        '<?=htmlspecialchars($compose_spawn_hash, ENT_QUOTES)?>'
      );
    </script>
  </section>
  <?php } elseif (!empty($compose_validation_preview) && $compose_preview_key !== '') { ?>
  <section id="compose-validation-preview" class="docker-form-card docker-form-card--wide">
    <div class="docker-panel__header">
      <div>
        <div class="docker-eyebrow"><?=__('Canonical validation')?></div>
        <h2 class="docker-panel__title"><?=__('Review before deployment')?></h2>
      </div>
    </div>
    <p><?=__('No project state or runtime was changed. Confirm to persist and deploy this exact validated candidate.')?></p>
    <?php
      $impact_services = isset($compose_validation_preview['SERVICES'])
        && is_array($compose_validation_preview['SERVICES'])
        ? $compose_validation_preview['SERVICES'] : array();
      $impact_resources = isset($compose_validation_preview['RESOURCES']['DELTA'])
        && is_array($compose_validation_preview['RESOURCES']['DELTA'])
        ? $compose_validation_preview['RESOURCES']['DELTA'] : array();
      $impact_routes = isset($compose_validation_preview['ROUTES'])
        && is_array($compose_validation_preview['ROUTES'])
        ? $compose_validation_preview['ROUTES'] : array();
      $impact_ports = isset($compose_validation_preview['PORTS'])
        && is_array($compose_validation_preview['PORTS'])
        ? $compose_validation_preview['PORTS'] : array();
    ?>
    <div class="docker-impact-grid">
      <?php foreach (array('ADDED' => __('Services added'), 'CHANGED' => __('Services changed'), 'REMOVED' => __('Services removed')) as $key => $label) { ?>
      <article class="docker-impact-card">
        <h3><?=htmlspecialchars($label, ENT_QUOTES)?></h3>
        <p><?=htmlspecialchars(implode(', ', isset($impact_services[$key]) && is_array($impact_services[$key]) ? $impact_services[$key] : array()) ?: __('None'), ENT_QUOTES)?></p>
      </article>
      <?php } ?>
      <article class="docker-impact-card">
        <h3><?=__('Resource delta')?></h3>
        <p><?=htmlspecialchars(sprintf(
          'Memory: %s MB; CPU: %s milli-CPU; Storage: %s MB',
          isset($impact_resources['MEMORY_MB']) ? $impact_resources['MEMORY_MB'] : 0,
          isset($impact_resources['CPUS_MILLI']) ? $impact_resources['CPUS_MILLI'] : 0,
          isset($impact_resources['STORAGE_MB']) ? $impact_resources['STORAGE_MB'] : 0
        ), ENT_QUOTES)?></p>
      </article>
      <article class="docker-impact-card">
        <h3><?=__('Port changes')?></h3>
        <?php if (empty($impact_ports)) { ?><p><?=__('No published port before/after changes reported.')?></p><?php } ?>
        <?php foreach ($impact_ports as $port) { if (is_array($port)) { ?>
        <p><?=htmlspecialchars(
          (isset($port['SERVICE']) ? $port['SERVICE'].': ' : '')
          .(isset($port['BEFORE']) ? $port['BEFORE'] : __('none'))
          .' → '.(isset($port['AFTER']) ? $port['AFTER'] : __('none')),
          ENT_QUOTES
        )?></p>
        <?php }} ?>
      </article>
      <article class="docker-impact-card">
        <h3><?=__('Route impact')?></h3>
        <?php foreach (array('UNCHANGED' => __('unchanged'), 'INVALIDATED' => __('invalidated'), 'RETARGET_REQUIRED' => __('retarget required')) as $key => $label) { ?>
        <p><?=htmlspecialchars($label.': '.(implode(', ', isset($impact_routes[$key]) && is_array($impact_routes[$key]) ? $impact_routes[$key] : array()) ?: __('None')), ENT_QUOTES)?></p>
        <?php } ?>
      </article>
      <article class="docker-impact-card docker-impact-card--warning">
        <h3><?=__('Deployment warnings')?></h3>
        <p><?=__('Image references that use mutable tags can resolve to different image content at apply time.')?></p>
        <p><?=__('Definition rollback does not roll back persistent application data.')?></p>
      </article>
    </div>
    <details class="docker-preview-details">
      <summary><?=__('Full validation details')?></summary>
      <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($compose_validation_preview), ENT_QUOTES)?></pre>
    </details>
    <form id="compose-deploy-confirm-form" method="post">
      <input type="hidden" name="token" value="<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>">
      <input type="hidden" name="preview_token" value="<?=htmlspecialchars($compose_preview_key, ENT_QUOTES)?>">
      <?php foreach (array('owner', 'project', 'profile', 'preview_id', 'source_sha', 'candidate_sha', 'expected_revision') as $field) { ?>
      <input type="hidden" name="<?=htmlspecialchars($field, ENT_QUOTES)?>" value="<?=htmlspecialchars((string) $preview[$field], ENT_QUOTES)?>">
      <?php } ?>
      <?php if ($user === 'admin' && $preview['profile'] === 'admin-approved') { ?>
      <input type="hidden" name="expires" value="<?=htmlspecialchars($compose_form['expires'], ENT_QUOTES)?>">
      <textarea hidden name="definition"><?=htmlspecialchars($compose_form['definition'], ENT_QUOTES)?></textarea>
      <?php } ?>
      <button class="button docker-button docker-button--primary" name="confirm_deploy" value="1"><?=__('Confirm and deploy')?></button>
      <button class="button docker-button docker-button--secondary" name="cancel_preview" value="1"><?=__('Cancel preview')?></button>
    </form>
  </section>
  <?php } else { ?>
  <form id="compose-advanced-add-form" method="post" class="docker-form">
    <input type="hidden" name="token" value="<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>" />
    <div class="docker-form-grid">
      <section class="docker-form-card">
        <div class="docker-field-grid">
          <div class="docker-field docker-field--full">
            <label class="docker-field-label" for="compose-owner"><?=__('Owner')?></label>
            <input id="compose-owner" class="vst-input" value="<?=htmlspecialchars($docker_form_owner, ENT_QUOTES)?>" disabled>
          </div>
          <div class="docker-field docker-field--full">
            <label class="docker-field-label" for="compose-project"><?=__('Project name')?></label>
            <input id="compose-project" class="vst-input" name="project" required pattern="[a-z0-9][a-z0-9-]{0,47}" value="<?=htmlspecialchars($compose_form['project'], ENT_QUOTES)?>">
          </div>
          <div class="docker-field docker-field--full">
            <label class="docker-field-label" for="compose-profile"><?=__('Policy profile')?></label>
            <?php if ($user === 'admin') { ?>
            <select id="compose-profile" class="vst-list docker-select" name="profile">
              <option value="standard" <?php if ($compose_form['profile'] === 'standard') echo 'selected'; ?>>standard</option>
              <option value="admin-approved" <?php if ($compose_form['profile'] === 'admin-approved') echo 'selected'; ?>>admin-approved</option>
            </select>
            <?php } else { ?>
            <p id="compose-profile" class="docker-readonly-value">standard</p>
            <?php } ?>
          </div>
          <?php if ($user === 'admin') { ?>
          <div class="docker-field docker-field--full">
            <label class="docker-field-label" for="compose-expires"><?=__('Admin-approved expiry (UTC)')?></label>
            <input id="compose-expires" class="vst-input" name="expires" value="<?=htmlspecialchars($compose_form['expires'], ENT_QUOTES)?>" placeholder="2026-07-26T00:00:00Z">
            <p><?=__('Required only for admin-approved; must be in the future and no more than one year away.')?></p>
          </div>
          <?php } ?>
        </div>
      </section>
      <section class="docker-form-card docker-form-card--wide">
        <label class="docker-field-label" for="compose-definition"><?=__('Compose YAML')?></label>
        <textarea id="compose-definition" class="vst-textinput docker-compose-editor" name="definition" rows="24" required><?=htmlspecialchars($compose_form['definition'], ENT_QUOTES)?></textarea>
        <p><?=__('Do not place secret or registry values in the definition. Use managed secret and registry references.')?></p>
      </section>
    </div>
    <div class="docker-form-actions">
      <button class="button docker-button docker-button--primary" name="validate_preview" value="1"><?=__('Validate and preview')?></button>
      <a class="button docker-button docker-button--secondary" href="/list/docker/?user=<?=urlencode($docker_form_owner)?>"><?=__('Cancel')?></a>
    </div>
  </form>
  <?php } ?>
</div>
