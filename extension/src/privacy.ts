// Requests to nodes carry the extension's origin: chrome-extension://<id>,
// or on Firefox a moz-extension:// address unique to the install. That tells
// a node operator the request comes from Kilonova and, on Firefox, from
// which install. A session rule removes the header from the extension's
// own requests; it needs no extra host access beyond the node's.

const RULE_ID = 1;

export async function stripOriginHeader(): Promise<void> {
  const dnr = chrome.declarativeNetRequest;
  if (!dnr?.updateSessionRules) return;
  const self = new URL(chrome.runtime.getURL('')).host;
  await dnr.updateSessionRules({
    removeRuleIds: [RULE_ID],
    addRules: [
      {
        id: RULE_ID,
        priority: 1,
        action: {
          type: chrome.declarativeNetRequest.RuleActionType.MODIFY_HEADERS,
          requestHeaders: [{ header: 'origin', operation: chrome.declarativeNetRequest.HeaderOperation.REMOVE }],
        },
        condition: {
          initiatorDomains: [self],
          resourceTypes: [chrome.declarativeNetRequest.ResourceType.XMLHTTPREQUEST],
        },
      },
    ],
  });
}
