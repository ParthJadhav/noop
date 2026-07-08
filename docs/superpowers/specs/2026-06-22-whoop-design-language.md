# WHOOP Design Language — reverse-engineered reference (2026-06-22)

Pixel-sampled from 20 real WHOOP iOS screenshots (`~/Downloads/whoop-ref/` +
`New Folder With Items 18/`). This is the target the NOOP "Design Reset" builds to. Applies
to the DEFAULT theme on dark; the Classic-throwback toggle is untouched.

## The one rule: NO GOLD

WHOOP text is white/grey. It is NEVER gold or amber. There is no gold in the app. Every
section title, label, body string and number is white or grey. The only coloured text is
functional status (green good/up, amber warn/down) and blue links. Premium feel comes from
near-black backgrounds, generous spacing, tight UPPERCASE labels and big white numbers —
NOT a metallic accent.

## Palette (sampled hexes → NOOP token)

```
surfaceBase    #121518   page canvas (cool dark blue-grey, not pure black)
surfaceRaised  #25292C   list-style cards (the common one)
(raised)       #31363A   raised cards (Health/Stress Monitor)
track          #1F252A   ring track + progress-bar track
divider        #1C1F22   hairline between rows

textPrimary    #FFFFFF   titles, labels, numbers — all white
textSecondary  #9AA4AC   baselines, captions
textTertiary   #6B7177   dates, axes, inactive tabs

accent (link)  #60A0E0   ALL action links/labels: SEE TRENDS / EXPLORE / CUSTOMIZE — blue, never gold
statusPositive #03E095   good / up-trend / within-range / green recovery
statusWarning  #F0A020   warn / down-trend / HIGH / alarm-off
statusCritical #E0463C   red — low recovery, notification badges

ring Charge/Recovery  value-based: green #03E095 (>=67%) / yellow #F9DF4A (34-66) / red #E0463C (<=33)
ring Effort/Strain    #4090E0 (always blue; 0-21 scale shown as 9.0)
ring Rest/Sleep       #83A0B8 (always muted slate-blue)
stage deep #A06CE0 (purple) · rem lilac · light #83A0B8 · awake light-grey
```

## Components

- **3 rings (home hero):** order Sleep · Recovery · Strain, three equal rings. Thick stroke
  (~0.10-0.12 of diameter), rounded caps, dark almost-invisible track. Big bold WHITE number
  centred. Label directly below: UPPERCASE white bold + a `›` chevron (`SLEEP ›`). No icons inside.
- **Cards:** fill `#25292C`/`#31363A`, ~16-20px radius, NO borders (fill-contrast separation),
  ~20px padding. Title = UPPERCASE bold white tracked + a right-aligned grey `›` when tappable
  (`HEALTH MONITOR ›`). **Two-card rows** side by side (Health Monitor + Stress Monitor 50/50).
- **My Dashboard metric rows:** `[thin-line white icon]  UPPERCASE LABEL ........ BIG WHITE VALUE [▲/▼]`
  with the 30-day baseline in grey under the value. Trend arrow: green ▲ up (improved), amber ▼ down.
  One continuous list card, hairline dividers. Header "My Dashboard" large mixed-case + blue `CUSTOMIZE ✎`.
- **Hatched typical-range bars (detail):** solid coloured fill = your value, diagonal-hatch track =
  the typical range. "Solid = you, hatch = the context." Swatch + UPPERCASE stage + coloured % + bar +
  right-aligned white duration.
- **Section headers:** two levels — large mixed-case page sections (`My Day`, `My Dashboard`) with a
  right-aligned blue action link; small UPPERCASE tracked card titles.
- **Tab bar:** floating rounded pill, 5 dests (Home · Health · Community · More) + a circular gradient-ring
  avatar. Active = white icon+label, inactive = grey.
- **Top bar (home):** avatar/streak chip left · `‹ TODAY ›` date stepper centre · battery+strap glyph right.

## Typography

Clean grotesque sans (DIN/Proxima-adjacent; Inter/Helvetica Neue/DIN read right). Bold/Semibold for
numbers + labels + titles, Regular for body. UPPERCASE + ~+0.04em tracking on all labels and card
titles. Mixed-case only for big section headers + body sentences. Numbers big, bold, white, tabular,
with a smaller-weight unit suffix.
