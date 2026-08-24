// The shell re-renders its title bar on every route change, so bind by delegation.
const actions = ['minimize', 'maximize', 'close'];
const labels = ['最小化', '最大化', '关闭'];
const controls = () => document.querySelectorAll('.win span').forEach((control, index) => {
  if (index > 2) return;
  control.setAttribute('role', 'button');
  control.setAttribute('tabindex', '0');
  control.setAttribute('aria-label', labels[index]);
  control.style.cursor = 'pointer';
});
const run = control => {
  const index = Array.from(control.parentElement.children).indexOf(control);
  if (index >= 0 && index < actions.length) window.yingjiDesktop?.windowAction(actions[index]);
};
document.addEventListener('click', event => {
  const control = event.target.closest('.win span');
  if (control) run(control);
});
document.addEventListener('keydown', event => {
  const control = event.target.closest('.win span');
  if (!control || !['Enter', ' '].includes(event.key)) return;
  event.preventDefault();
  run(control);
});
controls();
new MutationObserver(controls).observe(document.body, { childList: true, subtree: true });
