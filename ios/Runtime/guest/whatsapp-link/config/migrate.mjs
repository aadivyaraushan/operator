export const IPHONE_WHATSAPP_PLUGIN_ID = 'operator-iphone-whatsapp-link';
export const IPHONE_WHATSAPP_PLUGIN_PATH = '/usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link';

export class WhatsAppPluginConfigRefusal extends Error {}

export function migrateIPhoneWhatsAppPluginConfig(currentConfig) {
  if (!isRecord(currentConfig)) {
    refuse('Cannot enable the iPhone WhatsApp plugin because openclaw.json must contain an object.');
  }
  const config = structuredClone(currentConfig);
  const plugins = objectAt(config, 'plugins', 'plugins must be an object before enabling the iPhone WhatsApp plugin.');

  if (plugins.enabled === false) {
    refuse('Cannot enable the iPhone WhatsApp plugin while plugins.enabled is false. Enable plugins globally first.');
  }
  if (plugins.deny !== undefined) {
    requireArray(plugins.deny, 'plugins.deny must be a list before enabling the iPhone WhatsApp plugin.');
    if (plugins.deny.includes(IPHONE_WHATSAPP_PLUGIN_ID)) {
      refuse('Cannot enable the iPhone WhatsApp plugin because plugins.deny blocks it. Remove operator-iphone-whatsapp-link from plugins.deny first.');
    }
  }

  const load = objectAt(plugins, 'load', 'plugins.load must be an object before adding the iPhone WhatsApp plugin path.');
  if (load.paths === undefined) {
    load.paths = [IPHONE_WHATSAPP_PLUGIN_PATH];
  } else {
    requireArray(load.paths, 'plugins.load.paths must be a list before adding the iPhone WhatsApp plugin path.');
    if (!load.paths.includes(IPHONE_WHATSAPP_PLUGIN_PATH)) {
      load.paths.push(IPHONE_WHATSAPP_PLUGIN_PATH);
    }
  }

  const entries = objectAt(plugins, 'entries', 'plugins.entries must be an object before enabling the iPhone WhatsApp plugin.');
  const existingEntry = entries[IPHONE_WHATSAPP_PLUGIN_ID];
  if (existingEntry !== undefined && !isRecord(existingEntry)) {
    refuse('The iPhone WhatsApp plugin entry must be an object before it can be enabled.');
  }
  if (existingEntry?.enabled === false) {
    refuse('Cannot enable the iPhone WhatsApp plugin because its entry is explicitly disabled. Enable the entry first.');
  }
  entries[IPHONE_WHATSAPP_PLUGIN_ID] = { ...existingEntry, enabled: true };

  if (plugins.allow !== undefined) {
    requireArray(plugins.allow, 'plugins.allow must be a list before enabling the iPhone WhatsApp plugin.');
    if (plugins.allow.length > 0 && !plugins.allow.includes(IPHONE_WHATSAPP_PLUGIN_ID)) {
      plugins.allow.push(IPHONE_WHATSAPP_PLUGIN_ID);
    }
  }

  return { status: 'migrated', config };
}

function objectAt(parent, key, message) {
  if (parent[key] === undefined) {
    parent[key] = {};
  }
  if (!isRecord(parent[key])) {
    refuse(`Cannot enable the iPhone WhatsApp plugin because ${message}`);
  }
  return parent[key];
}

function requireArray(value, message) {
  if (!Array.isArray(value)) {
    refuse(`Cannot enable the iPhone WhatsApp plugin because ${message}`);
  }
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function refuse(message) {
  throw new WhatsAppPluginConfigRefusal(message);
}
