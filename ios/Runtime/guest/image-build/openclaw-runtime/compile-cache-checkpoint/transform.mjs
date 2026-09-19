const moduleImport = 'import { createRequire } from "node:module";';
const transformedModuleImport = 'import { createRequire, flushCompileCache } from "node:module";';
const originalContext = `\tkernel.setPostAttachHandles(postAttachHandles, startupPluginRuntimeClaim);
\tstartupTrace.detail("memory.ready", collectGatewayProcessMemoryUsageMb());
\tstartupTrace.mark("ready");
\tif (sidecarStartup === "defer") log.info("gateway ready");
\tfinishGatewayRestartTrace("restart.ready", collectGatewayProcessMemoryUsageMb());`;
const transformedContext = `\tkernel.setPostAttachHandles(postAttachHandles, startupPluginRuntimeClaim);
\tstartupTrace.detail("memory.ready", collectGatewayProcessMemoryUsageMb());
\tstartupTrace.mark("compile-cache-flush-start");
\tflushCompileCache();
\tstartupTrace.mark("compile-cache-flush-end");
\tstartupTrace.mark("ready");
\tif (sidecarStartup === "defer") log.info("gateway ready");
\tfinishGatewayRestartTrace("restart.ready", collectGatewayProcessMemoryUsageMb());`;

function count(source, value) {
  return source.split(value).length - 1;
}

function unsupported() {
  throw new Error('Unsupported compile-cache checkpoint source');
}

export function transform(source) {
  if (count(source, 'startupTrace.mark("ready");') !== 1) return unsupported();
  const originalImports = count(source, moduleImport);
  const transformedImports = count(source, transformedModuleImport);
  const originalContexts = count(source, originalContext);
  const transformedContexts = count(source, transformedContext);

  if (transformedImports === 1 && originalImports === 0 && transformedContexts === 1 && originalContexts === 0) {
    const restored = source
      .replace(transformedModuleImport, moduleImport)
      .replace(transformedContext, originalContext);
    if (count(restored, moduleImport) === 1 && count(restored, originalContext) === 1 &&
        count(source, 'flushCompileCache();') === 1 &&
        count(source, 'compile-cache-flush-start') === 1 &&
        count(source, 'compile-cache-flush-end') === 1) return source;
    return unsupported();
  }

  if (originalImports !== 1 || transformedImports !== 0 || originalContexts !== 1 || transformedContexts !== 0 ||
      source.includes('flushCompileCache') || source.includes('compile-cache-flush-')) return unsupported();

  return source
    .replace(moduleImport, transformedModuleImport)
    .replace(originalContext, transformedContext);
}
