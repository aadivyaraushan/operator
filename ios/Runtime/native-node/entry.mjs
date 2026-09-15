import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {startEmbeddedRuntime} from './host/start.mjs';
import {installSegmenterFallback} from './compat/intl/segmenter.mjs';

// Returning from embedded Node must not terminate the containing iOS app,
// including when startup fails and the native UI needs to display the failure.
setInterval(() => {}, 60000);
// The pinned NodeMobile has no ICU break-iterator data, so the built-in
// Intl.Segmenter crashes the process on first use. OpenClaw segments every
// reply; replace it before OpenClaw is imported (see compat/intl/segmenter.mjs).
installSegmenterFallback();
await startEmbeddedRuntime({
  stateDirectory: process.env.OPERATOR_RUNTIME_STATE_DIR,
  runtimeDirectory: path.dirname(fileURLToPath(import.meta.url)),
  gatewayToken: process.env.OPERATOR_GATEWAY_TOKEN,
  requiredGatewayPort: Number(process.env.OPERATOR_RUNTIME_GATEWAY_PORT),
  runID: process.env.OPERATOR_RUNTIME_RUN_ID,
  statusPath: process.env.OPERATOR_RUNTIME_STATUS_PATH
});
