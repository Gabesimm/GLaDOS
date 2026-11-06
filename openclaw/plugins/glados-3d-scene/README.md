# glados-3d-scene

OpenClaw workspace replacement with the existing animated GLaDOS rig, selectable
personality cores, and the separately exported packed Portal 2 chamber.
The built-in chat is composed with `context.mountDefault()`.

## Files

- `index.js`: gateway-authenticated, fixed-allowlist model streaming route at
  `/glados-3d-scene/models/`. Includes `chamber_room.glb`.
- `dist/control-ui/index.js`: hand-authored renderer; no build step.
- `dist/control-ui/vendor/`: pinned Three.js 0.160.0, GLTFLoader, OrbitControls,
  BufferGeometryUtils and MeshoptDecoder with relative imports; MIT license included.
  No CDN/import-map dependency. Existing compressed rig/core files require meshopt.
- `models/chamber_room.glb`: 42,140,496 bytes, one static mesh / 96 material
  primitives, 112 embedded JPEG/PNG images, no external texture dependencies,
  skins, or animation.
- `export_room.py`: reproducible Blender export; never saves the source blend.
- `verify-room.mjs`: headless Chrome verification against the actual backend
  handler and renderer with a minimal host/chat stub.
- `room-export.json`, `room-verification.json`, `room-runtime.png`: evidence.

## Chamber conversion / alignment

Source: `<DOWNLOADS>\EDIT_sp_a2_core_PACKED.blend`.
SHA-256 before and after:
`908b5a1d0329d781ed5790c2087409cdce2dbb39f68a6293b7905a3213a6e239`.

Bundled Blender 5.2.2 exports the evaluated visible environment (1,062 meshes).
Hidden character variants and non-rendered Source tool faces are excluded.
The source's ceiling support is omitted because the existing rig already has
its own support; existing GLaDOS/core GLBs are untouched.
Source shader groups are converted to glTF Principled PBR base-color/normal
textures with conservative roughness and selected light-material emission.
Textures are capped at 1024 pixels; Source-specific shader effects are approximated.
Static geometry is joined by material and validated before export.

The exported origin is the original ceiling-support top at Blender coordinates
`[-0.00549096055, 0.08513906598, 5.58583354950]`. Blender exports Y-up.
At runtime only the room is transformed: this datum aligns to the top/center
of `GLaDOS_base_ARM`, not the moving `Root0_JNT`. Uniform scale leaves 15%
of the rig's height between its rest-pose bottom and the main floor.
Camera stays inside the authored inner wall and frames the head/core left of chat.
Bone animation, transition parameters, core offsets, and switching are unchanged.

Re-export from the Blender executable directory:

```powershell
.\blender.exe -b <DOWNLOADS>\EDIT_sp_a2_core_PACKED.blend --python-exit-code 1 --python <ULTRON_ROOT>\openclaw\plugins\glados-3d-scene\export_room.py
```

## Verification

- `openclaw plugins validate --root .`: valid.
- `node --check dist\control-ui\index.js`: passed.
- `node verify-room.mjs`: seven GLBs return HTTP 200 with model/gltf-binary;
  non-allowlisted model returns 404; room renders with textured materials;
  head-bone quaternion advances in talking state; variant2 core switches;
  no browser errors; teardown exercised.
- Screenshot visually inspected in headless Chrome. Test chat is a stub,
  not a live Control UI conversation.
- Rig animation functions/state definitions and core-switch functions compared
  with original and unchanged.

**Live deployment limitation:** unauthenticated checks of port 18789 returned
the Control UI HTML fallback (200 text/html) for both the pre-existing core
route and new chamber route, not GLB data. Thus the running gateway was not
verified to have this plugin backend registered. No gateway settings or
credentials were read/changed and no gateway restart was performed.
Port 8765 serves a separate standalone `index.html` renderer; it was not
modified because this task explicitly targeted the plugin.
Once the plugin is enabled/loaded, restart/reload it as appropriate and refresh
the Control UI to load the new browser bundle.
