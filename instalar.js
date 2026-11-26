const botonInstalar = document.getElementById("instalar-app");
let instalacionPendiente;

window.addEventListener("beforeinstallprompt", evento => {
  evento.preventDefault();
  instalacionPendiente = evento;
  botonInstalar.hidden = false;
});

botonInstalar.addEventListener("click", async () => {
  const solicitud = instalacionPendiente;
  if (!solicitud) return;
  instalacionPendiente = null;
  botonInstalar.hidden = true;
  try {
    await solicitud.prompt();
  } catch (error) {
    console.warn("Usa el menú del navegador para instalar Requisiciones.", error);
  }
});

window.addEventListener("appinstalled", () => {
  instalacionPendiente = null;
  botonInstalar.hidden = true;
});

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/requisiciones-sw.js").catch(error => {
    console.warn("No se pudo activar la pantalla sin conexión.", error);
  });
}
