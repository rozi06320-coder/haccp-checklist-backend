import { createServer } from "node:http";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";

async function start() {
  const config = loadBackendConfig();
  const server = createServer(createApp(config));

  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;

  server.on("clientError", (_error, socket) => {
    if (socket.writable) {
      socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, config.host, () => {
      server.off("error", reject);
      resolve();
    });
  });

  console.info(`API listening on http://${config.host}:${config.port}`);

  let shuttingDown = false;
  const shutdown = (signal: NodeJS.Signals) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.info(`Received ${signal}; closing API server.`);

    server.close((error) => {
      if (error) {
        console.error("API shutdown failed", error);
        process.exitCode = 1;
      }
    });

    setTimeout(() => {
      console.error("API shutdown timed out.");
      process.exit(1);
    }, 10_000).unref();
  };

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

start().catch((error: unknown) => {
  console.error(
    "Unable to start API",
    error instanceof Error
      ? { name: error.name, message: error.message }
      : { name: "UnknownError" },
  );
  process.exitCode = 1;
});
