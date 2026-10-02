export const authorizedPage = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Telegram authorized · Scrollock</title>
    <style>
      * { box-sizing: border-box; }
      html {
        color-scheme: light dark;
        --background: #f2f2f7;
        --card: #fff;
        --label: #000;
        --secondary: #6c6c70;
        --success: #248a3d;
        --success-background: #e8f5eb;
      }
      body {
        margin: 0;
        padding: max(32px, 12vh) 20px 32px;
        background: var(--background);
        color: var(--label);
        font: 17px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        -webkit-text-size-adjust: 100%;
      }
      main { max-width: 420px; margin: 0 auto; text-align: center; }
      .brand { margin: 0 0 20px; color: var(--secondary); font-size: 15px; }
      .card { padding: 32px 24px; border-radius: 20px; background: var(--card); }
      .check {
        display: grid;
        place-items: center;
        width: 56px;
        height: 56px;
        margin: 0 auto 20px;
        border-radius: 50%;
        background: var(--success-background);
        color: var(--success);
        font-size: 28px;
      }
      h1 { margin: 0 0 12px; font-size: 24px; font-weight: 600; line-height: 1.25; }
      p { margin: 0; }
      .hint { margin-top: 20px; color: var(--secondary); font-size: 14px; }
      @media (prefers-color-scheme: dark) {
        html {
          --background: #000;
          --card: #1c1c1e;
          --label: #fff;
          --secondary: #aeaeb2;
          --success: #30d158;
          --success-background: #15351e;
        }
      }
    </style>
  </head>
  <body>
    <main>
      <p class="brand">Scrollock</p>
      <section class="card" aria-labelledby="title">
        <div class="check" aria-hidden="true">✓</div>
        <h1 id="title">Telegram authorized</h1>
        <p>Return to the Scrollock extension to finish connecting.</p>
        <p class="hint">You can close this tab.</p>
      </section>
    </main>
  </body>
</html>`;
