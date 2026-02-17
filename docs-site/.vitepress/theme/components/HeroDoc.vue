<template>
  <div class="hero-doc-scene">
    <div class="hero-doc">
      <!-- Front face -->
      <div class="doc-face doc-front">
        <div class="doc-header">
          <div class="doc-dot" style="background: #ff5f57"></div>
          <div class="doc-dot" style="background: #febc2e"></div>
          <div class="doc-dot" style="background: #28c840"></div>
        </div>
        <div class="doc-body">
          <div class="doc-line kw" style="width: 35%"></div>
          <div class="doc-line type" style="width: 55%; margin-left: 8%"></div>
          <div class="doc-line" style="width: 70%; margin-left: 4%"></div>
          <div class="doc-line fn" style="width: 40%; margin-left: 8%"></div>
          <div class="doc-line" style="width: 60%; margin-left: 12%"></div>
          <div class="doc-line" style="width: 45%; margin-left: 12%"></div>
          <div class="doc-line" style="width: 30%; margin-left: 8%"></div>
          <div class="doc-spacer"></div>
          <div class="doc-line kw" style="width: 30%"></div>
          <div class="doc-line type" style="width: 50%; margin-left: 8%"></div>
          <div class="doc-line fn" style="width: 65%; margin-left: 4%"></div>
        </div>
        <div class="doc-badge">API</div>
      </div>
      <!-- Back face -->
      <div class="doc-face doc-back">
        <div class="doc-header">
          <div class="doc-dot" style="background: #ff5f57"></div>
          <div class="doc-dot" style="background: #febc2e"></div>
          <div class="doc-dot" style="background: #28c840"></div>
        </div>
        <div class="doc-body">
          <div class="doc-line" style="width: 80%"></div>
          <div class="doc-line" style="width: 65%"></div>
          <div class="doc-line" style="width: 90%"></div>
          <div class="doc-line" style="width: 50%"></div>
          <div class="doc-line" style="width: 75%"></div>
        </div>
        <div class="doc-badge guide">Guide</div>
      </div>
    </div>
    <!-- Floating particles -->
    <div class="particle p1">{}</div>
    <div class="particle p2">&lt;/&gt;</div>
    <div class="particle p3">///</div>
    <div class="particle p4">.md</div>
  </div>
</template>

<style scoped>
.hero-doc-scene {
  display: flex;
  justify-content: center;
  align-items: center;
  width: 100%;
  height: 320px;
  perspective: 800px;
  position: relative;
}

.hero-doc {
  width: 200px;
  height: 260px;
  position: relative;
  transform-style: preserve-3d;
  animation: doc-rotate 8s ease-in-out infinite;
}

.doc-face {
  position: absolute;
  inset: 0;
  border-radius: 12px;
  backface-visibility: hidden;
  padding: 16px;
  display: flex;
  flex-direction: column;
  box-shadow:
    0 20px 60px rgba(1, 117, 194, 0.15),
    0 0 40px rgba(19, 185, 253, 0.08);
}

.doc-front {
  background: linear-gradient(145deg, #1a1a2e 0%, #16213e 100%);
  border: 1px solid rgba(19, 185, 253, 0.2);
}

.doc-back {
  background: linear-gradient(145deg, #1a2e1a 0%, #162e3e 100%);
  border: 1px solid rgba(40, 200, 64, 0.2);
  transform: rotateY(180deg);
}

.doc-header {
  display: flex;
  gap: 5px;
  margin-bottom: 16px;
  padding-bottom: 10px;
  border-bottom: 1px solid rgba(255, 255, 255, 0.08);
}

.doc-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  opacity: 0.8;
}

.doc-body {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.doc-line {
  height: 6px;
  border-radius: 3px;
  background: rgba(255, 255, 255, 0.12);
}

.doc-line.kw {
  background: rgba(19, 185, 253, 0.4);
}

.doc-line.type {
  background: rgba(1, 117, 194, 0.5);
}

.doc-line.fn {
  background: rgba(84, 197, 248, 0.35);
}

.doc-spacer {
  height: 4px;
}

.doc-badge {
  position: absolute;
  bottom: 12px;
  right: 12px;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 1.5px;
  text-transform: uppercase;
  color: rgba(19, 185, 253, 0.7);
  background: rgba(19, 185, 253, 0.08);
  padding: 3px 8px;
  border-radius: 4px;
  border: 1px solid rgba(19, 185, 253, 0.15);
}

.doc-badge.guide {
  color: rgba(40, 200, 64, 0.7);
  background: rgba(40, 200, 64, 0.08);
  border-color: rgba(40, 200, 64, 0.15);
}

/* Floating particles */
.particle {
  position: absolute;
  font-size: 13px;
  font-weight: 600;
  font-family: 'SF Mono', 'Fira Code', monospace;
  opacity: 0;
  pointer-events: none;
  color: rgba(19, 185, 253, 0.5);
}

.p1 {
  top: 15%;
  right: 5%;
  animation: float-particle 8s 0s ease-in-out infinite;
}

.p2 {
  bottom: 20%;
  left: 5%;
  animation: float-particle 8s 2s ease-in-out infinite;
  color: rgba(84, 197, 248, 0.4);
}

.p3 {
  top: 25%;
  left: 8%;
  animation: float-particle 8s 4s ease-in-out infinite;
  color: rgba(40, 200, 64, 0.4);
}

.p4 {
  bottom: 15%;
  right: 8%;
  animation: float-particle 8s 6s ease-in-out infinite;
  color: rgba(1, 117, 194, 0.5);
}

@keyframes doc-rotate {
  0%, 100% {
    transform: rotateY(-15deg) rotateX(5deg);
  }
  25% {
    transform: rotateY(15deg) rotateX(-2deg) translateY(-8px);
  }
  50% {
    transform: rotateY(195deg) rotateX(5deg);
  }
  75% {
    transform: rotateY(165deg) rotateX(-2deg) translateY(-8px);
  }
}

@keyframes float-particle {
  0%, 100% {
    opacity: 0;
    transform: translateY(10px);
  }
  15%, 85% {
    opacity: 0.6;
  }
  50% {
    opacity: 0.8;
    transform: translateY(-15px);
  }
}

@media (max-width: 960px) {
  .hero-doc-scene {
    height: 240px;
  }
  .hero-doc {
    width: 160px;
    height: 210px;
  }
}

@media (max-width: 640px) {
  .hero-doc-scene {
    height: 200px;
  }
  .hero-doc {
    width: 140px;
    height: 180px;
  }
  .particle {
    display: none;
  }
}
</style>
