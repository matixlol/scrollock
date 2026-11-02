import { chromium } from "playwright";
import { readFileSync } from "node:fs";
const svg = readFileSync("extension/icons/icon.svg", "utf8").replace(' rx="224"', "");
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
await page.setContent(`<style>html,body{margin:0;background:#264d3d}</style>${svg.replace("<svg ", '<svg width="1024" height="1024" ')}`);
await page.screenshot({ path: "ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png", omitBackground: false });
await browser.close();
