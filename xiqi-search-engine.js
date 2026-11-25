const https = require('https');

function fetchUrl(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (X11; x86_64) XIQI-OS/1.0',
        'Accept-Language': 'pt-BR,pt;q=0.9,en;q=0.8',
        ...headers
      },
      timeout: 12000
    }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
  });
}

function decodeHtml(str) {
  return String(str || '')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

async function searchWikipedia(query) {
  try {
    const api = ["https:/","pt.wikipedia.org","w","api.php?action=query&list=search&srsearch="].join("/") +
      encodeURIComponent(query) + '&utf8=1&format=json&srlimit=3';
    const res = await fetchUrl(api);
    const json = JSON.parse(res.body);
    const items = json?.query?.search || [];
    return items.map(item => ({
      title: decodeHtml(item.title),
      snippet: decodeHtml(item.snippet),
      uri: ["https:/","pt.wikipedia.org","wiki",""].join("/") + encodeURIComponent(item.title.replace(/ /g, "_"))
    }));
  } catch {
    return [];
  }
}

async function searchWeb(query) {
  try {
    const url = ["https:/","html.duckduckgo.com","html","?q="].join("/") + encodeURIComponent(query);
    const res = await fetchUrl(url);
    const results = [];
    const blockRegex = /<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)<\/a>/gi;
    let match;
    while ((match = blockRegex.exec(res.body)) !== null && results.length < 6) {
      let rawHref = match[1];
      if (rawHref.includes('uddg=')) {
        const u = new URL(rawHref, 'https://duckduckgo.com').searchParams.get('uddg');
        if (u) rawHref = u;
      }
      if (rawHref.startsWith('http')) {
        results.push({
          title: decodeHtml(match[2]),
          snippet: decodeHtml(match[3]),
          uri: rawHref
        });
      }
    }
    return results;
  } catch {
    return [];
  }
}

async function xiqiSearch(prompt) {
  const [webResults, wikiResults] = await Promise.all([
    searchWeb(prompt),
    searchWikipedia(prompt)
  ]);

  const seen = new Set();
  const sources = [];
  const summaryLines = [];

  for (const item of [...webResults, ...wikiResults]) {
    if (!item.uri || seen.has(item.uri)) continue;
    seen.add(item.uri);
    sources.push({ title: item.title || item.uri, uri: item.uri });
    if (item.snippet) {
      summaryLines.push('• ' + item.title + ': ' + item.snippet);
    }
  }

  if (summaryLines.length === 0) {
    return {
      text: 'Nenhum resultado direto encontrado para "' + prompt + '". Tente reformular a consulta com palavras-chave mais objetivas.',
      sources: []
    };
  }

  const text = 'Resultados encontrados pelo motor próprio XIQI OS:\n\n' + summaryLines.slice(0, 6).join('\n\n');
  return { text, sources };
}

module.exports = { xiqiSearch };
