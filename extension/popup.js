/* global chrome, browser */
const api = globalThis.browser || chrome;
const names = {
  x: "X / Twitter",
  instagram: "Instagram",
  youtube: "YouTube",
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
    : "Telegram not connected";
  document.querySelector("#connection-copy").textContent = state.user
    ? ""
    : state.pairing
      ? "Finish login, then return here."
      : "Connect to unblock feeds.";
  document.querySelector("#connect").textContent = state.user
    ? "Reconnect"
    : state.pairing
      ? "Check login"
      : "Connect";
  for (const [site, name] of Object.entries(names)) {
    let row = document.getElementById(site);
    if (!row) {
      row = document.createElement("article");
      row.id = site;
      row.className = "site";
      row.innerHTML = `<div><strong>${name}</strong><p></p></div><button></button>`;
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
    row.classList.toggle("active", !!remaining);
    row.querySelector("p").textContent = remaining
      ? `Unblocked · ${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, "0")} left`
      : "Feed blocked";
    const button = row.querySelector("button");
    button.textContent = remaining ? "Block" : "Unblock";
    button.setAttribute(
      "aria-label",
      `${remaining ? "Block" : "Unblock"} ${name}${remaining ? "" : " for 5 minutes"}`,
    );
  }
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
