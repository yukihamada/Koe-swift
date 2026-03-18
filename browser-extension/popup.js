function openKoe(path) {
  const status = document.getElementById('status');
  chrome.tabs.create({ url: 'koe://' + path, active: false }, () => {
    // Close the new tab immediately (it just triggered the URL scheme)
    chrome.tabs.query({}, (tabs) => {
      const newTab = tabs.find(t => t.url && t.url.startsWith('koe://'));
      if (newTab) chrome.tabs.remove(newTab.id);
    });
  });
  status.textContent = '✓ Koeに送信しました';
  setTimeout(() => window.close(), 800);
}

document.getElementById('btn-transcribe').addEventListener('click', () => openKoe('transcribe'));
document.getElementById('btn-translate').addEventListener('click', () => openKoe('translate'));
document.getElementById('btn-stop').addEventListener('click', () => openKoe('stop'));
document.getElementById('btn-settings').addEventListener('click', () => openKoe('settings'));
