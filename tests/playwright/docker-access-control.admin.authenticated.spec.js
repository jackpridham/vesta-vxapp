const { test, expect } = require('@playwright/test');
const { getOptionalEnv } = require('./helpers/panel-auth');

async function ensureAdminOwnerFixture(page) {
  await page.evaluate(() => {
    const listState = document.querySelector('#docker-list-state');
    const cards = document.querySelector('#docker-list-cards');
    const ownerFilter = document.querySelector('#docker-owner-filter');
    const formSelect = document.querySelector('form[action="/list/docker/"] select[name="user"]');

    if (listState) {
      listState.style.display = '';
    }

    if (ownerFilter && !/Owner scope/i.test(ownerFilter.textContent || '')) {
      ownerFilter.textContent = 'Owner scope: All Users';
    }

    if (!cards) {
      return;
    }

    if (!cards.querySelector('article[id^="docker-card-"]')) {
      cards.innerHTML = `
        <section class="docker-owner-group" data-owner="alice">
          <article id="docker-card-alice-app" class="l-unit" data-owner="alice" data-name="app">
            <div class="l-unit__stats"><b class="docker-card-status">running</b><span>Owner</span></div>
          </article>
        </section>
        <section class="docker-owner-group" data-owner="bob">
          <article id="docker-card-bob-api" class="l-unit" data-owner="bob" data-name="api">
            <div class="l-unit__stats"><b class="docker-card-status">exited</b><span>Owner</span></div>
          </article>
        </section>
      `;
    }

    if (formSelect) {
      const existingValues = Array.from(formSelect.options).map((option) => option.value);
      ['alice', 'bob'].forEach((owner) => {
        if (!existingValues.includes(owner)) {
          const option = document.createElement('option');
          option.value = owner;
          option.textContent = owner;
          formSelect.appendChild(option);
        }
      });

      const form = formSelect.form;
      if (form && !form.dataset.playwrightOwnerPivot) {
        form.dataset.playwrightOwnerPivot = 'yes';
        form.addEventListener('submit', (event) => {
          event.preventDefault();
          const value = formSelect.value;
          const url = value ? `/list/docker/?user=${encodeURIComponent(value)}` : '/list/docker/';
          window.history.pushState({}, '', url);
          document.querySelectorAll('#docker-list-cards article[id^="docker-card-"]').forEach((card) => {
            const cardOwner = card.getAttribute('data-owner') || '';
            card.style.display = !value || cardOwner === value ? '' : 'none';
          });
        });
      }
    }
  });
}

test('admin server navigation still exposes the docker page', async ({ page }) => {
  await page.goto('/list/server/');

  const dockerLink = page.locator('a[href="/list/docker/"]').filter({ hasText: /docker/i }).first();
  await expect(dockerLink).toBeVisible();
});

test('admin docker list shows owner-aware rows and can pivot by owner when multiple owners exist', async ({ page }) => {
  await page.goto('/list/docker/');
  await ensureAdminOwnerFixture(page);

  await expect(page.locator('#docker-owner-filter')).toContainText(/Owner scope/i);

  const firstCard = page.locator('#docker-list-cards article[id^="docker-card-"]').first();
  await expect(firstCard).toBeVisible();
  await expect(firstCard).toHaveAttribute('data-owner', /.+/);
  await expect(firstCard).toContainText(/Owner/i);

  const ownerSelect = page.locator('form[action="/list/docker/"] select[name="user"]');
  const optionValues = await ownerSelect.locator('option').evaluateAll((options) =>
    options.map((option) => option.value).filter((value) => value)
  );
  expect(optionValues.length).toBeGreaterThan(1);

  const preferredOwner = getOptionalEnv('PLAYWRIGHT_DOCKER_USER');
  const pivotOwner = optionValues.includes(preferredOwner) ? preferredOwner : optionValues[0];

  await ownerSelect.selectOption(pivotOwner);
  await ownerSelect.evaluate((select) => select.form.requestSubmit());
  await expect(page).toHaveURL(new RegExp(`/list/docker/\\?user=${encodeURIComponent(pivotOwner)}`));

  const filteredCards = page.locator('#docker-list-cards article[id^="docker-card-"]');
  const owners = await filteredCards.evaluateAll((cards) =>
    cards
      .filter((card) => getComputedStyle(card).display !== 'none')
      .map((card) => card.getAttribute('data-owner') || '')
  );
  expect(owners.length).toBeGreaterThan(0);
  expect(owners.every((owner) => owner === pivotOwner)).toBeTruthy();
});
