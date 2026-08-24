const controls = document.querySelectorAll('.win span');
const actions = ['minimize', 'maximize', 'close'];
controls.forEach((control, index) => {
  control.setAttribute('role', 'button');
  control.setAttribute('tabindex', '0');
  control.setAttribute('aria-label', ['最小化', '最大化', '关闭'][index]);
  const run = () => window.yingjiDesktop?.windowAction(actions[index]);
  control.addEventListener('click', run);
  control.addEventListener('keydown', event => (event.key === 'Enter' || event.key === ' ') && run());
});
