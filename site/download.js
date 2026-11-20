(async () => {
  const config = window.ZALOLITE_DOWNLOAD || {};
  const links = document.querySelectorAll('[data-download]');
  const legacyLinks = document.querySelectorAll('[data-download-legacy]');
  const fileLabel = document.getElementById('dl-file');
  const versionLabel = document.getElementById('dl-version');
  const httpsUrl = value => {
    try { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url : null; }
    catch { return null; }
  };
  const customUrl = httpsUrl(config.url);
  if (customUrl) {
    links.forEach(link => { link.href = customUrl.href; });
    fileLabel.textContent = config.label || 'Bộ cài DMG';
    versionLabel.textContent = 'macOS 14 trở lên';
    return;
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 6000);
  try {
    const res = await fetch('https://api.github.com/repos/lebad280324/zalolite/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' }, signal: controller.signal,
    });
    if (!res.ok) throw new Error('Release unavailable');
    const release = await res.json();
    if (release.draft || release.prerelease) throw new Error('Stable release required');
    const assets = Array.isArray(release.assets) ? release.assets : [];
    // The page promises both Mac architectures, so never substitute an ARM-only package.
    const dmg = assets.find(asset => /^Zalolite-[\d.]+-macos-universal\.dmg$/i.test(asset.name) && asset.state === 'uploaded');
    const url = dmg && httpsUrl(dmg.browser_download_url);
    if (!url || url.origin !== 'https://github.com' || !url.pathname.startsWith('/lebad280324/zalolite/releases/download/')) throw new Error('No trusted Universal DMG');
    links.forEach(link => { link.href = url.href; });
    // The macOS 13 edition ships in the same release under its own -macos13- name.
    const legacy = assets.find(asset => /^Zalolite-[\d.]+-macos13-universal\.dmg$/i.test(asset.name) && asset.state === 'uploaded');
    const legacyUrl = legacy && httpsUrl(legacy.browser_download_url);
    if (legacyUrl && legacyUrl.origin === 'https://github.com' && legacyUrl.pathname.startsWith('/lebad280324/zalolite/releases/download/')) {
      legacyLinks.forEach(link => { link.href = legacyUrl.href; });
    }
    const size = Number.isFinite(dmg.size) && dmg.size > 0 ? ` · ${(dmg.size / 1e6).toLocaleString('vi-VN', { maximumFractionDigits: 1 })} MB` : '';
    fileLabel.textContent = `Bộ cài Universal DMG${size}`;
    versionLabel.textContent = `Phiên bản ${String(release.tag_name).replace(/^v/i, '')}`;
  } catch (_) {
    // The verified static DMG remains available if the API times out or is rate-limited.
    versionLabel.textContent = 'Bản 0.0.20 · Có thể có bản mới trên GitHub';
  } finally {
    clearTimeout(timeout);
  }
})();
