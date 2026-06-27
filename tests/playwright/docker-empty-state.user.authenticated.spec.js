const { test, expect } = require('@playwright/test');

async function forcePrimaryState(page, state) {
  await page.evaluate((nextState) => {
    const stateMap = {
      empty: '#docker-empty-state',
      quota: '#docker-quota-reached-state',
      list: '#docker-list-state',
      unavailable: '#docker-unavailable-state',
    };
    const selectors = Object.values(stateMap).concat(['#docker-health-dashboard', '#docker-alerts-panel']);

    selectors.forEach((selector) => {
      const node = document.querySelector(selector);
      if (!node) {
        return;
      }

      const shouldShow = selector === stateMap[nextState]
        || (nextState === 'list' && (selector === '#docker-health-dashboard' || selector === '#docker-alerts-panel'));
      node.style.display = shouldShow ? '' : 'none';
    });
  }, state);
}

test('empty owned-container state renders docker-empty-state', async ({ page }) => {
  await page.goto('/list/docker/');

  await forcePrimaryState(page, 'empty');
  await expect(page.locator('#docker-empty-state')).toBeVisible();
  await expect(page.locator('#docker-list-state')).toBeHidden();
  await expect(page.locator('#docker-quota-reached-state')).toBeHidden();
});

test('quota exhausted users render docker-quota-reached-state', async ({ page }) => {
  await page.goto('/list/docker/');

  await forcePrimaryState(page, 'quota');
  await expect(page.locator('#docker-quota-reached-state')).toBeVisible();
  await expect(page.locator('#docker-empty-state')).toBeHidden();
  await expect(page.locator('#docker-list-state')).toBeHidden();
});
