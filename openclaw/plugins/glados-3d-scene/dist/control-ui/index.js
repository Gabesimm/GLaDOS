// Hand-authored prebuilt Control UI bundle (no bundler step). This file is the
// literal asset declared at openclaw.plugin.json#controlUi.entry. It stays a
// small ES module: pinned Three.js modules are shipped alongside it in vendor/.
// Local imports and the meshopt decoder work without a CDN or host import map.
// The complete browser directory remains under the 4 MiB/8 MiB limits in
// docs/plugins/feature-plugins.md.
//
// Rendering logic (chamber, rig animation, core switching) is ported from the
// project's standalone Three.js test viewer at <ULTRON_ROOT>\viewer.html.


const PLUGIN_ID = "glados-3d-scene";
const MODEL_BASE = "/glados-3d-scene/models";

const CORE_NAMES = ["default", "variant1", "variant2", "variant3", "damaged"];
const STATES = {
  idle: { bodyAmp: 0.032, bodyFreq: 0.28, headAmp: 0.028, headFreq: 0.38, eyeAmp: 0.02, eyeFreq: 0.15, cableAmp: 0.02, cableFreq: 0.4, pistonAmp: 0.018, pistonFreq: 0.3 },
  listening: { bodyAmp: 0.035, bodyFreq: 0.35, headAmp: 0.03, headFreq: 0.5, eyeAmp: 0.06, eyeFreq: 0.9, cableAmp: 0.022, cableFreq: 0.6, pistonAmp: 0.02, pistonFreq: 0.5, headTilt: 0.06 },
  talking: { bodyAmp: 0.085, bodyFreq: 1.4, headAmp: 0.09, headFreq: 2.2, eyeAmp: 0.09, eyeFreq: 3.2, cableAmp: 0.065, cableFreq: 2.0, pistonAmp: 0.055, pistonFreq: 1.8 },
};

async function loadThree() {
  const THREE = await import("./vendor/three.module.js");
  const { GLTFLoader } = await import("./vendor/GLTFLoader.js");
  const { OrbitControls } = await import("./vendor/OrbitControls.js");
  const { MeshoptDecoder } = await import("./vendor/meshopt_decoder.module.js");
  // All existing rig/core assets require EXT_meshopt_compression.
  class ModelLoader extends GLTFLoader {
    constructor() { super(); this.setMeshoptDecoder(MeshoptDecoder); }
  }
  return { THREE, GLTFLoader: ModelLoader, OrbitControls };
}

function blendStates(a, b, k) {
  const out = { ...b };
  for (const key of ["bodyAmp", "headAmp", "eyeAmp", "cableAmp", "pistonAmp", "headTilt"]) {
    const av = a[key] || 0, bv = b[key] || 0;
    out[key] = av + (bv - av) * k;
  }
  return out;
}

