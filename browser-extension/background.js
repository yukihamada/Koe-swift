// Background service worker — handles toolbar icon click (no popup fallback)
chrome.action.onClicked.addListener((tab) => {
  // Fallback: if popup is not shown, open koe://transcribe directly
  chrome.tabs.create({ url: 'koe://transcribe', active: false }, (newTab) => {
    setTimeout(() => {
      if (newTab && newTab.id) chrome.tabs.remove(newTab.id);
    }, 500);
  });
});
