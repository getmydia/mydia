defmodule MydiaWeb.FeatureCase.MobileLayout do
  @moduledoc """
  Measures the six mobile layout defects (seven checks: a small target and
  overlapping targets are both target defects) from
  `lib/mydia_web/components/README.md`, "Mobile layout sweep", in one JS pass.

  Returns `MydiaWeb.FeatureCase.MobileLayout.Violation` structs naming the
  element and its measurements. Like `MydiaWeb.FeatureCase.Geometry`, this
  measures rendered boxes and never compares screenshots.

  `:scope` (default `"body"`) limits element checks to a subtree; the
  document-level `:page_overflow` check ignores it. A scope matching nothing
  raises, so a typo cannot make a quiet test pass.

  The audit hides scrollbars (an injected `#mobile-layout-audit-style` rule) to
  measure the page as a phone lays it out: with overlay scrollbars, layout width
  equals window width. The style stays on the page afterwards.
  """

  alias MydiaWeb.FeatureCase.MobileLayout.Violation

  @checks ~w(page_overflow inner_scroll escapes_viewport small_target
             overlapping_targets clipped_text tiny_text)a

  def audit(session, opts \\ []) do
    scope = Keyword.get(opts, :scope, "body")

    case MydiaWeb.FeatureCase.eval_js(session, script(), [scope]) do
      %{"missing_scope" => sel} ->
        raise "audit: no element matched scope #{inspect(sel)}"

      violations ->
        Enum.map(violations, fn %{"check" => check, "selector" => selector, "detail" => detail} ->
          %Violation{check: to_check(check), selector: selector, detail: detail}
        end)
    end
  end

  # Only the fixed list above is ever turned into an atom.
  defp to_check(name),
    do: Enum.find(@checks, &(Atom.to_string(&1) == name)) || raise("unknown check #{name}")

  defp script do
    ~S"""
    var scopeSel = arguments[0];
    // Phones overlay their scrollbars; hide the desktop ones so layout width
    // equals window width.
    if (!document.getElementById('mobile-layout-audit-style')) {
      var st = document.createElement('style');
      st.id = 'mobile-layout-audit-style';
      st.textContent = '*{scrollbar-width:none !important}*::-webkit-scrollbar{display:none !important}';
      document.head.appendChild(st);
    }
    void document.documentElement.offsetWidth;
    var root = document.querySelector(scopeSel);
    if (!root) return {missing_scope: scopeSel};
    var vw = document.documentElement.clientWidth;
    var out = [];
    var TOL = 1, MIN_TARGET = 24, MIN_FONT = 12;

    function cls(el) {
      var c = el.className;
      if (c && c.baseVal !== undefined) c = c.baseVal;
      c = String(c || '').trim();
      return c ? '.' + c.split(/\s+/).slice(0, 4).join('.') : '';
    }
    // Ids carry database keys (UUIDs, integers) and LiveView's random phx-
    // ids, which differ between runs and adapters, so a selector names the
    // kind of element, not the row.
    function stableId(id) {
      return '#' + id.replace(/^phx-[A-Za-z0-9_-]+$/, 'phx-*')
                     .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '*')
                     .replace(/\d+/g, '*');
    }
    function own(el) { return el.id ? stableId(el.id) : el.tagName.toLowerCase() + cls(el); }
    function describe(el) {
      if (el.id) return stableId(el.id);
      var a = el.parentElement;
      while (a && !a.id) a = a.parentElement;
      return (a ? stableId(a.id) + ' ' : '') + own(el);
    }
    function push(check, el, detail) {
      out.push({check: check, selector: el ? describe(el) : 'html', detail: detail});
    }
    function visible(el, s, r) {
      if (r.width === 0 || r.height === 0) return false;
      if (s.display === 'none' || s.visibility === 'hidden') return false;
      if (el.closest('[aria-hidden="true"], .sr-only')) return false;
      // The body of a closed <details> keeps a layout box but is never
      // painted (content-visibility: hidden), so its rects are meaningless.
      if (el.checkVisibility && !el.checkVisibility()) return false;
      return true;
    }
    // Whether an element sits in a position: fixed layer. Page content
    // scrolls under a fixed dock by design, so a fixed target over a flow
    // target is not a collision. Two fixed targets (a FAB over the dock) can
    // collide, and so can sticky and flow content, so neither is exempt.
    function inFixed(el) {
      for (var a = el; a && a !== document.body; a = a.parentElement) {
        if (getComputedStyle(a).position === 'fixed') return true;
      }
      return false;
    }
    // Measures the glyphs, not scrollWidth: an unloaded lazy <img> showing its
    // alt text, or a badge border, overflows a box without hiding any text.
    // A text node counts only for its nearest clipping ancestor on that axis,
    // so one cut is reported once, by the box doing the cutting (and a
    // truncating child with an ellipsis stays its own, exempt, business).
    function clipperX(n) {
      for (var a = n.parentElement; a; a = a.parentElement) {
        if (getComputedStyle(a).overflowX !== 'visible') return a;
      }
      return null;
    }
    function clipperY(n) {
      for (var a = n.parentElement; a; a = a.parentElement) {
        if (getComputedStyle(a).overflowY !== 'visible') return a;
      }
      return null;
    }
    function clippedText(el, clipX, clipY) {
      var b = el.getBoundingClientRect();
      var L = b.left + el.clientLeft, T = b.top + el.clientTop;
      var R = L + el.clientWidth, B = T + el.clientHeight;
      var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      var range = document.createRange();
      for (var n = walker.nextNode(); n; n = walker.nextNode()) {
        if (n.textContent.trim() === '') continue;
        var cx = clipX && clipperX(n) === el, cy = clipY && clipperY(n) === el;
        if (!cx && !cy) continue;
        range.selectNodeContents(n);
        var rs = range.getClientRects();
        for (var k = 0; k < rs.length; k++) {
          var q = rs[k];
          if (q.width === 0 || q.height === 0) continue;
          if (cx && (q.right > R + TOL || q.left < L - TOL)) {
            return 'box=' + Math.round(L) + '..' + Math.round(R) + ' text=' + Math.round(q.left) + '..' + Math.round(q.right);
          }
          if (cy && (q.bottom > B + TOL || q.top < T - TOL)) {
            return 'box=' + Math.round(T) + '..' + Math.round(B) + ' text=' + Math.round(q.top) + '..' + Math.round(q.bottom);
          }
        }
      }
      return null;
    }
    function within(inner, outer) {
      return inner.left >= outer.left - TOL && inner.right <= outer.right + TOL &&
             inner.top >= outer.top - TOL && inner.bottom <= outer.bottom + TOL;
    }
    // The part of a target its scrolling or clipping ancestors let through,
    // or null when none does. A sidebar link scrolled out of its nav is not
    // under the finger, whatever its layout box overlaps.
    function shownRect(el, r) {
      var L = r.left, T = r.top, R = r.right, B = r.bottom;
      for (var a = el.parentElement; a && a !== document.body; a = a.parentElement) {
        var cs = getComputedStyle(a);
        if (cs.overflowX === 'visible' && cs.overflowY === 'visible') continue;
        var c = a.getBoundingClientRect();
        L = Math.max(L, c.left); T = Math.max(T, c.top);
        R = Math.min(R, c.right); B = Math.min(B, c.bottom);
        if (R - L <= TOL || B - T <= TOL) return null;
      }
      return {left: L, top: T, right: R, bottom: B, width: R - L, height: B - T};
    }
    function overlay(inner, outer) {
      return within(inner, outer) &&
             inner.width * inner.height < (outer.width * outer.height) / 2;
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
    // WCAG 2.5.8 inline exception: a link inside a sentence. The sentence's
    // container can be any element (a <div> of helper text as often as a
    // <p>), so this asks whether the link flows inline among its parent's text.
    function inlineLink(el) {
      if (el.tagName !== 'A' || getComputedStyle(el).display !== 'inline') return false;
      var p = el.parentElement;
      if (!p) return false;
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
      push('page_overflow', null, 'scrollWidth=' + d.scrollWidth + ' vw=' + vw);
    }

    var targets = [];
    var escaped = new Set();
    function escapedAncestor(el) {
      for (var a = el.parentElement; a; a = a.parentElement) {
        if (escaped.has(a)) return true;
      }
      return false;
    }
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
      // Only the outermost escaping element: its descendants escape with it,
      // and listing each would bury the one box that needs fixing. Measured
      // as clipped by its overflow ancestors: a span inside a truncating <p>
      // is cut at the <p>'s edge, so only the <p> can escape.
      var seen = (r.right > vw + TOL || r.left < -TOL) ? shownRect(el, r) : null;
      if (!rail && seen && (seen.right > vw + TOL || seen.left < -TOL) && !closedDrawer(el) &&
          !escapedAncestor(el)) {
        escaped.add(el);
        push('escapes_viewport', el, 'left=' + Math.round(r.left) + ' right=' + Math.round(r.right) + ' vw=' + vw);
      }

      // 4a. small_target, and collect for 4b
      if (isTarget(el)) {
        if (!inlineLink(el) && (r.width < MIN_TARGET - TOL || r.height < MIN_TARGET - TOL)) {
          push('small_target', el, Math.round(r.width) + 'x' + Math.round(r.height));
        }
        var shown = shownRect(el, r);
        if (shown) targets.push({el: el, r: shown, fixed: inFixed(el)});
      }

      // 5. clipped_text
      if (el.textContent.trim() !== '' && !/^(IMG|VIDEO|SVG)$/.test(el.tagName.toUpperCase()) &&
          !/hero-/.test(String(el.className && el.className.baseVal !== undefined ? el.className.baseVal : el.className))) {
        var clipX = /(hidden|clip)/.test(s.overflowX) && s.textOverflow !== 'ellipsis';
        var clipY = /(hidden|clip)/.test(s.overflowY) &&
                    (s.webkitLineClamp === 'none' || !s.webkitLineClamp);
        var cut = (clipX || clipY) ? clippedText(el, clipX, clipY) : null;
        if (cut) push('clipped_text', el, cut);
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
        if (A.fixed !== B.fixed) continue;
        // A control laid over a card (select box, menu button) sits wholly
        // inside a much larger card link: a deliberate overlay, not a
        // collision. Two stacked targets of similar size still collide.
        if (overlay(A.r, B.r) || overlay(B.r, A.r)) continue;
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
