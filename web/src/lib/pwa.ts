export function shouldRegisterServiceWorker(
  isProduction = import.meta.env.PROD,
  hasServiceWorker = typeof navigator !== "undefined" && "serviceWorker" in navigator
): boolean {
  return isProduction && hasServiceWorker;
}

export function registerServiceWorker(): void {
  if (!shouldRegisterServiceWorker()) return;
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js").catch((error: unknown) => {
      console.warn("Rubien Web service worker registration failed", error);
    });
  });
}
