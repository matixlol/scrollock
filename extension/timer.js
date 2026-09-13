// Shared native range input with a draggable duration pill.
globalThis.ScrollockTimer = (input) => {
  input.type = "range";
  input.min = "5";
  input.max = "60";
  input.step = "5";
  const surface = document.createElement("span");
  surface.className = "scrollock-timer";
  surface.innerHTML = `<style>
    .scrollock-timer { --track:#e5e5ea; --tick:#8e8e93; position:relative; display:block; width:100%; height:76px; margin:12px 0; color:var(--secondary); user-select:none; -webkit-user-select:none; }
    .scrollock-timer::before { content:""; position:absolute; inset:0 0 auto; height:48px; border-radius:24px; background:var(--track); }
    .scrollock-timer .ticks { position:absolute; top:22px; left:44px; right:44px; display:flex; justify-content:space-between; pointer-events:none; }
    .scrollock-timer .ticks span { width:4px; height:4px; border-radius:50%; background:var(--tick); }
    .scrollock-timer input { position:absolute; inset:0 0 auto; box-sizing:border-box; width:100%; height:48px; margin:0; padding:0; opacity:0; cursor:ew-resize; touch-action:none; direction:ltr; }
    .scrollock-timer:has(input:focus-visible)::before { outline:2px solid var(--action); outline-offset:3px; }
    .scrollock-timer output { position:absolute; top:2px; left:calc(2px + (100% - 92px) * var(--position)); width:88px; height:44px; border-radius:22px; background:#fff; color:#111; display:flex; align-items:center; justify-content:center; font-size:17px; font-weight:600; font-variant-numeric:tabular-nums; box-shadow:0 1px 3px #0002; pointer-events:none; }
    .scrollock-timer small { position:absolute; top:56px; font-size:12px; pointer-events:none; }
    .scrollock-timer .maximum { right:0; } .scrollock-timer .minimum { left:0; }
    @media(prefers-color-scheme:dark) { .scrollock-timer { --track:#343438; --tick:#98989d; } }
  </style><span class="ticks" aria-hidden="true">${"<span></span>".repeat(12)}</span><small class="maximum" aria-hidden="true">60 min</small><output aria-hidden="true"></output><small class="minimum" aria-hidden="true">5 min</small>`;
  input.replaceWith(surface);
  surface.append(input);
  const update = () => {
    surface.style.setProperty("--position", (Number(input.value) - 5) / 55);
    surface.querySelector("output").textContent = `${input.value} min`;
    input.setAttribute("aria-valuetext", `${input.value} minutes`);
  };
  let grabOffset = 0;
  const drag = (event) => {
    const rect = surface.getBoundingClientRect();
    const fraction = Math.max(
      0,
      Math.min(
        1,
        (event.clientX - grabOffset - rect.left - 46) / (rect.width - 92),
      ),
    );
    input.value = String(5 + Math.round(fraction * 11) * 5);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  };
  input.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || !event.isPrimary) return;
    event.preventDefault();
    input.focus({ preventScroll: true });
    input.setPointerCapture(event.pointerId);
    const pill = surface.querySelector("output").getBoundingClientRect();
    grabOffset =
      event.clientX >= pill.left && event.clientX <= pill.right
        ? event.clientX - (pill.left + pill.width / 2)
        : 0;
    drag(event);
  });
  input.addEventListener("pointermove", (event) => {
    if (input.hasPointerCapture(event.pointerId)) drag(event);
  });
  input.addEventListener("pointerup", (event) => {
    if (!input.hasPointerCapture(event.pointerId)) return;
    drag(event);
    input.releasePointerCapture(event.pointerId);
    input.dispatchEvent(new Event("change", { bubbles: true }));
  });
  input.addEventListener("input", update);
  update();
};