function createSceneController(THREE, GLTFLoader, OrbitControls, canvasHost) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x0a0a0c);

  const camera = new THREE.PerspectiveCamera(60, 1, 0.01, 1000);
  camera.position.set(2, 1.5, 3);

  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  canvasHost.appendChild(renderer.domElement);
  renderer.domElement.style.width = "100%";
  renderer.domElement.style.height = "100%";
  renderer.domElement.style.display = "block";

  const controls = new OrbitControls(camera, renderer.domElement);
  controls.target.set(0, 1, 0);
  controls.update();

  scene.add(new THREE.AmbientLight(0xffffff, 0.6));
  const key = new THREE.DirectionalLight(0xffffff, 1.2);
  key.position.set(3, 5, 2);
  scene.add(key);
  const fill = new THREE.DirectionalLight(0x88aaff, 0.4);
  fill.position.set(-3, 2, -2);
  scene.add(fill);

  const rig = {};
  const cableBones = [];
  const pistonBones = [];
  const idleLook = { yaw: 0, pitch: 0, startYaw: 0, startPitch: 0, targetYaw: 0, targetPitch: 0, moveStart: 0, moveDuration: 3, nextChange: 0 };
  const idleTwitch = { active: false, timeLeft: 0, duration: 0.35, ex: 0, ey: 0, ez: 0, nextTrigger: 0 };

  let currentState = "idle";
  let prevState = "idle";
  let transitionStart = 0;
  let transitionPending = false;
  const TRANSITION_DURATION = 0.6;

  function captureBone(model, name) {
    const obj = model.getObjectByName(name);
    if (obj) rig[name] = { obj, restQuat: obj.quaternion.clone() };
  }

  function setupRig(model) {
    ["Root0_JNT", "Body0_JNT", "Body1_JNT", "Neck0_JNT", "Head0_JNT", "mainEye_JNT", "upperEye_JNT", "lowerEye_JNT"].forEach((n) => captureBone(model, n));
    model.traverse((obj) => {
      const cableMatch = obj.name.match(/^(Left|Right|Main)Cable(\d+)_JNT$/);
      if (cableMatch) cableBones.push({ obj, restQuat: obj.quaternion.clone(), side: cableMatch[1], index: parseInt(cableMatch[2], 10) });
      const pistonMatch = obj.name.match(/^(RightNeckPiston|LeftNeckPiston|NeckPistonTop|NeckPistonBtmA|NeckPistonBtmB)(\d+)_JNT$/);
      if (pistonMatch) pistonBones.push({ obj, restQuat: obj.quaternion.clone(), side: pistonMatch[1], index: parseInt(pistonMatch[2], 10) });
    });
  }

  function applyOffset(entry, ex, ey, ez) {
    if (!entry) return;
    const offset = new THREE.Quaternion().setFromEuler(new THREE.Euler(ex, ey, ez));
    entry.obj.quaternion.copy(entry.restQuat).multiply(offset);
  }

  function updateIdleLook(t, dt) {
    if (t > idleLook.nextChange) {
      idleLook.startYaw = idleLook.yaw;
      idleLook.startPitch = idleLook.pitch;
      idleLook.targetYaw = (Math.random() * 2 - 1) * 0.32;
      idleLook.targetPitch = (Math.random() * 2 - 1) * 0.08;
      idleLook.moveStart = t;
      idleLook.moveDuration = 3.0 + Math.random() * 2.0;
      const hold = 2.5 + Math.random() * 3.5;
      idleLook.nextChange = t + idleLook.moveDuration + hold;
    }
    const progress = Math.min(1, (t - idleLook.moveStart) / idleLook.moveDuration);
    const eased = progress * progress * (3 - 2 * progress);
    idleLook.yaw = idleLook.startYaw + (idleLook.targetYaw - idleLook.startYaw) * eased;
    idleLook.pitch = idleLook.startPitch + (idleLook.targetPitch - idleLook.startPitch) * eased;

    if (!idleTwitch.active && t > idleTwitch.nextTrigger) {
      idleTwitch.active = true;
      idleTwitch.timeLeft = idleTwitch.duration;
      idleTwitch.ex = (Math.random() * 2 - 1) * 0.05;
      idleTwitch.ey = (Math.random() * 2 - 1) * 0.08;
      idleTwitch.ez = (Math.random() * 2 - 1) * 0.03;
      idleTwitch.nextTrigger = t + idleTwitch.duration + 3 + Math.random() * 6;
    }
    if (idleTwitch.active) {
      idleTwitch.timeLeft -= dt;
      if (idleTwitch.timeLeft <= 0) idleTwitch.active = false;
    }
  }

  function updateRig(t, dt) {
    if (transitionPending) { transitionStart = t; transitionPending = false; }
    const transitionProgress = Math.min(1, (t - transitionStart) / TRANSITION_DURATION);
    const transitionEased = transitionProgress * transitionProgress * (3 - 2 * transitionProgress);
    const s = blendStates(STATES[prevState], STATES[currentState], transitionEased);

    const idling = currentState === "idle";
    if (idling) updateIdleLook(t, dt);
    const idleWeight = idling ? transitionEased : (prevState === "idle" ? 1 - transitionEased : 0);
    const lookYaw = idleLook.yaw * idleWeight;
    const lookPitch = idleLook.pitch * idleWeight;
    const twitchProgress = idleTwitch.active ? 1 - idleTwitch.timeLeft / idleTwitch.duration : 0;
    const twitchEase = (idleTwitch.active ? Math.sin(Math.PI * twitchProgress) : 0) * idleWeight;

    const bodySway = Math.sin(t * s.bodyFreq) * s.bodyAmp + Math.sin(t * s.bodyFreq * 2.7 + 3.1) * s.bodyAmp * 0.4;
    const bodyTwist = Math.sin(t * s.bodyFreq * 0.6 + 0.7) * s.bodyAmp * 0.7 + Math.sin(t * s.bodyFreq * 2.1 + 1.4) * s.bodyAmp * 0.3;

    applyOffset(rig.Root0_JNT, lookPitch * 0.2, bodyTwist + lookYaw * 1.0, bodySway * 0.5);
    applyOffset(rig.Body0_JNT, bodySway * 0.6 + lookPitch * 0.3, bodyTwist * 0.6 + lookYaw * 0.85, 0);
    applyOffset(rig.Body1_JNT, bodySway * 0.8 + lookPitch * 0.4, bodyTwist * 0.4 + lookYaw * 0.7, 0);

    const headSway = Math.sin(t * s.headFreq) * s.headAmp + Math.sin(t * s.headFreq * 3.3 + 1.8) * s.headAmp * 0.35;
    const headNod = Math.sin(t * s.headFreq * 1.7 + 1.0) * s.headAmp * 0.6 + Math.sin(t * s.headFreq * 4.1 + 0.5) * s.headAmp * 0.25;
    const tilt = s.headTilt || 0;
    applyOffset(rig.Neck0_JNT, headNod * 0.5 + lookPitch * 0.7, headSway * 0.5 + lookYaw * 0.9, 0);
    applyOffset(rig.Head0_JNT, headNod + lookPitch, headSway + lookYaw, tilt);

    const eyeX = Math.sin(t * s.eyeFreq) * s.eyeAmp + twitchEase * idleTwitch.ex;
    const eyeY = Math.cos(t * s.eyeFreq * 0.8) * s.eyeAmp + twitchEase * idleTwitch.ey;
    applyOffset(rig.mainEye_JNT, eyeX, eyeY, twitchEase * idleTwitch.ez);
    applyOffset(rig.upperEye_JNT, eyeX * 0.5, 0, 0);
    applyOffset(rig.lowerEye_JNT, -eyeX * 0.5, 0, 0);

    for (const c of cableBones) {
      const phase = c.index * 0.5 + (c.side === "Right" ? 1.5 : c.side === "Main" ? 3.0 : 0);
      const bend = Math.sin(t * s.cableFreq + phase) * s.cableAmp;
      applyOffset(c, bend, bend * 0.6, 0);
    }
    for (const p of pistonBones) {
      const phase = p.index * 0.8 + (p.side.includes("Right") ? 0.5 : p.side.includes("Left") ? 2.5 : 4.5);
      const bend = Math.sin(t * s.pistonFreq + phase) * s.pistonAmp;
      applyOffset(p, bend * 0.5, 0, bend);
    }
  }

  const CORE_OFFSET = { x: 115, y: 20, z: -10 };
  const coreMeshes = {};
  let currentCore = "default";

  function loadCores() {
    const coreLoader = new GLTFLoader();
    for (const name of CORE_NAMES) {
      coreLoader.load(`${MODEL_BASE}/core_${name}.glb`, (gltf) => {
        if (disposed) { disposeObject(gltf.scene); return; }
        const obj = gltf.scene;
        obj.position.set(CORE_OFFSET.x, CORE_OFFSET.y, CORE_OFFSET.z);
        obj.rotation.y = Math.PI;
        obj.visible = name === currentCore;
        if (rig.Neck0_JNT) rig.Neck0_JNT.obj.add(obj);
        coreMeshes[name] = obj;
      }, undefined, () => {});
    }
  }

  function setCore(name) {
    if (!CORE_NAMES.includes(name)) return;
    currentCore = name;
    for (const n of CORE_NAMES) if (coreMeshes[n]) coreMeshes[n].visible = n === currentCore;
  }

  function setState(next) {
    if (next === currentState || !STATES[next]) return;
    prevState = currentState;
    currentState = next;
    transitionPending = true;
  }

  function disposeObject(object) {
    const textures = new Set();
    object.traverse((obj) => {
      obj.geometry?.dispose();
      for (const material of (Array.isArray(obj.material) ? obj.material : [obj.material])) {
        if (!material) continue;
        for (const value of Object.values(material)) if (value?.isTexture) textures.add(value);
        material.dispose();
      }
    });
    for (const texture of textures) texture.dispose();
  }

  let ready = false;
  let disposed = false;
  const loader = new GLTFLoader();
  const roomStatus = document.createElement("div");
  roomStatus.style.cssText = "position:absolute;top:12px;left:12px;color:#cde;font:13px monospace;pointer-events:none";
  roomStatus.textContent = "Loading chamber…";
  canvasHost.appendChild(roomStatus);
  loader.load(`${MODEL_BASE}/glados_model.glb`, (gltf) => {
    if (disposed) { disposeObject(gltf.scene); return; }
    const model = gltf.scene;
    scene.add(model);
    // Bounds of skinned meshes require the complete rest-pose world matrices.
    model.updateMatrixWorld(true);

    const box = new THREE.Box3().setFromObject(model);
    const size = box.getSize(new THREE.Vector3());
    const center = box.getCenter(new THREE.Vector3());

    model.updateMatrixWorld(true);
    // Keep the rig in its authored coordinates. Move only the separate room.
    // Root0_JNT is a moving body bone, not the fixed ceiling pole.
    const support = model.getObjectByName("GLaDOS_base_ARM");
    const supportBox = new THREE.Box3().setFromObject(support || model);
    const attachment = supportBox.getCenter(new THREE.Vector3());
    attachment.y = supportBox.max.y;
    const height = size.y;
    // Export datum: support top at Blender Z=5.58583355; main floor Z=-4.229.
    // Leave 15% of rig height below the head for floor clearance.
    const roomScale = height * 1.15 / (5.58583355 + 4.229);
    controls.target.set(center.x, box.min.y + height * 0.17, center.z + height * 0.10);
    // Stay inside the authored inner wall; a wider lens includes head and mount.
    camera.position.set(attachment.x + height * 0.28, box.min.y + height * 0.13, attachment.z + height * 0.41);
    camera.near = height / 500;
    camera.far = height * 60;
    camera.updateProjectionMatrix();
    controls.maxDistance = height * 1.5;
    controls.minDistance = height * 0.12;
    controls.maxPolarAngle = Math.PI * 0.82;
    controls.update();

    loader.load(MODEL_BASE + '/chamber_room.glb?v=1', (roomGltf) => {
      if (disposed) { disposeObject(roomGltf.scene); return; }
      const room = roomGltf.scene;
      room.name = "Packed chamber room";
      room.scale.setScalar(roomScale);
      room.position.copy(attachment);
      scene.add(room);
      roomStatus.remove();
    }, undefined, (err) => {
      if (disposed) return;
      roomStatus.textContent = "Chamber failed to load. Reload to retry.";
      console.error("[glados-3d-scene] chamber load failed", err);
    });
    setupRig(model);
    loadCores();
    ready = true;
  }, undefined, (err) => {
    console.error("[glados-3d-scene] model load failed", err);
  });

  const clock = new THREE.Clock();
  let rafId = 0;
  function animate() {
    rafId = requestAnimationFrame(animate);
    const dt = clock.getDelta();
    if (ready) updateRig(clock.getElapsedTime(), dt);
    controls.update();
    renderer.render(scene, camera);
  }
  animate();

  function resize() {
    const w = canvasHost.clientWidth || 1;
    const h = canvasHost.clientHeight || 1;
    camera.aspect = w / h;
    // Keep GLaDOS left of the floating chat without rotating the rig.
    camera.setViewOffset(w, h, Math.min(420, w * 0.38) * 0.5, 0, w, h);
    camera.updateProjectionMatrix();
    renderer.setSize(w, h, false);
  }
  const resizeObserver = new ResizeObserver(resize);
  resizeObserver.observe(canvasHost);
  resize();

  return {
    setState,
    setCore,
    dispose() {
      disposed = true;
      cancelAnimationFrame(rafId);
      resizeObserver.disconnect();
      controls.dispose();
      disposeObject(scene);
      roomStatus.remove();
      renderer.dispose();
      renderer.domElement.remove();
    },
  };
}

