import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineFeaturePlugin } from "openclaw/plugin-sdk/feature-plugin";
import { defineFeatureContract } from "openclaw/plugin-sdk/feature-contract";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MODELS_DIR = path.join(__dirname, "models");

// Compressed with gltfpack (meshopt, -cc). See README.md in this plugin for
// the before/after sizes. Served from disk, never bundled into the browser
// build, because the main model alone (34.8 MB) exceeds the plugin browser
// bundle's 4 MiB per-asset / 8 MiB total limit.
const ALLOWED_MODELS = new Set([
  "glados_model.glb",
  "chamber_room.glb",
  "core_default.glb",
  "core_variant1.glb",
  "core_variant2.glb",
  "core_variant3.glb",
  "core_damaged.glb",
]);

const contract = defineFeatureContract({
  pluginId: "glados-3d-scene",
  operations: {},
  events: {},
});

export default defineFeaturePlugin({
  contract,
  name: "GLaDOS 3D Scene",
  description: "3D GLaDOS workspace replacement surface for the Control UI",
  setup(api) {
    api.registerHttpRoute({
      path: "/glados-3d-scene/models/",
      auth: "gateway",
      match: "prefix",
      handler: async (req, res) => {
        const url = new URL(req.url, "http://internal");
        const name = decodeURIComponent(
          url.pathname.replace("/glados-3d-scene/models/", "")
        );

        if (!ALLOWED_MODELS.has(name)) {
          res.statusCode = 404;
          res.end("not found");
          return true;
        }

        const filePath = path.join(MODELS_DIR, name);
        let stat;
        try {
          stat = await fs.promises.stat(filePath);
        } catch {
          res.statusCode = 404;
          res.end("not found");
          return true;
        }

        res.statusCode = 200;
        res.setHeader("Content-Type", "model/gltf-binary");
        res.setHeader("Content-Length", String(stat.size));
        // Filenames are stable per plugin version; long-lived caching avoids
        // re-fetching the multi-megabyte model on every workspace load.
        res.setHeader("Cache-Control", "public, max-age=31536000, immutable");

        await new Promise((resolve, reject) => {
          const stream = fs.createReadStream(filePath);
          stream.on("error", reject);
          stream.on("end", resolve);
          stream.pipe(res);
        });
        return true;
      },
    });
    return {};
  },
});
