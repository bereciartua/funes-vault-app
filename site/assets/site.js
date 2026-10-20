// funesvault.com's only script. It runs in your browser, sends nothing and
// stores nothing; every page works the same without it.

// The Copy button for the Homebrew command.
document.querySelectorAll("[data-copy]").forEach(function (button) {
  var target = document.getElementById(button.dataset.copy);
  if (!target) return;
  button.hidden = false;
  button.addEventListener("click", function () {
    var done = function (label) {
      button.textContent = label;
      setTimeout(function () { button.textContent = "Copy"; }, 1600);
    };
    var select = function () {
      var range = document.createRange();
      range.selectNodeContents(target);
      var selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      done("Selected");
    };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(target.textContent).then(function () { done("Copied"); }, select);
    } else {
      select();
    }
  });
});

// The eye looks toward the pointer, unless the visitor asked for reduced
// motion. It only moves the iris; nothing is recorded.
(function () {
  var eye = document.querySelector(".eye.follows");
  if (!eye || !window.matchMedia("(prefers-reduced-motion: no-preference)").matches) return;
  var idle;
  window.addEventListener("pointermove", function (event) {
    if (event.pointerType === "touch") return;
    var box = eye.getBoundingClientRect();
    var dx = event.clientX - (box.left + box.width / 2);
    var dy = event.clientY - (box.top + box.height / 2);
    var reach = Math.min(1, Math.hypot(dx, dy) / 500);
    var angle = Math.atan2(dy, dx);
    eye.style.setProperty("--x", (Math.cos(angle) * reach * 92).toFixed(1) + "px");
    eye.style.setProperty("--y", (Math.sin(angle) * reach * 36).toFixed(1) + "px");
    eye.classList.add("tracking");
    clearTimeout(idle);
    idle = setTimeout(function () { eye.classList.remove("tracking"); }, 2500);
  }, { passive: true });
})();
