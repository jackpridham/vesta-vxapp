<div class="docker-shell docker-shell--form">
  <section class="docker-hero docker-hero--compact">
    <div>
      <div class="docker-eyebrow"><?=__('Admin-only advanced workflow')?></div>
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
    <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($compose_validation_preview), ENT_QUOTES)?></pre>
    <form id="compose-deploy-confirm-form" method="post">
      <input type="hidden" name="token" value="<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>">
      <input type="hidden" name="preview_token" value="<?=htmlspecialchars($compose_preview_key, ENT_QUOTES)?>">
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
            <select id="compose-profile" class="vst-list docker-select" name="profile">
              <option value="standard" <?php if ($compose_form['profile'] === 'standard') echo 'selected'; ?>>standard</option>
              <option value="admin-approved" <?php if ($compose_form['profile'] === 'admin-approved') echo 'selected'; ?>>admin-approved</option>
            </select>
          </div>
          <div class="docker-field docker-field--full">
            <label class="docker-field-label" for="compose-expires"><?=__('Admin-approved expiry (UTC)')?></label>
            <input id="compose-expires" class="vst-input" name="expires" value="<?=htmlspecialchars($compose_form['expires'], ENT_QUOTES)?>" placeholder="2026-07-26T00:00:00Z">
            <p><?=__('Required only for admin-approved; must be in the future and no more than one year away.')?></p>
          </div>
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
