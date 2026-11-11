// StudioSim's website: the menu on a small screen, and a picture opened large where it is clicked.
(function () {
  "use strict";

  var toggle = document.querySelector(".nav-toggle");
  var nav = document.getElementById("site-nav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  // The guide's list of pages is folded away on a small screen until asked for.
  var guideMenu = document.querySelector(".guide-menu");
  if (guideMenu && window.matchMedia("(max-width: 900px)").matches) {
    guideMenu.removeAttribute("open");
  }

  // A screenshot opens over the page (without this script, its link opens the picture itself).
  if (typeof HTMLDialogElement !== "function") {
    return;
  }
  var viewer = document.createElement("dialog");
  viewer.className = "viewer";
  viewer.innerHTML = '<form method="dialog"><button class="viewer-close" aria-label="Close">Close</button></form><img alt="">';
  document.body.appendChild(viewer);
  var large = viewer.querySelector("img");
  viewer.addEventListener("click", function (event) {
    if (event.target === viewer || event.target === large) {
      viewer.close();
    }
  });
  Array.prototype.forEach.call(document.querySelectorAll("a.zoom"), function (link) {
    link.addEventListener("click", function (event) {
      if (event.metaKey || event.ctrlKey || event.shiftKey) {
        return;
      }
      event.preventDefault();
      var small = link.querySelector("img");
      large.src = link.getAttribute("href");
      large.alt = small ? small.alt : "";
      viewer.showModal();
    });
  });
})();
