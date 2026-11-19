const controls = document.querySelector('.gallery-controls');
const gallery = document.querySelector('.gallery');
if (controls && gallery) {
  const buttons = [...controls.querySelectorAll('[data-view]')];
  const panels = [...gallery.querySelectorAll('[data-panel]')];
  const selectView = (button) => {
    buttons.forEach((item) => item.setAttribute('aria-pressed', String(item === button)));
    panels.forEach((panel) => { panel.hidden = panel.dataset.panel !== button.dataset.view; });
  };
  buttons.forEach((button) => button.addEventListener('click', () => {
    selectView(button);
    document.querySelector('.gallery-status').textContent = button.textContent + ' screenshot selected.';
  }));
  selectView(buttons[0]);
  gallery.classList.add('is-interactive');
  controls.hidden = false;
}

if (navigator.clipboard && window.isSecureContext) {
  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.hidden = false;
    button.addEventListener('click', async () => {
      const command = document.getElementById(button.dataset.copy);
      const status = button.closest('.command').nextElementSibling;
      button.disabled = true;
      try {
        await navigator.clipboard.writeText(command.textContent);
        status.textContent = 'Command copied.';
      } catch {
        status.textContent = 'Copy unavailable. Select and copy the command above.';
      } finally {
        button.disabled = false;
      }
    });
  });
}
