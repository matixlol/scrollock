/* global chrome, browser */
const api = globalThis.browser || chrome;
const names = {
  x: ["X", "X / Twitter"],
  instagram: [
    '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4"/><circle cx="17.5" cy="6.5" r="1" fill="currentColor" stroke="none"/></svg>',
    "Instagram",
  ],
  youtube: ["▷", "YouTube"],
};
let state = {},
  busy = false;
const status = document.querySelector("#status");
async function send(type, site) {
  const result = await api.runtime.sendMessage({ type, site });
  if (!result.ok) throw new Error(result.error);
  return result;
}
function render() {
  document.querySelector("#identity").textContent = state.user
    ? `Connected as ${state.user.name}`
    : "Better together";
  document.querySelector("#connection-copy").textContent = state.user
    ? "Your friends are keeping you company."
    : state.pairing
      ? "Finish login, then return here."
      : "Connect to your friends on Telegram.";
  document.querySelector("#connect").textContent = state.user
    ? "Reconnect"
    : state.pairing
      ? "Check login"
      : "Connect";
  let active = 0;
  for (const [site, [icon, name]] of Object.entries(names)) {
    let row = document.getElementById(site);
    if (!row) {
      row = document.createElement("article");
      row.id = site;
      row.className = "site";
      row.innerHTML = `<span class="icon" aria-hidden="true">${icon}</span><div><strong>${name}</strong><p></p></div><button></button>`;
      row
        .querySelector("button")
        .addEventListener("click", () =>
          action(() =>
            send(
              state.leases?.[site]?.expiresAt > Date.now() ? "lock" : "unlock",
              site,
            ),
          ),
        );
      document.querySelector("#sites").append(row);
    }
    const remaining = Math.max(
      0,
      Math.ceil(((state.leases?.[site]?.expiresAt || 0) - Date.now()) / 1000),
    );
    active += !!remaining;
    row.classList.toggle("active", !!remaining);
    row.querySelector("p").textContent = remaining
      ? `Break · ${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, "0")} left`
      : "Feed blocked";
    const button = row.querySelector("button");
    button.textContent = remaining ? "Lock now" : "Unlock 5 min";
    button.setAttribute(
      "aria-label",
      `${remaining ? "Lock" : "Unlock"} ${name}${remaining ? "" : " for 5 minutes"}`,
    );
  }
  document.querySelector("#summary").textContent = active
    ? `${active} on a break`
    : "All quiet";
  document
    .querySelectorAll("button")
    .forEach((button) => (button.disabled = busy));
}
async function refresh() {
  state = await send("state");
  render();
}
async function action(fn) {
  if (busy) return;
  busy = true;
  status.textContent = "";
  render();
  try {
    await fn();
    await refresh();
  } catch (error) {
    status.textContent = error.message;
  } finally {
    busy = false;
    render();
  }
}
document
  .querySelector("#connect")
  .addEventListener("click", () =>
    action(() => send(state.pairing ? "poll" : "pair")),
  );
refresh().catch((error) => {
  status.textContent = error.message;
});
setInterval(() => {
  if (!busy) refresh().catch(() => {});
}, 1000);