function buildOverlayUI(root, controller) {
  const bar = document.createElement("div");
  bar.style.cssText = "position:absolute;bottom:12px;left:50%;transform:translateX(-50%);display:flex;gap:8px;z-index:5;font-family:monospace;";
  const states = ["idle", "listening", "talking"];
  for (const s of states) {
    const btn = document.createElement("button");
    btn.textContent = s;
    btn.style.cssText = "padding:6px 12px;border-radius:6px;border:1px solid #5a5;background:#113;color:#9fe;cursor:pointer;font-size:12px;";
    btn.addEventListener("click", () => controller.setState(s));
    bar.appendChild(btn);
  }
  root.appendChild(bar);

  const coreBar = document.createElement("div");
  coreBar.style.cssText = "position:absolute;bottom:52px;left:50%;transform:translateX(-50%);display:flex;gap:8px;z-index:5;font-family:monospace;";
  for (const c of CORE_NAMES) {
    const btn = document.createElement("button");
    btn.textContent = c;
    btn.style.cssText = "padding:5px 10px;border-radius:6px;border:1px solid #a5a;background:#213;color:#fbf;cursor:pointer;font-size:11px;";
    btn.addEventListener("click", () => controller.setCore(c));
    coreBar.appendChild(btn);
  }
  root.appendChild(coreBar);
}

