const SERIE = "SF60653";
const DIAS_HISTORICOS = 14;

function fechaMexico(ahora: Date): string {
  const partes = new Intl.DateTimeFormat("es-MX", {
    timeZone: "America/Mexico_City", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(ahora);
  const campos = Object.fromEntries(partes.map(p => [p.type, p.value]));
  return `${campos.year}-${campos.month}-${campos.day}`;
}

Deno.serve(async () => {
  try {
    const token = Deno.env.get("BANXICO_TOKEN");
    if (!token) throw new Error("Falta BANXICO_TOKEN");
    const hoy = fechaMexico(new Date());
    const inicio = new Date(Date.parse(hoy) - DIAS_HISTORICOS * 86400000).toISOString().slice(0, 10);
    const origen = `https://www.banxico.org.mx/SieAPIRest/service/v1/series/${SERIE}/datos/${inicio}/${hoy}`;
    const respuesta = await fetch(origen, {
      headers: { "Bmx-Token": token, Accept: "application/json" },
      signal: AbortSignal.timeout(15000),
    });
    if (!respuesta.ok) throw new Error(`Banxico HTTP ${respuesta.status}`);
    const resultado = await respuesta.json();
    const serie = resultado?.bmx?.series?.find((s: { idSerie: string }) => s.idSerie === SERIE);
    if (!Array.isArray(serie?.datos)) throw new Error("Banxico no devolvió la serie esperada");

    const observaciones = new Map<string, { fecha: string; valor: number; fuente: string }>();
    for (const dato of serie.datos) {
      const campos = String(dato.fecha).match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
      if (!campos) continue;
      const fecha = `${campos[3]}-${campos[2]}-${campos[1]}`;
      const valor = Number(String(dato.dato).replace(/,/g, ""));
      if (fecha < inicio || fecha > hoy || !Number.isFinite(valor) || valor <= 0) continue;
      observaciones.set(fecha, { fecha, valor, fuente: "banxico" });
    }
    const filas = [...observaciones.values()];
    if (!filas.length) throw new Error("Banxico no devolvió observaciones utilizables");

    const url = Deno.env.get("SUPABASE_URL") + "/rest/v1/tipo_cambio?on_conflict=fecha";
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!key) throw new Error("Falta la credencial de Supabase");
    async function guardar(datos: typeof filas, estrategia: "merge" | "ignore") {
      if (!datos.length) return;
      const respuesta = await fetch(url, {
        method: "POST",
        headers: {
          apikey: key!, Authorization: `Bearer ${key}`, "Content-Type": "application/json",
          "Content-Profile": "amex_requisiciones", Prefer: `resolution=${estrategia}-duplicates,return=minimal`,
        },
        body: JSON.stringify(datos),
        signal: AbortSignal.timeout(10000),
      });
      if (!respuesta.ok) throw new Error(`Supabase HTTP ${respuesta.status}`);
    }
    await guardar(filas.filter(fila => fila.fecha < hoy), "ignore");
    await guardar(filas.filter(fila => fila.fecha === hoy), "merge");
    const ultima = filas.sort((a,b) => b.fecha.localeCompare(a.fecha))[0];
    return Response.json({ ok: true, fecha: ultima.fecha, valor: ultima.valor, observaciones: filas.length });
  } catch (error) {
    return Response.json({ ok: false, error: String(error) }, { status: 500 });
  }
});
