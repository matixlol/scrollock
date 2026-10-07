export const downloadsPage = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Download Scrollock</title>
    <style>
      * { box-sizing: border-box; }
      html {
        color-scheme: light dark;
        --background: #f2f2f7;
        --card: #fff;
        --label: #000;
        --secondary: #6c6c70;
        --action: #007aff;
      }
      body {
        margin: 0;
        padding: 32px 20px;
        background: var(--background);
        color: var(--label);
        font: 17px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
        -webkit-text-size-adjust: 100%;
      }
      main { max-width: 540px; margin: 0 auto; }
      .brand { margin: 0 0 20px; color: var(--secondary); font-size: 15px; }
      section { padding: 24px; border-radius: 16px; background: var(--card); }
      section + section { margin-top: 16px; }
      h1 { margin: 0 0 8px; font-size: 26px; font-weight: 600; line-height: 1.25; }
      h2 { margin: 24px 0 8px; font-size: 19px; font-weight: 600; }
      p { margin: 0 0 12px; }
      p:last-child { margin-bottom: 0; }
      ol { margin: 0; padding-left: 24px; }
      li + li { margin-top: 8px; }
      a { color: var(--action); text-underline-offset: 3px; }
      a:focus-visible { outline: 2px solid var(--action); outline-offset: 4px; }
      .download {
        display: block;
        margin-top: 20px;
        padding: 12px 16px;
        border-radius: 10px;
        background: var(--action);
        color: #fff;
        text-align: center;
        text-decoration: none;
        font-weight: 600;
      }
      .hint { color: var(--secondary); font-size: 14px; }
      code { font: inherit; font-size: 15px; overflow-wrap: anywhere; }
      @media (prefers-color-scheme: dark) {
        html {
          --background: #000;
          --card: #1c1c1e;
          --label: #fff;
          --secondary: #aeaeb2;
          --action: #0a84ff;
        }
      }
    </style>
  </head>
  <body>
    <main>
      <p class="brand">Scrollock</p>
      <section aria-labelledby="title">
        <h1 id="title">Get the latest extension</h1>
        <p>Every passing build on main produces a new Chrome ZIP. This link always downloads the latest published build.</p>
        <a class="download" href="https://github.com/matixlol/scrollock/releases/latest/download/scrollock-chrome.zip">Download for Chrome</a>
        <h2>Update an existing installation</h2>
        <ol>
          <li>Download and unzip the new package.</li>
          <li>Copy its contents into the <strong>same folder you originally loaded</strong>, replacing the old files. Keep <code>manifest.json</code> directly inside that folder.</li>
          <li>Open <code>chrome://extensions</code>, enable Developer mode, and click <strong>Reload</strong> on Scrollock.</li>
          <li>Refresh your open X, Instagram, and YouTube tabs.</li>
        </ol>
        <p class="hint" style="margin-top:16px">Do not remove the extension. Replacing files and reloading preserves your saved Telegram login and settings. The popup shows your installed version.</p>
        <h2>Installing for the first time?</h2>
        <p>Unzip into a permanent folder. Open <code>chrome://extensions</code>, enable Developer mode, choose <strong>Load unpacked</strong>, and select that folder.</p>
        <p class="hint">Chrome does not automatically install these ZIP updates. <a href="https://github.com/matixlol/scrollock/releases/latest">View the latest build and release notes</a>.</p>
      </section>
      <section aria-labelledby="safari-title">
        <h2 id="safari-title" style="margin-top:0">Safari / iPhone</h2>
        <p>Update the Scrollock app through TestFlight. You can enable Automatic Updates there.</p>
        <p class="hint">The <a href="https://github.com/matixlol/scrollock/releases/latest/download/scrollock-safari.zip">Safari source ZIP</a> is for packaging a signed app, not installing directly on an iPhone.</p>
      </section>
    </main>
  </body>
</html>`;
