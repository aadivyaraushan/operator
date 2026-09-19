# iPhone WhatsApp link plugin

This is iPhone-only source for the direct Gateway methods that start, read, and cancel a local `wacli` phone-link attempt. It is not bundled by this folder alone.

## Runtime load requirements

Provision the contents of `plugin/` as one read-only local plugin root, for example:

`/usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link`

Then add that exact path to `plugins.load.paths` in the guest's `openclaw.json` and enable the matching entry:

```json
{
  "plugins": {
    "load": {
      "paths": ["/usr/local/share/openclaw-plugins/operator-iphone-whatsapp-link"]
    },
    "entries": {
      "operator-iphone-whatsapp-link": { "enabled": true }
    }
  }
}
```

Keep the global `plugins.enabled` setting true and do not add this plugin id to `plugins.deny`. If `plugins.allow` is already a non-empty list, append `operator-iphone-whatsapp-link` to that list without removing `codex` or any other existing item. The pinned loader scans `plugins.load.paths`, but a non-empty allow list blocks a plugin that is absent from it.

The guest also needs the existing `wacli` executable on `PATH`. No account data, pair code, or login state belongs in `openclaw.json`.

## What the plugin exposes

Only these direct operator-admin Gateway methods are registered:

- `operator.whatsappLink.start`
- `operator.whatsappLink.status`
- `operator.whatsappLink.cancel`

Each caller is verified from its paired `openclaw-ios` Gateway client identity: `device.id` plus `pairedClientId`. Request parameters cannot choose an owner. Link operations are memory-only, and the temporary code is returned only from `status` to that verified owner.

## Pinned CLI result handling

With wacli0.17.1, `pair_code` can contain a hyphen (for example the upstream test's `ABCD-1234`). `connected` clears the code and means `finishing`, not confirmed completion. Only exit0 plus the final stdout envelope `{"success":true,"data":{"authenticated":true},"error":null}` confirms `linked`. Additional data fields are allowed. An `error` event becomes a redacted failure; raw messages are not returned or logged. There are no `authenticated` or `pair_code_expired` events in this pinned CLI. Final output is kept in memory, capped at64KiB, and discarded after parsing. Cancelled/failed/completed operations cannot regain a queued code.
