// What the extension keeps in chrome.storage.local. The wallet and its scan
// progress are sealed by the Rust core (kn-store's format, the same files
// the desktop app writes); this module only moves bytes.

export interface Meta {
  /** kn-store wallet id; names the cache entry. */
  id: string;
  network: string;
}

export interface Settings {
  /** Chosen node per network. */
  nodes: Record<string, string>;
}

const enc = (bytes: Uint8Array): string => {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
};

const dec = (text: string): Uint8Array => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

export async function loadWallet(): Promise<{ meta: Meta; blob: Uint8Array } | null> {
  const { wallet, meta } = await chrome.storage.local.get(['wallet', 'meta']);
  if (typeof wallet !== 'string' || !meta) return null;
  return { meta: meta as Meta, blob: dec(wallet) };
}

export async function saveWallet(meta: Meta, blob: Uint8Array): Promise<void> {
  await chrome.storage.local.set({ wallet: enc(blob), meta });
}

export async function loadCache(id: string): Promise<Uint8Array | null> {
  const key = `cache:${id}`;
  const { [key]: cache } = await chrome.storage.local.get(key);
  return typeof cache === 'string' ? dec(cache) : null;
}

export async function saveCache(id: string, cache: Uint8Array): Promise<void> {
  await chrome.storage.local.set({ [`cache:${id}`]: enc(cache) });
}

export async function loadSettings(): Promise<Settings> {
  const { settings } = await chrome.storage.local.get('settings');
  return { nodes: {}, ...(settings as Partial<Settings> | undefined) };
}

export async function saveSettings(settings: Settings): Promise<void> {
  await chrome.storage.local.set({ settings });
}
