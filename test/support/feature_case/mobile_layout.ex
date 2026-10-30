defmodule MydiaWeb.FeatureCase.MobileLayout do
  @moduledoc """
  Measures the six mobile layout defects from
  `lib/mydia_web/components/README.md`, "Mobile layout sweep", in one JS pass.

  Returns `MydiaWeb.FeatureCase.MobileLayout.Violation` structs naming the
  element and its measurements. Like `MydiaWeb.FeatureCase.Geometry`, this
  measures rendered boxes and never compares screenshots.

  `:scope` (default `"body"`) limits element checks to a subtree; the
  document-level `:page_overflow` check ignores it.
  """

  alias MydiaWeb.FeatureCase.MobileLayout.Violation

  @checks ~w(page_overflow inner_scroll escapes_viewport small_target
             overlapping_targets clipped_text tiny_text)a

  def audit(session, opts \\ []) do
    scope = Keyword.get(opts, :scope, "body")

    session
    |> MydiaWeb.FeatureCase.eval_js(script(), [scope])
    |> Enum.map(fn %{"check" => check, "selector" => selector, "detail" => detail} ->
      %Violation{check: to_check(check), selector: selector, detail: detail}
    end)
  end

  # Only the fixed list above is ever turned into an atom.
  defp to_check(name),
    do: Enum.find(@checks, &(Atom.to_string(&1) == name)) || raise("unknown check #{name}")

  defp script do
    ~S"""
    var scopeSel = arguments[0];
    var root = document.querySelector(scopeSel);
    // innerWidth, not clientWidth: the headless desktop browser reserves ~15px
    // for a classic scrollbar, which phones overlay. The reported vw is the
    // configured viewport width.
    var vw = window.innerWidth;
    var out = [];
    var TOL = 1, MIN_TARGET = 24, MIN_FONT = 12;

    function cls(el) {
      var c = el.className;
      if (c && c.baseVal !== undefined) c = c.baseVal;
      c = String(c || '').trim();
      return c ? '.' + c.split(/\s+/).slice(0, 4).join('.') : '';
    }
    function own(el) { return el.id ? '#' + el.id : el.tagName.toLowerCase() + cls(el); }
    function describe(el) {
      if (el.id) return '#' + el.id;
      var a = el.parentElement;
      while (a && !a.id) a = a.parentElement;
      return (a ? '#' + a.id + ' ' : '') + own(el);
    }
    function push(check, el, detail) {
      out.push({check: check, selector: el ? describe(el) : 'html', detail: detail});
    }
    function visible(el, s, r) {
      if (r.width === 0 || r.height === 0) return false;
      if (s.display === 'none' || s.visibility === 'hidden') return false;
      if (el.closest('[aria-hidden="true"], .sr-only')) return false;
      return true;
    }
    function inRail(el) { return !!el.closest('[data-scroll-rail]'); }
    function hasOwnText(el) {
      for (var n = el.firstChild; n; n = n.nextSibling) {
        if (n.nodeType === 3 && n.textContent.trim() !== '') return true;
      }
      return false;
    }
    function isTarget(el) {
      var t = el.tagName;
      if (t === 'BUTTON' || t === 'SELECT' || t === 'SUMMARY' || t === 'A') return true;
      if (t === 'INPUT') return el.type !== 'hidden';
      if (t === 'LABEL') return el.hasAttribute('for');
      return el.getAttribute('role') === 'button';
    }
    // WCAG 2.5.8 inline exception: a link inside a sentence.
    function inlineLink(el) {
      if (el.tagName !== 'A') return false;
      var p = el.parentElement;
      if (!p || !/^(P|LI|SPAN|TD)$/.test(p.tagName)) return false;
      for (var n = p.firstChild; n; n = n.nextSibling) {
        if (n.nodeType === 3 && n.textContent.trim() !== '') return true;
      }
      return false;
    }
    // A closed drawer parks its side panel off screen on purpose.
    function closedDrawer(el) {
      return !!el.closest('.drawer-side') && !document.querySelector('.drawer-toggle:checked');
    }

    // 1. page_overflow (document-level, ignores scope)
    var d = document.documentElement;
    if (d.scrollWidth > d.clientWidth + TOL) {
      push('page_overflow', null, 'scrollWidth=' + d.scrollWidth + ' vw=' + d.clientWidth);
    }

    if (!root) return out;

    var targets = [];
    var all = root.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var s = getComputedStyle(el);
      var r = el.getBoundingClientRect();
      if (!visible(el, s, r)) continue;
      var rail = inRail(el);

      // 2. inner_scroll
      if (!rail && /(auto|scroll)/.test(s.overflowX) && !/^(PRE|CODE)$/.test(el.tagName) &&
          el.scrollWidth > el.clientWidth + TOL) {
        push('inner_scroll', el, 'clientWidth=' + el.clientWidth + ' scrollWidth=' + el.scrollWidth);
      }

      // 3. escapes_viewport
      if (!rail && (r.right > vw + TOL || r.left < -TOL) && !closedDrawer(el)) {
        push('escapes_viewport', el, 'left=' + Math.round(r.left) + ' right=' + Math.round(r.right) + ' vw=' + vw);
      }

      // 4a. small_target, and collect for 4b
      if (isTarget(el)) {
        if (!inlineLink(el) && (r.width < MIN_TARGET - TOL || r.height < MIN_TARGET - TOL)) {
          push('small_target', el, Math.round(r.width) + 'x' + Math.round(r.height));
        }
        targets.push({el: el, r: r});
      }

      // 5. clipped_text
      if (hasOwnText(el) && !/^(IMG|VIDEO|SVG)$/.test(el.tagName) && !/hero-/.test(String(el.className))) {
        var clipX = /(hidden|clip)/.test(s.overflowX);
        var clipY = /(hidden|clip)/.test(s.overflowY);
        if (clipX && el.scrollWidth > el.clientWidth + TOL && s.textOverflow !== 'ellipsis') {
          push('clipped_text', el, 'clientWidth=' + el.clientWidth + ' scrollWidth=' + el.scrollWidth);
        } else if (clipY && el.scrollHeight > el.clientHeight + TOL &&
                   (s.webkitLineClamp === 'none' || !s.webkitLineClamp)) {
          push('clipped_text', el, 'clientHeight=' + el.clientHeight + ' scrollHeight=' + el.scrollHeight);
        }
      }

      // 6. tiny_text
      if (hasOwnText(el) && parseFloat(s.fontSize) < MIN_FONT - 0.01) {
        push('tiny_text', el, 'font-size=' + s.fontSize);
      }
    }

    // 4b. overlapping_targets
    for (var a = 0; a < targets.length; a++) {
      for (var b = a + 1; b < targets.length; b++) {
        var A = targets[a], B = targets[b];
        if (A.el.contains(B.el) || B.el.contains(A.el)) continue;
        var w = Math.min(A.r.right, B.r.right) - Math.max(A.r.left, B.r.left);
        var h = Math.min(A.r.bottom, B.r.bottom) - Math.max(A.r.top, B.r.top);
        if (w > TOL && h > TOL) {
          push('overlapping_targets', A.el, 'overlaps ' + describe(B.el) + ' by ' + Math.round(w) + 'x' + Math.round(h));
        }
      }
    }

    return out;
    """
  end
end
