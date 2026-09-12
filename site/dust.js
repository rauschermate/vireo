(() => {
  const canvas = document.getElementById('dust');
  const context = canvas?.getContext('2d');
  if (!context) return;

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const finePointer = window.matchMedia('(any-hover: hover) and (any-pointer: fine)');
  const pointer = { x: 0, y: 0, active: false };
  const radius = 180;
  const margin = 40;
  let width = 0;
  let height = 0;
  let particles = [];
  let frame = 0;
  let previousTime = 0;

  // Paint the soft halo once, instead of creating a gradient for every dot/frame.
  const glow = document.createElement('canvas');
  glow.width = glow.height = 32;
  const glowContext = glow.getContext('2d');
  if (!glowContext) return;
  const gradient = glowContext.createRadialGradient(16, 16, 0, 16, 16, 16);
  gradient.addColorStop(0, 'rgba(233, 234, 239, 0.5)');
  gradient.addColorStop(0.25, 'rgba(233, 234, 239, 0.12)');
  gradient.addColorStop(1, 'rgba(233, 234, 239, 0)');
  glowContext.fillStyle = gradient;
  glowContext.fillRect(0, 0, 32, 32);

  function draw(delta) {
    context.clearRect(0, 0, width, height);
    const ease = 1 - Math.exp(-delta / 0.28);

    for (const particle of particles) {
      particle.x += particle.vx * delta;
      particle.y += particle.vy * delta;
      if (particle.x < -margin) particle.x = width + margin;
      if (particle.x > width + margin) particle.x = -margin;
      if (particle.y < -margin) particle.y = height + margin;
      if (particle.y > height + margin) particle.y = -margin;

      const dx = particle.x - pointer.x;
      const dy = particle.y - pointer.y;
      const distance = Math.hypot(dx, dy);
      const proximity = pointer.active ? Math.max(0, 1 - distance / radius) : 0;
      const influence = proximity * proximity * (3 - 2 * proximity);
      const push = influence * 34;

      // Follow a displaced resting position, so dots ease back without bouncing.
      particle.offsetX += (dx / (distance || 1) * push - particle.offsetX) * ease;
      particle.offsetY += (dy / (distance || 1) * push - particle.offsetY) * ease;
      const fade = 1 - Math.exp(-delta / (influence > particle.light ? 0.12 : 0.8));
      particle.light += (influence - particle.light) * fade;

      const x = particle.x + particle.offsetX;
      const y = particle.y + particle.offsetY;
      const edge = Math.max(0, Math.min(1, x / margin, y / margin,
        (width - x) / margin, (height - y) / margin));

      if (particle.light > 0.01) {
        const size = 10 + particle.size * 5;
        context.globalAlpha = particle.light * edge * 0.5;
        context.drawImage(glow, x - size / 2, y - size / 2, size, size);
      }

      context.globalAlpha = (particle.opacity + particle.light * 0.65) * edge;
      context.fillStyle = '#e9eaef';
      context.beginPath();
      context.arc(x, y, particle.size, 0, Math.PI * 2);
      context.fill();
    }
    context.globalAlpha = 1;
  }

  function animate(time) {
    // Cap elapsed time so returning to a suspended tab never jumps the field.
    const delta = previousTime ? Math.min((time - previousTime) / 1000, 0.05) : 0;
    previousTime = time;
    draw(delta);
    frame = window.requestAnimationFrame(animate);
  }

  function stop() {
    window.cancelAnimationFrame(frame);
    frame = 0;
    previousTime = 0;
    pointer.active = false;
  }

  function syncMotion() {
    stop();
    for (const particle of particles) {
      particle.offsetX = particle.offsetY = particle.light = 0;
    }
    // Touch and reduced-motion visitors get the same faint texture, drawn once.
    draw(0);
    if (!document.hidden && !reducedMotion.matches && finePointer.matches) {
      frame = window.requestAnimationFrame(animate);
    }
  }

  function resize() {
    const bounds = canvas.getBoundingClientRect();
    const scale = Math.min(window.devicePixelRatio || 1, 2);
    width = bounds.width;
    height = bounds.height;
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
    context.setTransform(scale, 0, 0, scale, 0, 0);

    // Keep density consistent and bound work on large/Retina displays.
    const count = Math.min(700, Math.ceil(width * height / 2600));
    particles = Array.from({ length: count }, () => ({
      x: Math.random() * width,
      y: Math.random() * height,
      vx: (Math.random() - 0.5) * 3,
      vy: -(1 + Math.random() * 3),
      size: 0.45 + Math.random() * 0.75,
      opacity: 0.035 + Math.random() * 0.065,
      offsetX: 0,
      offsetY: 0,
      light: 0,
    }));
    syncMotion();
  }

  window.addEventListener('pointermove', (event) => {
    if (event.pointerType !== 'mouse' || reducedMotion.matches || !finePointer.matches) return;
    pointer.x = event.clientX;
    pointer.y = event.clientY;
    pointer.active = true;
  }, { passive: true });
  window.addEventListener('pointerout', (event) => {
    if (!event.relatedTarget) pointer.active = false;
  });
  window.addEventListener('blur', () => { pointer.active = false; });
  window.addEventListener('resize', resize);
  window.addEventListener('pagehide', stop);
  window.addEventListener('pageshow', syncMotion);
  document.addEventListener('visibilitychange', syncMotion);
  reducedMotion.addEventListener('change', syncMotion);
  finePointer.addEventListener('change', syncMotion);
  resize();
})();
