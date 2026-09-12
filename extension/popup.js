/* global chrome, browser */
const api = globalThis.browser || chrome;
const names = {
  x: "X / Twitter",
  instagram: "Instagram",
  youtube: "YouTube",
};
let state = {},
  busy = false,
  selectedSite;
const status = document.querySelector("#status");
const form = document.querySelector("#unlock-form");
async function send(type, site, fields = {}) {
  const result = await api.runtime.sendMessage({ type, site, ...fields });
  if (!result.ok) throw new Error(result.error);
  if (result.warning) status.textContent = result.warning;
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
      row.querySelector("button").addEventListener("click", () => {
        if (state.leases?.[site]?.expiresAt > Date.now())
          return action(() => send("lock", site));
        if (!state.user) {
          status.textContent = "Connect Telegram in the extension first.";
          return;
        }
        selectedSite = site;
        form.hidden = false;
        document.querySelector("#unlock-title").textContent = `Unblock ${name}`;
        document.querySelector("#reason").focus();
      });
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
      `${remaining ? "Block" : "Unblock"} ${name}`,
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
document.querySelector("#cancel").addEventListener("click", () => {
  form.hidden = true;
});
form.addEventListener("submit", (event) => {
  event.preventDefault();
  const reason = document.querySelector("#reason").value.trim();
  if (!reason) {
    status.textContent = "Enter a brief reason.";
    return;
  }
  action(async () => {
    await send("unlock", selectedSite, {
      minutes: Number(document.querySelector("#minutes").value),
      reason,
    });
    form.hidden = true;
    document.querySelector("#reason").value = "";
  });
});
if (api.runtime.getURL("").startsWith("safari-web-extension:")) {
  send("native-status")
    .then((result) => {
      const note = document.querySelector("#native-status");
      note.hidden = false;
      note.textContent = result.authorized
        ? "Screen Time connected. Manage selected apps in the iPhone app."
        : "To block installed apps too, open the iPhone app and set up Screen Time.";
    })
    .catch((error) => {
      status.textContent = error.message;
    });
}
refresh().catch((error) => {
  status.textContent = error.message;
});
setInterval(() => {
  if (!busy) refresh().catch(() => {});
}, 1000);
