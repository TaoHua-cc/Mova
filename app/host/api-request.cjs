'use strict';

const DEFAULT_HEADERS = {
  Accept: 'application/json, text/plain, application/xml, text/xml, */*',
  'User-Agent': 'Yingji/2.0'
};

/**
 * Host-side HTTP boundary used by the renderer IPC handler.
 * Keeping this policy in one module makes transport replacement independent of
 * the player runtime and preserves the renderer's existing request contract.
 */
async function apiRequest(request, { electronNet, fetchImpl = globalThis.fetch } = {}) {
  const url = new URL(request.url);
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new Error('仅支持 HTTP 或 HTTPS 地址');
  }

  const controller = new AbortController();
  const timeoutMs = Math.min(60000, Math.max(5000, Number(request.timeoutMs) || 15000));
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const options = {
      method: request.method || 'GET',
      headers: { ...DEFAULT_HEADERS, ...(request.headers || {}) },
      body: request.rawBody ?? (request.body ? JSON.stringify(request.body) : undefined),
      signal: controller.signal
    };
    let response;
    try {
      response = await fetchImpl(url, options);
    } catch (error) {
      if (!electronNet?.fetch) throw error;
      response = await electronNet.fetch(url, options);
    }
    const text = await response.text();
    const data = request.responseType === 'text' ? text : text ? JSON.parse(text) : null;
    if (request.acceptErrors) return { status: response.status, data };
    if (!response.ok) throw new Error(`${response.status} ${text.slice(0, 180)}`);
    return data;
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`请求超时（${Math.round(timeoutMs / 1000)} 秒）`);
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { apiRequest };
