import assert from 'node:assert/strict';
import test from 'node:test';
import {
  IPHONE_WHATSAPP_PLUGIN_ID,
  IPHONE_WHATSAPP_PLUGIN_PATH,
  WhatsAppPluginConfigRefusal,
  migrateIPhoneWhatsAppPluginConfig,
} from '../config/migrate.mjs';

test('adds the exact iPhone path and enabled entry without changing unrelated config', () => {
  const current = {
    gateway: { port: 18789 },
    plugins: { load: { paths: ['/opt/other-plugin'] }, entries: { codex: { enabled: true } } },
    tools: { exec: { mode: 'ask' } },
  };

  const result = migrateIPhoneWhatsAppPluginConfig(current);

  assert.equal(result.status, 'migrated');
  assert.deepEqual(result.config.plugins.load.paths, ['/opt/other-plugin', IPHONE_WHATSAPP_PLUGIN_PATH]);
  assert.deepEqual(result.config.plugins.entries.codex, { enabled: true });
  assert.deepEqual(result.config.plugins.entries[IPHONE_WHATSAPP_PLUGIN_ID], { enabled: true });
  assert.deepEqual(result.config.gateway, current.gateway);
  assert.deepEqual(result.config.tools, current.tools);
  assert.deepEqual(current.plugins.load.paths, ['/opt/other-plugin']);
});

test('preserves an existing nonempty allow list and adds only this plugin id once', () => {
  const current = {
    plugins: {
      allow: ['codex', 'other-plugin'],
      load: { paths: [IPHONE_WHATSAPP_PLUGIN_PATH] },
      entries: { [IPHONE_WHATSAPP_PLUGIN_ID]: { config: { existing: true } } },
    },
  };

  const result = migrateIPhoneWhatsAppPluginConfig(current);

  assert.deepEqual(result.config.plugins.allow, ['codex', 'other-plugin', IPHONE_WHATSAPP_PLUGIN_ID]);
  assert.deepEqual(result.config.plugins.load.paths, [IPHONE_WHATSAPP_PLUGIN_PATH]);
  assert.deepEqual(result.config.plugins.entries[IPHONE_WHATSAPP_PLUGIN_ID], {
    config: { existing: true }, enabled: true,
  });
});

test('leaves an absent or empty allow list unrestricted', () => {
  for (const allow of [undefined, []]) {
    const current = { plugins: allow === undefined ? {} : { allow } };
    const result = migrateIPhoneWhatsAppPluginConfig(current);
    assert.deepEqual(result.config.plugins.allow, allow);
  }
});

test('refuses an explicitly disabled global plugin system with an actionable message', () => {
  assert.throws(
    () => migrateIPhoneWhatsAppPluginConfig({ plugins: { enabled: false } }),
    error => error instanceof WhatsAppPluginConfigRefusal
      && error.message === 'Cannot enable the iPhone WhatsApp plugin while plugins.enabled is false. Enable plugins globally first.');
});

test('refuses a deny list that explicitly blocks the iPhone plugin', () => {
  assert.throws(
    () => migrateIPhoneWhatsAppPluginConfig({ plugins: { deny: ['codex', IPHONE_WHATSAPP_PLUGIN_ID] } }),
    error => error instanceof WhatsAppPluginConfigRefusal
      && error.message === 'Cannot enable the iPhone WhatsApp plugin because plugins.deny blocks it. Remove operator-iphone-whatsapp-link from plugins.deny first.');
});

test('refuses an explicitly disabled entry rather than overriding it', () => {
  assert.throws(
    () => migrateIPhoneWhatsAppPluginConfig({ plugins: { entries: { [IPHONE_WHATSAPP_PLUGIN_ID]: { enabled: false } } } }),
    error => error instanceof WhatsAppPluginConfigRefusal
      && error.message === 'Cannot enable the iPhone WhatsApp plugin because its entry is explicitly disabled. Enable the entry first.');
});
