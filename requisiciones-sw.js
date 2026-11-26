self.addEventListener("activate", evento => {
  evento.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", evento => {
  const url = new URL(evento.request.url);
  if (evento.request.method !== "GET" || evento.request.mode !== "navigate" ||
      url.origin !== self.location.origin || !["/", "/app.html"].includes(url.pathname)) return;

  evento.respondWith(fetch(evento.request).catch(() => new Response(
    `<!doctype html><html lang="es"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Requisiciones sin conexión</title>
    <main><h1>Sin conexión</h1><p>Conéctate a internet para consultar o actualizar tus requisiciones.</p>
    <p><a href="/app.html">Reintentar</a></p></main></html>`,
    { status: 503, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } }
  )));
});
