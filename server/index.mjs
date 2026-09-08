import { createServer, config } from "./server.mjs";

const cfg = config();
const server = await createServer({ config: cfg });
server.listen(cfg.port, cfg.host, () =>
  console.log(`scrollock server listening on ${cfg.host}:${cfg.port}`),
);
