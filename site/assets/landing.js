(() => {
  const panel = document.querySelector("[data-signal-panel]");
  const trace = panel?.querySelector(".trace");
  const replay = panel?.querySelector("[data-replay]");

  if (!replay || typeof trace?.getAnimations !== "function") return;

  const motion = window.matchMedia("(prefers-reduced-motion: no-preference)");
  let observer;
  let stopRun;
  let introPlayed = false;

  function stopWatching() {
    if (!observer) return;
    observer.disconnect();
    observer = undefined;
    motion.removeEventListener("change", stopWatching);
  }

  function inView() {
    if (document.hidden) return false;
    const { top, right, bottom, left, width, height } = trace.getBoundingClientRect();
    return width > 0 && height > 0 && bottom > 0 && right > 0 &&
      top < window.innerHeight && left < window.innerWidth;
  }

  function play(reveal = false) {
    stopRun?.();
    if (!motion.matches || document.hidden) return;
    if (reveal && !inView()) trace.scrollIntoView({ block: "nearest", behavior: "instant" });
    // The bounds read also flushes the reset when replaying.
    if (!inView()) return;
    panel.classList.add("is-replaying");

    const run = new AbortController();
    const { signal } = run;
    const finish = () => {
      run.abort();
      panel.classList.remove("is-replaying");
      stopRun = undefined;
    };
    stopRun = finish;

    const stopIfOffscreen = () => {
      if (!inView()) finish();
    };
    window.addEventListener("scroll", stopIfOffscreen, { capture: true, passive: true, signal });
    window.addEventListener("resize", stopIfOffscreen, { signal });
    document.addEventListener("visibilitychange", stopIfOffscreen, { signal });
    motion.addEventListener("change", finish, { signal });

    const animations = trace.getAnimations({ subtree: true });
    Promise.allSettled(animations.map(animation => animation.finished)).then(() => {
      if (!signal.aborted) finish();
    });
  }

  replay.hidden = false;
  replay.addEventListener("click", () => {
    stopWatching();
    play(true);
  });

  if (!motion.matches || !("IntersectionObserver" in window)) return;
  // A touching edge can have zero visible area.
  const threshold = 0.01;
  observer = new IntersectionObserver(entries => {
    if (
      introPlayed ||
      !observer ||
      !entries.some(entry => entry.isIntersecting && entry.intersectionRatio >= threshold)
    ) return;
    introPlayed = true;
    stopWatching();
    play();
  }, { threshold });
  motion.addEventListener("change", stopWatching);
  observer.observe(trace);
})();
