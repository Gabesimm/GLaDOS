# glados-3d-scene

An OpenClaw control-UI plugin that replaces the default workspace with an animated 3D GLaDOS
scene (Three.js) with idle, listening and talking states. The built-in chat is composed in with
`context.mountDefault()`.

## Files

- `index.js`: the plugin backend. It serves 3D model files from a fixed allowlist at
  `/glados-3d-scene/models/`, behind the gateway's authentication. Models are streamed from disk
  because they are larger than the plugin browser bundle's per-asset limit.
- `dist/control-ui/index.js`: the renderer, hand-written with no build step.
- `openclaw.plugin.json`, `package.json`: the plugin manifest and package metadata.

## Models are not included

The GLaDOS, core and chamber models were exported from Portal 2 and belong to Valve, so they are
not in this repository. Without them the plugin has nothing to render. To run the 3D scene, supply
your own `.glb` files with the names listed in `ALLOWED_MODELS` in `index.js`, in a `models/`
folder next to it. Three.js and its loaders (`dist/control-ui/vendor/`) are also not included;
install a pinned Three.js release there.