export default {
  id: PLUGIN_ID,
  activate(host) {
    const disposers = [];

    disposers.push(
      host.ui.registerReplacement("workspace", {
        id: `${PLUGIN_ID}/chamber`,
        label: "GLaDOS 3D Chamber",
        async mount(container, context) {
          container.style.position = "relative";
          container.style.width = "100%";
          container.style.height = "100%";
          container.style.overflow = "hidden";
          container.style.background = "#0a0a0c";

          const canvasHost = document.createElement("div");
          canvasHost.style.cssText = "position:absolute;inset:0;";
          container.appendChild(canvasHost);

          // Composes the existing built-in chat instead of replacing it: it is
          // mounted as a floating panel over the 3D chamber, per the SDK's
          // documented context.mountDefault() composition pattern.
          const chatPanel = document.createElement("div");
          chatPanel.style.cssText =
            "position:absolute;top:12px;right:12px;bottom:12px;width:min(420px,38%);z-index:4;" +
            "background:rgba(10,10,14,0.82);border:1px solid #2a2a32;border-radius:10px;overflow:hidden;" +
            "box-shadow:0 8px 32px rgba(0,0,0,0.5);backdrop-filter:blur(6px);";
          container.appendChild(chatPanel);

          let sceneController = null;
          let defaultHandle = null;

          try {
            defaultHandle = context.mountDefault(chatPanel);
          } catch (err) {
            console.error("[glados-3d-scene] failed to mount built-in chat", err);
          }

          try {
            const { THREE, GLTFLoader, OrbitControls } = await loadThree();
            sceneController = createSceneController(THREE, GLTFLoader, OrbitControls, canvasHost);
            buildOverlayUI(container, sceneController);
          } catch (err) {
            console.error("[glados-3d-scene] failed to initialize 3D scene", err);
            canvasHost.textContent = "GLaDOS 3D scene failed to load; see console.";
            canvasHost.style.color = "#f88";
            canvasHost.style.padding = "16px";
          }

          return {
            update() {
              // Composed built-in chat re-renders itself via its own host
              // subscriptions; nothing extra to do here on host updates.
            },
            dispose() {
              sceneController?.dispose();
              defaultHandle?.dispose?.();
              container.innerHTML = "";
            },
          };
        },
      })
    );

    return {
      dispose() {
        for (const d of disposers) d();
      },
    };
  },
};
