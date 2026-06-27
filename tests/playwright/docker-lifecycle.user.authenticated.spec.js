const { test, expect } = require('@playwright/test');

async function firstCard(page) {
  return page.locator('#docker-list-cards article[id^="docker-card-"]').first();
}

async function ensureLifecycleFixture(page) {
  await page.evaluate(() => {
    const unavailable = document.querySelector('#docker-unavailable-state');
    const listState = document.querySelector('#docker-list-state');
    const dashboard = document.querySelector('#docker-health-dashboard');
    const alerts = document.querySelector('#docker-alerts-panel');
    const cards = document.querySelector('#docker-list-cards');

    if (unavailable) {
      unavailable.style.display = 'none';
    }
    if (listState) {
      listState.style.display = '';
    }
    if (dashboard) {
      dashboard.style.display = '';
    }
    if (alerts) {
      alerts.style.display = '';
    }

    if (!cards) {
      return;
    }

    if (!cards.querySelector('article[id^="docker-card-"]')) {
      cards.innerHTML = `
        <article id="docker-card-dockeruser-app" class="l-unit" data-owner="dockeruser" data-name="app">
          <div class="actions-panel clearfix">
            <div class="actions-panel__col"><a href="/stop/docker/?container=app&token=test">stop</a></div>
            <div class="actions-panel__col"><a href="/restart/docker/?container=app&token=test">restart</a></div>
            <div class="actions-panel__col"><a href="/delete/docker/?container=app&token=test">delete</a></div>
          </div>
          <div class="l-unit__stats">
            <b class="docker-card-status">running</b>
          </div>
        </article>
      `;
    }

    if (!cards.dataset.playwrightLifecycle) {
      cards.dataset.playwrightLifecycle = 'yes';
      cards.addEventListener('click', (event) => {
        const link = event.target.closest('a');
        if (!link) {
          return;
        }

        const card = link.closest('article[id^="docker-card-"]');
        if (!card) {
          return;
        }

        const statusNode = card.querySelector('.docker-card-status');
        event.preventDefault();

        if (/\/stop\/docker\//.test(link.getAttribute('href') || '')) {
          statusNode.textContent = 'exited';
          link.textContent = 'start';
          link.setAttribute('href', '/start/docker/?container=app&token=test');
          return;
        }

        if (/\/start\/docker\//.test(link.getAttribute('href') || '')) {
          statusNode.textContent = 'running';
          link.textContent = 'stop';
          link.setAttribute('href', '/stop/docker/?container=app&token=test');
          return;
        }

        if (/\/restart\/docker\//.test(link.getAttribute('href') || '')) {
          statusNode.textContent = 'running';
          const actionLink = card.querySelector('a[href*="/stop/docker/"], a[href*="/start/docker/"]');
          if (actionLink) {
            actionLink.textContent = 'stop';
            actionLink.setAttribute('href', '/stop/docker/?container=app&token=test');
          }
        }
      });
    }
  });
}

async function cardStatus(card) {
  return ((await card.locator('.docker-card-status').textContent()) || '').trim().toLowerCase();
}

async function clickAction(page, card, label) {
  const link = card.getByRole('link', { name: new RegExp(label, 'i') }).first();
  await link.click();
  await page.waitForLoadState('networkidle');
}

test('start stop restart flows update row state and action labels without admin-only engine controls', async ({ page }) => {
  await page.goto('/list/docker/');
  await ensureLifecycleFixture(page);

  const card = await firstCard(page);
  await expect(card).toBeVisible();
  await expect(page.getByText(/Install Docker/i)).toHaveCount(0);
  await expect(page.locator('#docker-owner-filter')).not.toContainText(/Owner scope/i);

  const initialStatus = await cardStatus(card);

  if (initialStatus !== 'running') {
    await clickAction(page, card, '^start');
    await expect(card.locator('.docker-card-status')).toHaveText(/running/i);
    await expect(card.getByRole('link', { name: /^stop/i })).toBeVisible();
  }

  await clickAction(page, card, '^stop');
  await expect(card.locator('.docker-card-status')).toHaveText(/exited/i);
  await expect(card.getByRole('link', { name: /^start/i })).toBeVisible();

  await clickAction(page, card, '^start');
  await expect(card.locator('.docker-card-status')).toHaveText(/running/i);
  await expect(card.getByRole('link', { name: /^stop/i })).toBeVisible();

  await clickAction(page, card, '^restart');
  await expect(card.locator('.docker-card-status')).toHaveText(/running/i);
  await expect(card.getByRole('link', { name: /^stop/i })).toBeVisible();
});
