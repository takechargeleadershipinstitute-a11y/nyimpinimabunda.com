/* Short multi-step forms.

   Any <form data-steps> whose fields are grouped in <div class="step"
   data-label="..."> shows one group at a time with "Step 1 of 3" and a bar.
   The form's own submit button reads "Continue" until the last step, then its
   original label. Each form's existing submit handler is untouched: this runs
   first (capture phase) and only lets the submit through on the last step, by
   which point every earlier step has passed its checks.

   Without JavaScript every step shows, so the form still works. */
(function () {
  var css = document.createElement('style');
  css.textContent =
    'form[data-steps].js-steps .step{display:none}' +
    'form[data-steps].js-steps .step.on{display:block;animation:stepIn .22s ease}' +
    '@keyframes stepIn{from{opacity:0;transform:translateX(10px)}to{opacity:1;transform:none}}' +
    '@media(prefers-reduced-motion:reduce){form[data-steps].js-steps .step.on{animation:none}}' +
    '.step-head{display:flex;justify-content:space-between;align-items:baseline;gap:12px;margin:4px 0 8px;' +
      'font-size:10.5px;font-weight:600;letter-spacing:.16em;text-transform:uppercase;color:var(--grey)}' +
    '.step-head b{color:var(--ink);font-weight:600}' +
    '.step-bar{height:3px;background:var(--line);margin-bottom:18px;overflow:hidden}' +
    '.step-bar i{display:block;height:100%;background:var(--amber);transition:width .3s ease}' +
    '.step-back{display:block;margin:12px auto 0;background:none;border:0;padding:6px 10px;cursor:pointer;' +
      'font:600 11px/1 var(--body);letter-spacing:.14em;text-transform:uppercase;color:var(--grey)}' +
    '.step-back:hover{color:var(--ink)}' +
    '.step-back[hidden]{display:none}';
  document.head.appendChild(css);

  function msgOf(form) { return form.querySelector('[role=alert]'); }
  function say(form, text) {
    var m = msgOf(form); if (!m) return;
    m.textContent = text; m.classList.toggle('show', !!text);
  }
  function labelFor(form, el) {
    var l = el.id && form.querySelector('label[for="' + el.id + '"]');
    return l ? l.textContent.replace(/\(.*?\)/g, '').trim().toLowerCase() : 'this field';
  }

  // First problem in a step, as a plain-English message, or ''.
  function problem(form, step) {
    var els = step.querySelectorAll('input[required], select[required], textarea[required]');
    for (var i = 0; i < els.length; i++) {
      var el = els[i], v = (el.value || '').trim();
      if (el.type === 'checkbox') continue;          // consent is checked on the last step by the form itself
      if (!v) {
        el.focus();
        return el.tagName === 'SELECT' ? 'Please choose your ' + labelFor(form, el) + '.'
                                       : 'Please fill in your ' + labelFor(form, el) + '.';
      }
      if (el.type === 'email' && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) {
        el.focus(); return 'That email address does not look right. Please check it.';
      }
    }
    return '';
  }

  [].forEach.call(document.querySelectorAll('form[data-steps]'), function (form) {
    var steps = form.querySelectorAll('.step');
    if (steps.length < 2) return;
    var btn = form.querySelector('button[type=submit]');
    var finalLabel = btn.textContent;
    var at = 0;

    form.setAttribute('novalidate', '');
    form.classList.add('js-steps');

    var head = document.createElement('div'); head.className = 'step-head';
    head.innerHTML = '<span></span><b></b>';
    var bar = document.createElement('div'); bar.className = 'step-bar'; bar.innerHTML = '<i></i>';
    steps[0].parentNode.insertBefore(head, steps[0]);
    steps[0].parentNode.insertBefore(bar, steps[0]);

    var back = document.createElement('button');
    back.type = 'button'; back.className = 'step-back'; back.textContent = '← Back';
    btn.parentNode.insertBefore(back, btn.nextSibling);

    function show(n, focus) {
      at = n;
      [].forEach.call(steps, function (s, i) { s.classList.toggle('on', i === n); });
      head.firstChild.textContent = 'Step ' + (n + 1) + ' of ' + steps.length;
      head.lastChild.textContent = steps[n].getAttribute('data-label') || '';
      bar.firstChild.style.width = ((n + 1) / steps.length * 100) + '%';
      back.hidden = n === 0;
      btn.textContent = n === steps.length - 1 ? finalLabel : 'Continue';
      say(form, '');
      if (focus) {
        var f = steps[n].querySelector('input:not([type=checkbox]), select, textarea');
        if (f) f.focus();
      }
    }

    back.addEventListener('click', function () { if (at > 0) show(at - 1, true); });
    form.addEventListener('reset', function () { setTimeout(function () { show(0, false); }, 0); });

    // Capture on document runs before the form's own submit handler.
    document.addEventListener('submit', function (e) {
      if (e.target !== form) return;
      for (var i = 0; i <= Math.min(at, steps.length - 1); i++) {
        var p = problem(form, steps[i]);
        if (p) { e.preventDefault(); e.stopImmediatePropagation(); if (i !== at) show(i, false); say(form, p); return; }
      }
      if (at < steps.length - 1) {
        e.preventDefault(); e.stopImmediatePropagation();
        show(at + 1, true);
      }
    }, true);

    show(0, false);
  });
})();
