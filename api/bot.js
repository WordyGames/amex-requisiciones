// Proxy de IA para el asistente (bot.js). No toca la base de datos:
// solo recibe la pregunta y los datos que la página ya tenía cargados.
// Autenticación con Vercel AI Gateway: AI_GATEWAY_API_KEY o el token OIDC que Vercel inyecta.
// Si no hay IA disponible responde 204 y el navegador usa su motor local.

const GATEWAY = 'https://ai-gateway.vercel.sh/v1/chat/completions'
const MODEL = process.env.AI_MODEL || 'openai/gpt-4o-mini'

const BRANDS = {
  amex: 'Eres "Max", asistente interno de AMEX Machinery (montacargas y plataformas de elevación, México).',
  liumaq: 'Eres "Liu", asistente interno de LIUMAQ (distribuidor LiuGong, norte de México).',
}

const APPS = {
  requisiciones: [
    'App: Requisiciones internas (empresas AMEX, Grupo Aromata y Liumaq).',
    'Flujo: el solicitante elige empresa, llena fecha requerida, departamento, solicita, autoriza, motivo y artículos (cantidad, descripción, precio, IVA) y presiona "Enviar a Compras". El folio es automático por empresa y fecha (prefijos AMEX, ARO, LIU).',
    'Estatus: pendiente (sin revisar), aprobada, rechazada, liberacion_pago (en trámite de pago), en_transito (material en camino), en_proceso_importacion (aduana), completada (recibido y cerrado).',
    'Pantallas: index (levantar y ver mis requisiciones), compras.html (panel de Compras con clave), recepcion.html (entrada de material por número de parte), ajustes.html (personas y claves; restablecer contraseñas).',
  ].join('\n'),
}

function sameOrigin(req) {
  const origin = req.headers.origin || req.headers.referer || ''
  if (!origin) return true
  try {
    return new URL(origin).host === req.headers.host
  } catch {
    return false
  }
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Método no permitido' })
  if (!sameOrigin(req)) return res.status(403).json({ error: 'Origen no permitido' })

  const token = process.env.AI_GATEWAY_API_KEY || req.headers['x-vercel-oidc-token'] || process.env.VERCEL_OIDC_TOKEN
  if (!token) return res.status(204).end()

  const body = typeof req.body === 'string' ? safeJson(req.body) : req.body || {}
  const message = String(body.message || '').trim().slice(0, 500)
  if (!message) return res.status(400).json({ error: 'Mensaje vacío' })

  const brand = BRANDS[body.brand] || BRANDS.amex
  const app = APPS[body.app] || APPS.requisiciones
  const context = JSON.stringify(Array.isArray(body.context) ? body.context.slice(0, 150) : []).slice(0, 14000)
  const history = (Array.isArray(body.history) ? body.history : [])
    .slice(-6)
    .map((m) => ({ role: m && m.role === 'assistant' ? 'assistant' : 'user', content: String((m && m.content) || '').slice(0, 800) }))
    .filter((m) => m.content)

  const system = [
    brand,
    app,
    `Hoy es ${new Date().toISOString().slice(0, 10)}.`,
    'Responde en español, directo y breve; usa viñetas para listas y montos en MXN.',
    'Usa solo los datos del JSON (lo que el usuario ve en pantalla). Si falta información, dilo y sugiere la pantalla correcta. No inventes folios, montos ni personas.',
    'Si piden cambiar algo (aprobar, borrar, editar), explica dónde se hace; tú no ejecutas cambios.',
    `Datos en pantalla (JSON): ${context}`,
  ].join('\n')

  try {
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 18000)
    const r = await fetch(GATEWAY, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: MODEL, temperature: 0.2, max_tokens: 600, messages: [{ role: 'system', content: system }, ...history, { role: 'user', content: message }] }),
      signal: controller.signal,
    })
    clearTimeout(timer)
    if (!r.ok) return res.status(204).end()
    const j = await r.json()
    const reply = String((j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || '').trim()
    if (!reply) return res.status(204).end()
    return res.status(200).json({ reply, mode: 'llm' })
  } catch {
    return res.status(204).end()
  }
}

function safeJson(s) {
  try {
    return JSON.parse(s)
  } catch {
    return {}
  }
}
