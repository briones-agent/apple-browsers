Feature Spec — Interactive Swipe-Up to Open the Tab Overview

1. Summary
A single, continuous, finger-tracking, fully reversible gesture that transitions the
current page into the all-tabs overview. It is not a fire-and-forget trigger that "opens
a screen" — the transition's progress is bound to the finger and is not finalized until
release.

2. Scope
- Device: iPhone only.
- Availability: only when the address bar is in the bottom position. Not available with a
  top address bar.
- Additive: a second, gestural way into the same existing tab overview. The tabs button
  and all other entry points are unchanged.

3. Activation
- The user touches down anywhere on the bottom bar region (address bar + surrounding
  toolbar) and begins moving upward.
- Upward movement past a small initial threshold begins the transition, so taps and tiny
  jitters don't trigger it.

4. During the gesture
- As the finger moves up, the current tab shrinks / recedes in real time, revealing the
  tab overview forming behind it.
- Progress tracks finger position continuously (1:1 feel) — the further up, the more
  "zoomed out" toward the overview.
- The transition stays uncommitted for as long as the finger is down.

5. Reversibility
- At any point the user can reverse direction. Dragging back down rewinds the transition —
  the current tab grows back toward fullscreen.
- The user can change their mind repeatedly within one gesture; the view follows the finger
  up and down smoothly.

6. Release — commit vs. cancel
On finger-lift, intent decides the outcome:
- Quick upward flick → commit, and animate the rest of the way into the overview, even if
  the drag distance was short (velocity-based).
- Lift past a progress threshold → commit to the overview.
- Lift below the threshold, or after dragging back down → cancel, and snap smoothly back to
  the current page as if nothing happened.

7. Behavior details
- "Swipe up and it just opens" is simply the high-velocity case of this same gesture, not a
  separate path.
- A single open tab is supported: the gesture still works and lands in the overview showing
  that one tab.

8. Feel principles (the point of the project)
- Continuous and physical: motion maps to the finger, with natural momentum.
- Interruptible: can be reversed or cancelled at any moment, mid-flight.
- Forgiving: generous start region (whole bottom bar), small activation threshold, no dead
  zones.
- Native-quality: matches the smoothness users expect from the platform's own interactive
  transitions; no jank or stutter.

9. Explicitly out of scope
- The inverse interactive transition (dragging from within the overview back into a tab).
- Top-address-bar layout, iPad, and any non-iPhone surface.
