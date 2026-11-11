/*
 * Turn KasmVNC audio on at the first click or keypress.
 *
 * The speaker button in the side menu calls audio(), which opens the
 * socket and constructs an AudioContext. Browsers only allow that from a
 * user gesture, and a second call toggles audio back off, so this hook
 * calls audio() only while no context exists.
 *
 * The desktop is a same-origin iframe. A gesture inside it does not
 * bubble to the parent, so the copy of this file in the VNC page calls
 * parent.webtopEnableAudio() in the same turn. That is the window where
 * the parent still has user activation and can start playback.
 */
(function () {
  if (window.__webtopAudioHook) return;
  window.__webtopAudioHook = true;

  var done = false;
  var docs = [];

  function onAudioButton(event) {
    var node = event && event.target;
    while (node) {
      if (node.id === "audioButton") return true;
      node = node.parentElement;
    }
    return false;
  }

  function context() {
    return window.player && window.player.audioCtx;
  }

  function webtopEnableAudio() {
    if (typeof window.audio !== "function") return false;
    var ctx = context();
    if (!ctx) {
      window.audio();
      ctx = context();
    }
    if (!ctx) return false;
    if (ctx.state !== "running" && typeof ctx.resume === "function") {
      try {
        ctx.resume();
      } catch (err) {
        /* resume can throw if the context was closed */
      }
    }
    return ctx.state === "running";
  }

  window.webtopEnableAudio = webtopEnableAudio;

  function detach() {
    docs.forEach(function (doc) {
      doc.removeEventListener("pointerdown", onGesture, true);
      doc.removeEventListener("keydown", onGesture, true);
    });
    docs = [];
    if (window.__webtopAudioObserver) {
      window.__webtopAudioObserver.disconnect();
      window.__webtopAudioObserver = null;
    }
  }

  function finish() {
    if (done) return;
    done = true;
    detach();
  }

  function enableFromHere() {
    try {
      if (
        window.parent &&
        window.parent !== window &&
        typeof window.parent.webtopEnableAudio === "function"
      ) {
        return window.parent.webtopEnableAudio();
      }
    } catch (err) {
      return false;
    }
    return webtopEnableAudio();
  }

  function onGesture(event) {
    if (done) return;
    if (onAudioButton(event)) {
      // The button's own onclick calls audio(). Do not call it twice.
      finish();
      return;
    }
    if (enableFromHere()) finish();
  }

  function attach(doc) {
    if (!doc || doc.__webtopAudioDoc) return;
    doc.__webtopAudioDoc = true;
    docs.push(doc);
    doc.addEventListener("pointerdown", onGesture, true);
    doc.addEventListener("keydown", onGesture, true);
  }

  function hookFrames() {
    var frames;
    try {
      frames = document.querySelectorAll("iframe");
    } catch (err) {
      return;
    }
    Array.prototype.forEach.call(frames, function (frame) {
      try {
        if (frame.contentDocument) attach(frame.contentDocument);
      } catch (err) {
        /* cross-origin frame */
      }
    });
  }

  function start() {
    attach(document);
    if (window.parent && window.parent !== window) return;
    hookFrames();
    if (typeof MutationObserver === "function" && document.documentElement) {
      var observer = new MutationObserver(hookFrames);
      observer.observe(document.documentElement, { childList: true, subtree: true });
      window.__webtopAudioObserver = observer;
    }
    window.addEventListener("load", hookFrames);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
