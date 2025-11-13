class DavSettings {
  /**
   * @param {string[]} knownDavs
   */
  constructor (knownDavs) {
    this.knownDavs = knownDavs
  }
}

/**
 * @param {string} currentUrl
 * @param {string[]} knownDavs
 * @returns {int}
 */
function isKnown (currentUrl, knownDavs) {
  let knownIdx = knownDavs.findIndex((val) => currentUrl.startsWith(val))
  console.log('search for ', currentUrl, ' in list of knownDavs ', knownDavs, ' knownIdx: ', knownIdx)
  return knownIdx
}

const webDavSettings = new DavSettings([])

chrome.storage.local.get().then((storedWebDavSettings) => {
  Object.assign(webDavSettings, storedWebDavSettings)
})

chrome.storage.onChanged.addListener((changes, area) => {
  console.log('storage changed ', area, changes)
  if (area === 'local' && changes.knownDavs) {
    webDavSettings.knownDavs = changes.knownDavs.newValue
    console.log('webDavSettings.knownDavs', webDavSettings.knownDavs)
  }
})

function urlHasDav (url) {
  return url.includes('//dav.') || url.includes('//webdav.') ||
         url.includes('/dav/') || url.includes('/webdav/') ||
         url.includes('//svn.')
}

function suggester (status) {
  if (!(status.type === 'main_frame' && status.method === 'GET')) {
    return
  }

  let noHtmlReturned = status.statusCode === 403 || status.statusCode === 405

  const isFileRegex = /\.[a-zA-Z0-9]{2,5}$/;
  if (noHtmlReturned && urlHasDav(status.url) && !status.url.endsWith('/') && !isFileRegex.test(status.url)) {
    console.log('Initial load: Detected directory with missing slash. Redirecting...');
    chrome.tabs.update(status.tabId, { url: status.url + '/' });
    return;
  }

  if (isDav(status)) {
    insertWebdavJs(status.tabId)
    return
  }
  
  if (noHtmlReturned || urlHasDav(status.url)) {
    console.log('High chance of DAV')
    insertWebdavJs(status.tabId)
  }
}

function isDav (status) {
  if (status.responseHeaders && status.responseHeaders['DAV']) {
    console.log('Has DAV header')
    return true
  }
  let knownIdx = isKnown(status.url, webDavSettings.knownDavs)
  return knownIdx >= 0
}

chrome.webRequest.onCompleted.addListener(
  suggester,
  { urls: ['<all_urls>'] },
  ['responseHeaders']
)

async function insertWebdavJs (tabId) {
  // VERIFICA SE A UI JÁ EXISTE ANTES DE INJETAR
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId: tabId },
      func: () => window.webdavUiInitialized,
    });
    
    // Se a UI já foi inicializada (resultado é true), não faz nada.
    if (results[0].result) {
      console.log('WebDAV UI already injected, skipping.');
      return;
    }
  } catch (e) {
    console.log('Cannot execute script in this tab, probably a system page.');
    return;
  }

  // Se a UI não existe, define a flag e injeta os scripts.
  chrome.scripting.executeScript({
    target: { tabId: tabId },
    func: () => { window.webdavUiInitialized = true; },
  });

  chrome.scripting.executeScript({
    target: { tabId: tabId },
    files: ['webdav-min.js']
  });
  chrome.scripting.insertCSS({
    target: { tabId: tabId },
    files: ['style-min.css'],
  });
  chrome.scripting.executeScript({
    target: { tabId: tabId },
    files: ['loadWebdavJs.js']
  });
}

chrome.webNavigation.onHistoryStateUpdated.addListener(
  (details) => {
    let knownIdx = isKnown(details.url, webDavSettings.knownDavs);
    if (knownIdx < 0) return;

    const isFileRegex = /\.[a-zA-Z0-9]{2,5}$/;
    if (isFileRegex.test(details.url)) {
      console.log('Internal navigation to a file detected, ignoring.');
      return;
    }
    
    // Reseta a flag para permitir a injeção na nova "página"
    chrome.scripting.executeScript({
      target: { tabId: details.tabId },
      func: () => { window.webdavUiInitialized = false; },
    });

    if (details.url.endsWith('/')) {
      console.log('History state updated on a known DAV Directory, re-injecting script.');
      insertWebdavJs(details.tabId);
    } else {
      console.log('Internal navigation to directory with missing slash. Correcting URL.');
      chrome.tabs.update(details.tabId, { url: details.url + '/' });
    }
  }
);
