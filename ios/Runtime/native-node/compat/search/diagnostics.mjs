export function patchNativeSearchDiagnostics(source) {
  const entry = 'async function* mapCodexEvents(events) {\n\tfor await (const event of events) {';
  const diagnostic = '\n\t\t// Operator completion-only diagnostic: never log provider event data.\n\t\tif (event.type === "response.web_search_call.completed" || (event.type === "response.output_item.done" && event.item?.type === "web_search_call" && event.item?.status === "completed")) getAiTransportHost().logInfo("openai-transport", "[native-search] provider search completed");';
  if (source.split(entry).length !== 2) throw new Error('ChatGPT search event contract changed');
  if (source.includes(diagnostic)) {
    if (source.split(diagnostic).length !== 2 || !source.includes(entry + diagnostic)) throw new Error('ChatGPT search diagnostic contract changed');
    return source;
  }
  if (source.includes('[native-search]')) throw new Error('ChatGPT search diagnostic contract changed');
  return source.replace(entry, entry + diagnostic);
}
