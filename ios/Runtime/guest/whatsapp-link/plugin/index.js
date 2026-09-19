import {
  createWacliProcess,
  registerWhatsAppLinkGatewayMethods,
  WacliPhoneLinkService,
} from "./runtime/service.js";

export default {
  id: "operator-iphone-whatsapp-link",
  name: "Operator iPhone WhatsApp linking",
  description: "Shows a temporary WhatsApp phone-link code only to its paired iPhone owner.",
  register(api) {
    registerWhatsAppLinkGatewayMethods(api, new WacliPhoneLinkService({ startProcess: createWacliProcess }));
  },
};
