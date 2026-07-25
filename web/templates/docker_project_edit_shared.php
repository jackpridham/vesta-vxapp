<div class="docker-shell docker-shell--form">
  <section class="docker-hero docker-hero--compact">
    <div>
      <div class="docker-eyebrow"><?=__('Admin-only advanced workflow')?></div>
      <h1 class="docker-page-title"><?=__('Update Compose project')?></h1>
      <p class="docker-page-copy"><?=htmlspecialchars($compose_project_name, ENT_QUOTES)?> — <?=htmlspecialchars($compose_project['PROFILE'], ENT_QUOTES)?></p>
    </div>
  </section>

  <?php if (!empty($_SESSION['error_msg'])) { ?>
  <div class="docker-form-errors"><span class="vst-error"><?=htmlspecialchars($_SESSION['error_msg'], ENT_QUOTES)?></span></div>
  <?php } ?>

  <?php if ($compose_spawn_hash !== '') { ?>
  <section id="compose-spawn-output" class="docker-form-card docker-form-card--wide">
    <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Transactional update started')?></h2></div>
    <textarea disabled id="confirm-div-content-textarea-variable" class="vst-textinput ajax-newline" style="width:100%;height:420px;font-family:monospace;"></textarea>
    <script>
      startWatchingSpawnedAjaxProcess(
        '<?=htmlspecialchars($user, ENT_QUOTES)?>',
        '<?=htmlspecialchars($compose_spawn_hash, ENT_QUOTES)?>'
      );
    </script>
  </section>
  <?php } elseif (!empty($compose_validation_preview) && $compose_preview_key !== '') { ?>
  <section id="compose-update-validation-preview" class="docker-form-card docker-form-card--wide">
    <div class="docker-panel__header"><h2 class="docker-panel__title"><?=__('Review canonical update')?></h2></div>
    <p><?=__('No persisted project or runtime state was changed. Confirm to transactionally apply this exact validated candidate.')?></p>
    <pre class="docker-mono"><?=htmlspecialchars(vx_compose_pretty_json($compose_validation_preview), ENT_QUOTES)?></pre>
    <form id="compose-update-confirm-form" method="post">
      <input type="hidden" name="token" value="<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>">
      <input type="hidden" name="preview_token" value="<?=htmlspecialchars($compose_preview_key, ENT_QUOTES)?>">
      <button class="button docker-button docker-button--primary" name="confirm_update" value="1"><?=__('Confirm update')?></button>
      <button class="button docker-button docker-button--secondary" name="cancel_preview" value="1"><?=__('Cancel preview')?></button>
    </form>
  </section>
  <?php } else { ?>
  <form id="compose-advanced-update-form" method="post" class="docker-form">
    <input type="hidden" name="token" value="<?=htmlspecialchars($_SESSION['token'], ENT_QUOTES)?>">
    <section class="docker-form-card docker-form-card--wide">
      <label class="docker-field-label" for="compose-update-definition"><?=__('Complete replacement Compose YAML')?></label>
      <textarea id="compose-update-definition" class="vst-textinput docker-compose-editor" name="definition" rows="24" required><?=htmlspecialchars($compose_update_definition, ENT_QUOTES)?></textarea>
      <p><?=__('The stored raw definition is never returned. Paste the complete desired definition, using managed secret references only.')?></p>
    </section>
    <div class="docker-form-actions">
      <button class="button docker-button docker-button--primary" name="validate_preview" value="1"><?=__('Validate and preview')?></button>
      <a class="button docker-button docker-button--secondary" href="/list/docker/project/?project=<?=urlencode($compose_project_name)?>&user=<?=urlencode($compose_project_owner)?>"><?=__('Cancel')?></a>
    </div>
  </form>
  <?php } ?>
</div>
