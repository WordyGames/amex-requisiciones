/* Asistente flotante para apps estáticas del grupo (AMEX / LIUMAQ).
   Uso: <script src="bot.js" data-brand="amex" data-app="requisiciones" defer></script>
   - Responde con los datos que la página YA tiene cargados (no consulta la base por su cuenta).
   - Si /api/bot está disponible (Vercel AI Gateway), usa IA; si no, responde con el motor local. */
(function () {
  'use strict'
  if (window.__grupoBot) return
  window.__grupoBot = true

  var script = document.currentScript || document.querySelector('script[src*="bot.js"]')
  var BRAND = (script && script.dataset.brand) || 'amex'
  var APP = (script && script.dataset.app) || 'requisiciones'
  var ENDPOINT = (script && script.dataset.endpoint) || '/api/bot'

  var THEMES = {
    amex: { name: 'Max', company: 'AMEX Machinery', accent: '#FF5808', accentDark: '#E04A00', ink: '#3D261C', soft: '#FFEFE6', body: "'DM Sans', system-ui, sans-serif", radius: '8px' },
    liumaq: { name: 'Liu', company: 'LIUMAQ', accent: '#F26A1B', accentDark: '#CE5510', ink: '#0F0F0F', soft: '#F2F0EC', body: "'Inter', system-ui, sans-serif", radius: '4px' },
  }
  var T = THEMES[BRAND] || THEMES.amex

  // ------------------------------------------------------------ utilidades
  function norm(s) { return String(s == null ? '' : s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim() }
  function money(n) { var v = Number(n) || 0; return '$' + v.toLocaleString('es-MX', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c] }) }
  function md(s) { return esc(s).replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>').replace(/\n/g, '<br>') }
  // Lee una variable global de la página (let/const de scripts clásicos) sin romper si no existe.
  function readGlobal(name) {
    try { return Function('return typeof ' + name + ' !== "undefined" ? ' + name + ' : null')() } catch (e) { return null }
  }

  // ------------------------------------------------------------ conocimiento por app
  var ESTATUS = {
    pendiente: 'Pendiente: Compras aún no la revisa.',
    aprobada: 'Aprobada: Compras la autorizó y procede la compra.',
    rechazada: 'Rechazada: no procede; revisa el comentario de Compras.',
    liberacion_pago: 'Liberación de pago: aprobada y en trámite de pago al proveedor.',
    en_transito: 'En tránsito: el material ya viene en camino.',
    en_proceso_importacion: 'En proceso de importación: el material está en aduana/importación.',
    completada: 'Completo: el material se recibió y la requisición quedó cerrada.',
  }
  var LABEL = { pendiente: 'Pendiente', aprobada: 'Aprobada', rechazada: 'Rechazada', liberacion_pago: 'Liberación de pago', en_transito: 'En tránsito', en_proceso_importacion: 'En proceso de importación', completada: 'Completo' }

  var APPS = {
    requisiciones: {
      title: 'Requisiciones',
      prompts: ['¿Cómo hago una requisición?', 'Mis requisiciones pendientes', '¿Qué significa cada estatus?', 'Total de lo aprobado'],
      guide: [
        [/(como|donde).*(hago|crear|nueva|levantar|capturar).*(requisicion|pedido|solicitud)|nueva requisicion/, 'Para levantar una requisición:\n1. Elige la empresa arriba (AMEX, Aromata o Liumaq); el folio se asigna solo.\n2. Llena fecha requerida, departamento, quién solicita y quién autoriza, y el motivo.\n3. Agrega cada artículo (cantidad, descripción, precio). Marca si incluye IVA.\n4. Presiona **Enviar a Compras**. La verás en tu historial con estatus Pendiente.'],
        [/(estatus|status|significa|significado)/, function () { return 'Estatus de una requisición:\n' + Object.keys(ESTATUS).map(function (k) { return '• ' + ESTATUS[k] }).join('\n') }],
        [/(folio)/, 'El folio se genera automáticamente por empresa y fecha (prefijo AMEX, ARO o LIU). Si cambias la empresa o la fecha antes de enviar, se recalcula.'],
        [/(iva)/, 'Marca "Incluye IVA" si los precios capturados ya traen IVA; si no, el sistema suma 16% al subtotal para el total.'],
        [/(compras|aprobar|autorizar|panel)/, 'El panel de **Compras** (compras.html) requiere la clave de Compras. Ahí se aprueban, rechazan y actualizan estatus, con nota interna y comentario para el solicitante.'],
        [/(recepcion|entrada|recibir|material llego|escanear)/, 'La **Entrada de material** (recepcion.html) registra lo que llega: crea la recepción con la referencia, captura o escanea cada número de parte y el sistema marca lo recibido.'],
        [/(imprimir|pdf|formato)/, 'Desde tu historial abre la requisición y usa **Imprimir**; sale con el membrete de la empresa seleccionada.'],
        [/(contrasena|password|clave|acceso|usuario)/, 'Si olvidaste tu contraseña, pide a un administrador que la restablezca en **Ajustes → Personas**. Al entrar te pedirá cambiarla.'],
      ],
      collect: function () {
        var list = readGlobal('rows') || readGlobal('history') || []
        if (!Array.isArray(list)) list = []
        return list.slice(0, 150).map(function (r) {
          return { folio: r.folio, empresa: r.empresa, fecha: r.fecha, requerida: r.fecha_requerida, depto: r.depto, solicita: r.solicita, motivo: String(r.motivo || '').slice(0, 80), estatus: r.estatus, total: Number(r.total) || 0, comentario: String(r.comentario_solicitante || '').slice(0, 80) }
        })
      },
    },
  }
  var CFG = APPS[APP] || APPS.requisiciones

  // ------------------------------------------------------------ motor local
  function localReply(q) {
    var n = norm(q)
    for (var i = 0; i < CFG.guide.length; i++) {
      var g = CFG.guide[i]
      if (g[0].test(n)) return typeof g[1] === 'function' ? g[1]() : g[1]
    }
    var data = CFG.collect()
    if (/^(hola|buenas|que tal|hey)\b/.test(n)) return 'Hola, soy ' + T.name + ', el asistente de ' + T.company + '. Pregúntame cómo hacer una requisición, qué significa un estatus o pídeme un resumen de tus requisiciones.'
    if (!data.length) return 'Todavía no veo requisiciones cargadas en esta pantalla. Inicia sesión o abre tu historial y vuelve a preguntar. También puedo explicarte cómo levantar una requisición o qué significa cada estatus.'

    var folio = (q.match(/[A-Za-z]{2,5}-?\s?\d[\w-]*/) || [])[0]
    if (folio) {
      var f = norm(folio).replace(/\s/g, '')
      var hit = data.filter(function (r) { return norm(r.folio).replace(/\s/g, '').indexOf(f) >= 0 })
      if (hit.length) return hit.slice(0, 3).map(function (r) { return '**' + r.folio + '** · ' + (LABEL[r.estatus] || r.estatus) + '\n' + (r.motivo || 'sin motivo') + ' · ' + money(r.total) + (r.requerida ? ' · requerida ' + r.requerida : '') + (r.comentario ? '\nComentario de Compras: ' + r.comentario : '') }).join('\n\n')
    }
    var byStatus = {}
    data.forEach(function (r) { (byStatus[r.estatus] = byStatus[r.estatus] || []).push(r) })
    var ALIAS = { pendiente: ['pendiente'], aprobada: ['aprobad'], rechazada: ['rechazad'], liberacion_pago: ['liberacion', 'pago'], en_transito: ['transito', 'camino'], en_proceso_importacion: ['importacion', 'aduana'], completada: ['complet', 'cerrad', 'recibid'] }
    var wanted = Object.keys(ALIAS).filter(function (k) { return ALIAS[k].some(function (a) { return n.indexOf(a) >= 0 }) })
    if (wanted.length) {
      return wanted.map(function (k) {
        var l = byStatus[k] || []
        var tot = l.reduce(function (a, r) { return a + r.total }, 0)
        return '**' + LABEL[k] + '**: ' + l.length + (l.length ? ' (' + money(tot) + ')\n' + l.slice(0, 8).map(function (r) { return '• ' + r.folio + ' — ' + (r.motivo || '') + ' · ' + money(r.total) }).join('\n') : '')
      }).join('\n\n')
    }
    if (/(resumen|cuantas|total|estado|como van|todas)/.test(n)) {
      var total = data.reduce(function (a, r) { return a + r.total }, 0)
      return '**Resumen (' + data.length + ' requisiciones, ' + money(total) + ')**\n' + Object.keys(byStatus).map(function (k) { var l = byStatus[k]; return '• ' + (LABEL[k] || k) + ': ' + l.length + ' · ' + money(l.reduce(function (a, r) { return a + r.total }, 0)) }).join('\n')
    }
    if (/(ultima|reciente|nueva)/.test(n)) {
      var r0 = data[0]
      return 'La más reciente: **' + r0.folio + '** (' + (LABEL[r0.estatus] || r0.estatus) + ') — ' + (r0.motivo || '') + ' · ' + money(r0.total)
    }
    return 'No encontré eso. Prueba con: "mis pendientes", "resumen", un folio (ej. AMEX-0001), "¿qué significa en tránsito?" o "¿cómo hago una requisición?".'
  }

  // ------------------------------------------------------------ UI
  var css = '' +
    '.gb-btn{position:fixed;right:18px;bottom:18px;z-index:9999;display:flex;align-items:center;gap:8px;border:0;cursor:pointer;background:' + T.accent + ';color:#fff;border-radius:999px;padding:12px 16px;font:600 14px ' + T.body + ';box-shadow:0 12px 30px -12px rgba(0,0,0,.45)}' +
    '.gb-btn:hover{background:' + T.accentDark + '}' +
    '.gb-btn svg{width:20px;height:20px}' +
    '.gb-panel{position:fixed;right:18px;bottom:78px;z-index:9999;width:min(380px,calc(100vw - 24px));height:min(560px,calc(100vh - 110px));display:none;flex-direction:column;background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 24px 60px -20px rgba(0,0,0,.45);font:14px/1.5 ' + T.body + ';color:#1f1f1f;border:1px solid rgba(0,0,0,.08)}' +
    '.gb-panel.open{display:flex}' +
    '.gb-head{background:' + T.ink + ';color:#fff;padding:14px 16px;display:flex;align-items:center;justify-content:space-between}' +
    '.gb-head b{font:700 18px "Barlow Condensed",' + T.body + ';text-transform:uppercase;letter-spacing:.04em}' +
    '.gb-head small{display:block;opacity:.7;font-size:12px}' +
    '.gb-head button{background:transparent;border:0;color:#fff;font-size:22px;cursor:pointer;line-height:1}' +
    '.gb-msgs{flex:1;overflow-y:auto;padding:14px;background:#fafafa;display:flex;flex-direction:column;gap:10px}' +
    '.gb-m{max-width:88%;padding:9px 12px;border-radius:12px;word-wrap:break-word}' +
    '.gb-m.bot{background:#fff;border:1px solid #eee;align-self:flex-start}' +
    '.gb-m.me{background:' + T.accent + ';color:#fff;align-self:flex-end}' +
    '.gb-m.typing{opacity:.6;font-style:italic}' +
    '.gb-chips{display:flex;flex-wrap:wrap;gap:6px;padding:8px 12px;border-top:1px solid #eee;background:#fff}' +
    '.gb-chips button{border:1px solid ' + T.accent + ';background:' + T.soft + ';color:' + T.ink + ';border-radius:' + T.radius + ';padding:5px 9px;font:12px ' + T.body + ';cursor:pointer}' +
    '.gb-form{display:flex;gap:8px;padding:10px 12px;border-top:1px solid #eee;background:#fff}' +
    '.gb-form input{flex:1;border:1px solid #ddd;border-radius:' + T.radius + ';padding:10px 12px;font:16px ' + T.body + ';outline:none}' +
    '.gb-form input:focus{border-color:' + T.accent + ';box-shadow:0 0 0 3px ' + T.soft + '}' +
    '.gb-form button{background:' + T.accent + ';color:#fff;border:0;border-radius:' + T.radius + ';padding:0 14px;font:600 14px ' + T.body + ';cursor:pointer}' +
    '@media print{.gb-btn,.gb-panel{display:none!important}}'
  var style = document.createElement('style')
  style.textContent = css
  document.head.appendChild(style)

  var icon = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect x="4" y="8" width="16" height="12" rx="2"/><path d="M2 14h2M20 14h2M15 13v2M9 13v2"/></svg>'
  var btn = document.createElement('button')
  btn.className = 'gb-btn no-print'
  btn.type = 'button'
  btn.setAttribute('aria-label', 'Abrir asistente')
  btn.innerHTML = icon + '<span>' + T.name + '</span>'

  var panel = document.createElement('div')
  panel.className = 'gb-panel no-print'
  panel.setAttribute('role', 'dialog')
  panel.setAttribute('aria-label', 'Asistente ' + T.name)
  panel.innerHTML = '<div class="gb-head"><div><b>' + T.name + ' · Asistente</b><small>' + T.company + ' — ' + CFG.title + '</small></div><button type="button" aria-label="Cerrar">×</button></div>' +
    '<div class="gb-msgs"></div><div class="gb-chips"></div>' +
    '<form class="gb-form"><input type="text" maxlength="500" placeholder="Escribe tu pregunta…" aria-label="Pregunta"><button type="submit">Enviar</button></form>'
  document.body.appendChild(btn)
  document.body.appendChild(panel)

  var msgs = panel.querySelector('.gb-msgs')
  var chips = panel.querySelector('.gb-chips')
  var form = panel.querySelector('form')
  var input = form.querySelector('input')
  var convo = []
  var busy = false

  function add(role, text) {
    var d = document.createElement('div')
    d.className = 'gb-m ' + (role === 'user' ? 'me' : 'bot')
    d.innerHTML = role === 'user' ? esc(text) : md(text)
    msgs.appendChild(d)
    msgs.scrollTop = msgs.scrollHeight
    return d
  }
  CFG.prompts.forEach(function (p) {
    var b = document.createElement('button')
    b.type = 'button'
    b.textContent = p
    b.onclick = function () { ask(p) }
    chips.appendChild(b)
  })
  add('bot', 'Hola, soy **' + T.name + '**, el asistente de ' + T.company + '. Te ayudo con ' + CFG.title.toLowerCase() + ': cómo hacerlas, estatus y resúmenes de lo que ves en pantalla.')

  function ask(text) {
    var q = String(text || '').trim()
    if (!q || busy) return
    busy = true
    add('user', q)
    var typing = add('bot', 'Escribiendo…')
    typing.classList.add('typing')
    var local = localReply(q)
    var body = JSON.stringify({ app: APP, brand: BRAND, message: q, history: convo.slice(-6), context: CFG.collect(), localHint: local })
    var done = function (reply) {
      typing.remove()
      add('bot', reply)
      convo.push({ role: 'user', content: q }, { role: 'assistant', content: reply })
      busy = false
    }
    var ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null
    var timer = setTimeout(function () { if (ctrl) ctrl.abort() }, 20000)
    fetch(ENDPOINT, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body, signal: ctrl ? ctrl.signal : undefined })
      .then(function (r) { return r.ok ? r.json() : null })
      .then(function (j) { clearTimeout(timer); done((j && j.reply) || local) })
      .catch(function () { clearTimeout(timer); done(local) })
  }

  btn.onclick = function () { panel.classList.toggle('open'); if (panel.classList.contains('open')) input.focus() }
  panel.querySelector('.gb-head button').onclick = function () { panel.classList.remove('open') }
  form.onsubmit = function (e) { e.preventDefault(); var v = input.value; input.value = ''; ask(v) }
})()
