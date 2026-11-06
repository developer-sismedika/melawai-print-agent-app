/// PrintAgent bridge shim — contract v1
/// (`docs/wrapper-app-architecture.md` §Bridge contract (v1), fixtures in
/// `docs/examples/bridge-v1.json`).
///
/// Injected into every APEM page at document start. Validation happens
/// HERE first (cheap, no network): the Dart handler re-validates as
/// defense in depth. All responses resolve with the envelope object —
/// `ok:false` means failure; the promise only rejects when the handler
/// transport itself is broken (page opened outside the wrapper).
///
/// D9: inline content capped at 1 MB of envelope JSON.
/// D10: single-flight per documentId — a second print while one is in
/// flight resolves with the SAME envelope (no second POST).
const String kPrintAgentShim = r'''
(function () {
  'use strict';
  if (window.PrintAgent) return;

  var CAP = 1024 * 1024; // D9: 1 MB of envelope JSON
  var PRINT_FIELDS = ['documentId', 'printerId', 'title', 'format',
                      'contentEncoding', 'content', 'artifactUrl'];
  var inflight = {}; // documentId -> Promise (D10)

  function ok(body) {
    var r = { v: 1, ok: true };
    for (var k in body) r[k] = body[k];
    return r;
  }
  function fail(code, message) {
    return { v: 1, ok: false, error: { code: code, message: message } };
  }
  function post(env) {
    if (!window.flutter_inappwebview ||
        !window.flutter_inappwebview.callHandler) {
      return Promise.reject(
        new Error('PrintAgent: not running inside the Melawai Print wrapper'));
    }
    return window.flutter_inappwebview
      .callHandler('printAgent', JSON.stringify(env))
      .then(function (raw) {
        if (typeof raw === 'string') return JSON.parse(raw);
        return raw;
      }, function (e) {
        return fail('E_JOB', 'bridge error: ' + e);
      });
  }

  function validatePrint(p) {
    if (!p || typeof p !== 'object' || Array.isArray(p)) {
      return fail('E_BAD_PAYLOAD', 'missing payload');
    }
    for (var k in p) {
      if (PRINT_FIELDS.indexOf(k) === -1) {
        return fail('E_BAD_PAYLOAD', 'unknown field: ' + k);
      }
    }
    if (typeof p.documentId !== 'string' || !p.documentId) {
      return fail('E_BAD_PAYLOAD', 'missing required field: documentId');
    }
    if (typeof p.format !== 'string' || !p.format) {
      return fail('E_BAD_PAYLOAD', 'missing required field: format');
    }
    var hasContent = typeof p.content === 'string' && p.content.length > 0;
    var hasArtifact = typeof p.artifactUrl === 'string' && p.artifactUrl.length > 0;
    if (!hasContent && !hasArtifact) {
      return fail('E_BAD_PAYLOAD', 'missing required field: content');
    }
    return null;
  }

  window.PrintAgent = {
    print: function (payload) {
      var invalid = validatePrint(payload);
      if (invalid) return Promise.resolve(invalid);
      var env = { v: 1, action: 'print', payload: payload };
      if (JSON.stringify(env).length > CAP) {
        return Promise.resolve(fail('E_PAYLOAD_TOO_LARGE',
          'inline content exceeds 1 MB bridge cap; use artifactUrl'));
      }
      var key = payload.documentId;
      if (inflight[key]) return inflight[key]; // D10 single-flight
      var p = post(env);
      inflight[key] = p;
      var clear = function () { delete inflight[key]; };
      p.then(clear, clear);
      return p;
    },
    printers: function () {
      return post({ v: 1, action: 'printers', payload: {} });
    },
    health: function () {
      return post({ v: 1, action: 'health', payload: {} });
    },
    jobStatus: function (jobId) {
      return post({ v: 1, action: 'jobStatus', payload: { jobId: jobId } });
    }
  };

  // --- PDF auto-print (D13): page-side fetch keeps session cookies. ---
  var AUTO = __AUTO_PDF_DEFAULT__;
  window.__mpaSetAutoPdf = function (v) { AUTO = !!v; };

  function fetchPdfB64(url) {
    return fetch(url, { credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) {
        var he = new Error('HTTP ' + r.status);
        he.code = 'HTTP';
        throw he;
      }
      return r.arrayBuffer();
    }).then(function (buf) {
      var u8 = new Uint8Array(buf);
      var magic = '';
      for (var i = 0; i < 4 && i < u8.length; i++) {
        magic += String.fromCharCode(u8[i]);
      }
      if (magic !== '%PDF') {
        var pe = new Error('not a PDF');
        pe.code = 'NOT_PDF';
        throw pe;
      }
      if (u8.length > 750 * 1024) {
        if (/^https?:/.test(url)) return { tooLarge: true };
        var le = new Error('PDF too large for inline print (>750 KB) and no direct URL');
        le.code = 'E_PAYLOAD_TOO_LARGE';
        throw le;
      }
      var s = '';
      var CH = 0x8000;
      for (var j = 0; j < u8.length; j += CH) {
        s += String.fromCharCode.apply(null, u8.subarray(j, j + CH));
      }
      return { b64: btoa(s) };
    });
  }

  function postPdfResult(fetchId, res, error) {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      return;
    }
    window.flutter_inappwebview.callHandler('pdfFetchResult', JSON.stringify({
      fetchId: fetchId,
      b64: res ? res.b64 : null,
      tooLarge: !!(res && res.tooLarge),
      error: error || null
    }));
  }

  // Shell-initiated capture: the result flows back through the
  // pdfFetchResult handler (portable — evaluateJavascript does not
  // await promises on iOS).
  window.__mpaFetchPdf = function (url, fetchId) {
    fetchPdfB64(url).then(function (res) {
      postPdfResult(fetchId, res, null);
    }).catch(function (e) {
      postPdfResult(fetchId, null, e && e.message ? e.message : String(e));
    });
  };

  function mpaAutoPrint(url, title) {
    fetchPdfB64(url).then(function (res) {
      var payload = {
        documentId: 'pdf-' + Date.now().toString(36) + '-' +
            Math.random().toString(36).slice(2, 12),
        format: 'application/pdf',
        title: title || 'document.pdf'
      };
      if (res.b64) {
        payload.contentEncoding = 'base64';
        payload.content = res.b64;
      } else {
        payload.artifactUrl = url;
      }
      post({ v: 1, action: 'print', payload: payload });
    }).catch(function (e) {
      postPdfResult('auto-' + Date.now().toString(36), null,
          e && e.message ? e.message : String(e));
    });
  }

  document.addEventListener('click', function (e) {
    if (!AUTO || e.defaultPrevented) return;
    var t = e.target;
    var a = (t && t.closest) ? t.closest('a[href]') : null;
    if (!a) return;
    var href = a.getAttribute('href') || '';
    var dl = a.getAttribute('download') || '';
    var typ = (a.getAttribute('type') || '').toLowerCase();
    var isBlob = href.indexOf('blob:') === 0;
    var looksPdf = /\.pdf([?#]|$)/i.test(href) ||
        /\.pdf$/i.test(dl) || typ.indexOf('pdf') !== -1;
    if (!looksPdf && !isBlob) return;
    e.preventDefault();
    e.stopPropagation();
    mpaAutoPrint(a.href || href,
        dl || (a.textContent || '').trim().slice(0, 60) || 'document.pdf');
  }, true);
})();
''';
