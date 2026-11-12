// Host access to nodes. Nothing is granted at install: the extension asks
// for one node's origin when the user picks it, from a click.

function originPattern(url: string): string {
  const u = new URL(url);
  // Match patterns take no port; the grant covers the host.
  return `${u.protocol}//${u.hostname}/*`;
}

export async function hasNodeAccess(url: string): Promise<boolean> {
  return chrome.permissions.contains({ origins: [originPattern(url)] });
}

/** Must run inside a click handler. */
export async function requestNodeAccess(url: string): Promise<boolean> {
  return chrome.permissions.request({ origins: [originPattern(url)] });
}

/**
 * Firefox closes the popup when a permission prompt opens, so the request
 * never resolves there. The wallet asks from a tab instead.
 */
export const promptClosesPopup = typeof (globalThis as { browser?: unknown }).browser !== 'undefined';
