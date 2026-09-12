// Without JavaScript, all three workflows remain readable and images are links.
(() => {
  const tablist = document.querySelector("[data-tabs]");
  const tabs = [...document.querySelectorAll("[data-tab]")];
  const panels = tabs.map(tab => document.querySelector(tab.getAttribute("href")));
  if (tablist && tabs.length === 3 && panels.every(Boolean)) {
    tablist.setAttribute("role", "tablist");
    tabs.forEach((tab, index) => {
      tab.id = `workflow-tab-${index}`;
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-controls", panels[index].id);
      panels[index].setAttribute("role", "tabpanel");
      panels[index].setAttribute("aria-labelledby", tab.id);
      panels[index].tabIndex = 0;
    });
    const activate = (index, focus = false) => {
      tabs.forEach((tab, position) => {
        const selected = position === index;
        tab.setAttribute("aria-selected", String(selected));
        tab.tabIndex = selected ? 0 : -1;
        panels[position].hidden = !selected;
      });
      if (focus) tabs[index].focus();
    };
    const indexForHash = () => panels.findIndex(panel => `#${panel.id}` === location.hash);
    tabs.forEach((tab, index) => {
      tab.addEventListener("click", event => {
        event.preventDefault();
        activate(index);
      });
      tab.addEventListener("keydown", event => {
        let next;
        if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
        if (event.key === "ArrowLeft") next = (index + tabs.length - 1) % tabs.length;
        if (event.key === "Home") next = 0;
        if (event.key === "End") next = tabs.length - 1;
        if (event.key === " ") next = index;
        if (next === undefined) return;
        event.preventDefault();
        activate(next, true);
      });
    });
    document.documentElement.classList.add("features-enhanced");
    activate(Math.max(0, indexForHash()));
    addEventListener("hashchange", () => {
      const index = indexForHash();
      if (index >= 0) activate(index);
    });
  }

  const dialog = document.querySelector("#image-dialog");
  const image = document.querySelector("#dialog-image");
  const title = document.querySelector("#image-dialog-title");
  const close = document.querySelector("[data-close-viewer]");
  let opener;
  if (dialog && image && title && close && typeof dialog.showModal === "function") {
    document.querySelectorAll("[data-viewer]").forEach(link => {
      link.addEventListener("click", event => {
        // Preserve open-in-new-tab and other normal link gestures.
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        opener = link;
        image.src = link.href;
        image.alt = link.querySelector("img")?.alt || link.dataset.title || "Tursora 界面截图";
        title.textContent = link.dataset.title || "Tursora 界面截图";
        dialog.showModal();
        document.body.classList.add("viewer-open");
        close.focus();
      });
    });
    close.addEventListener("click", () => dialog.close());
    dialog.addEventListener("click", event => {
      const rect = dialog.getBoundingClientRect();
      if (event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) dialog.close();
    });
    dialog.addEventListener("close", () => {
      document.body.classList.remove("viewer-open");
      opener?.focus();
    });
  }
})();
