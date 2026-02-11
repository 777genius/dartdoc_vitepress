"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/index.ts
var index_exports = {};
__export(index_exports, {
  addKeyboardListener: () => addKeyboardListener,
  cleanupMermaidZoom: () => cleanupMermaidZoom,
  closeDiagram: () => closeDiagram,
  setupMermaidZoom: () => setupMermaidZoom,
  useMermaidZoom: () => useMermaidZoom
});
module.exports = __toCommonJS(index_exports);

// src/zoom.ts
var DEFAULT_OPTIONS = {
  selector: ".mermaid",
  dataAttr: "zoomable"
};
var backdrop = null;
var activeDiagram = null;
var placeholder = null;
var savedScrollY = 0;
var previouslyFocused = null;
var diagramControllers = /* @__PURE__ */ new WeakMap();
function createExpandSvg() {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("width", "14");
  svg.setAttribute("height", "14");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "2");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");
  const polyline1 = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
  polyline1.setAttribute("points", "15 3 21 3 21 9");
  const line1 = document.createElementNS("http://www.w3.org/2000/svg", "line");
  line1.setAttribute("x1", "14");
  line1.setAttribute("y1", "10");
  line1.setAttribute("x2", "21");
  line1.setAttribute("y2", "3");
  const polyline2 = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
  polyline2.setAttribute("points", "9 21 3 21 3 15");
  const line2 = document.createElementNS("http://www.w3.org/2000/svg", "line");
  line2.setAttribute("x1", "10");
  line2.setAttribute("y1", "14");
  line2.setAttribute("x2", "3");
  line2.setAttribute("y2", "21");
  svg.append(polyline1, line1, polyline2, line2);
  return svg;
}
function handleBackdropClick() {
  closeDiagram();
}
function ensureBackdrop() {
  if (backdrop?.isConnected) return backdrop;
  backdrop = document.createElement("div");
  backdrop.className = "mermaid-zoom-backdrop";
  backdrop.setAttribute("role", "dialog");
  backdrop.setAttribute("aria-modal", "true");
  backdrop.setAttribute("aria-label", "Zoomed diagram");
  backdrop.setAttribute("tabindex", "-1");
  backdrop.addEventListener("click", handleBackdropClick);
  document.body.appendChild(backdrop);
  return backdrop;
}
function handleKeydown(e) {
  if (e.key === "Escape") closeDiagram();
}
function closeDiagram() {
  if (!activeDiagram || !backdrop) return;
  const svgEl = activeDiagram.querySelector(":scope > svg");
  if (svgEl) {
    const origW = activeDiagram.dataset.origSvgWidth;
    const origH = activeDiagram.dataset.origSvgHeight;
    if (origW) svgEl.setAttribute("width", origW);
    else svgEl.removeAttribute("width");
    if (origH) svgEl.setAttribute("height", origH);
    else svgEl.removeAttribute("height");
    delete activeDiagram.dataset.origSvgWidth;
    delete activeDiagram.dataset.origSvgHeight;
  }
  activeDiagram.classList.remove("mermaid-zoomed");
  activeDiagram.style.cursor = "zoom-in";
  backdrop.classList.remove("active");
  backdrop.removeAttribute("aria-label");
  document.body.style.position = "";
  document.body.style.top = "";
  document.body.style.left = "";
  document.body.style.right = "";
  document.body.style.overflow = "";
  window.scrollTo(0, savedScrollY);
  if (placeholder?.parentNode) {
    placeholder.parentNode.replaceChild(activeDiagram, placeholder);
  }
  previouslyFocused?.focus();
  previouslyFocused = null;
  activeDiagram = null;
  placeholder = null;
}
function openDiagram(diagram) {
  if (activeDiagram) return;
  const svgEl = diagram.querySelector(":scope > svg");
  if (svgEl) {
    if (!svgEl.getAttribute("viewBox")) {
      const w = parseFloat(svgEl.getAttribute("width") || String(svgEl.getBoundingClientRect().width));
      const h = parseFloat(svgEl.getAttribute("height") || String(svgEl.getBoundingClientRect().height));
      if (w > 0 && h > 0) {
        svgEl.setAttribute("viewBox", `0 0 ${w} ${h}`);
      }
    }
    diagram.dataset.origSvgWidth = svgEl.getAttribute("width") || "";
    diagram.dataset.origSvgHeight = svgEl.getAttribute("height") || "";
    svgEl.removeAttribute("width");
    svgEl.removeAttribute("height");
  }
  const bg = ensureBackdrop();
  activeDiagram = diagram;
  placeholder = document.createElement("div");
  placeholder.style.height = `${diagram.offsetHeight}px`;
  diagram.parentNode?.replaceChild(placeholder, diagram);
  bg.appendChild(diagram);
  previouslyFocused = document.activeElement;
  savedScrollY = window.scrollY;
  document.body.style.position = "fixed";
  document.body.style.top = `-${savedScrollY}px`;
  document.body.style.left = "0";
  document.body.style.right = "0";
  document.body.style.overflow = "hidden";
  requestAnimationFrame(() => {
    bg.classList.add("active");
    diagram.classList.add("mermaid-zoomed");
    diagram.style.cursor = "zoom-out";
    bg.focus();
  });
}
function setupMermaidZoom(options = {}) {
  if (typeof document === "undefined") return;
  const { selector, dataAttr } = { ...DEFAULT_OPTIONS, ...options };
  const diagrams = document.querySelectorAll(selector);
  for (const diagram of diagrams) {
    if (diagram.dataset[dataAttr] !== void 0) continue;
    diagram.dataset[dataAttr] = "true";
    diagram.style.cursor = "zoom-in";
    const controller = new AbortController();
    const { signal } = controller;
    diagramControllers.set(diagram, controller);
    const hint = document.createElement("div");
    hint.className = "mermaid-zoom-hint";
    hint.setAttribute("aria-hidden", "true");
    hint.appendChild(createExpandSvg());
    diagram.style.position = "relative";
    diagram.appendChild(hint);
    diagram.addEventListener("click", () => openDiagram(diagram), { signal });
  }
}
function cleanupMermaidZoom(options = {}) {
  if (typeof document === "undefined") return;
  closeDiagram();
  const { selector, dataAttr } = { ...DEFAULT_OPTIONS, ...options };
  const diagrams = document.querySelectorAll(selector);
  for (const diagram of diagrams) {
    if (diagram.dataset[dataAttr] === void 0) continue;
    const controller = diagramControllers.get(diagram);
    if (controller) {
      controller.abort();
      diagramControllers.delete(diagram);
    }
    const hint = diagram.querySelector(".mermaid-zoom-hint");
    hint?.remove();
    delete diagram.dataset[dataAttr];
    diagram.style.cursor = "";
    diagram.style.position = "";
  }
  if (backdrop) {
    backdrop.remove();
    backdrop = null;
  }
}
function addKeyboardListener() {
  document.addEventListener("keydown", handleKeydown);
  return () => document.removeEventListener("keydown", handleKeydown);
}

// src/composable.ts
var import_vue = require("vue");
function useMermaidZoom(pagePath, options) {
  let removeKeyboardListener;
  const run = () => (0, import_vue.nextTick)(() => setupMermaidZoom(options));
  (0, import_vue.onMounted)(() => {
    removeKeyboardListener = addKeyboardListener();
    run();
  });
  const stopWatch = (0, import_vue.watch)(pagePath, () => {
    cleanupMermaidZoom(options);
    run();
  });
  (0, import_vue.onUnmounted)(() => {
    stopWatch();
    removeKeyboardListener?.();
    cleanupMermaidZoom(options);
  });
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  addKeyboardListener,
  cleanupMermaidZoom,
  closeDiagram,
  setupMermaidZoom,
  useMermaidZoom
});
