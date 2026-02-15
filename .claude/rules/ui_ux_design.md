---
paths:
  - "lib/**/*.dart"
  - "lib/page/**/*.dart"
  - "lib/presentation/**/*.dart"
---

# UI/UX Design Principles (Desktop)

## Design System Consistency

- Pick one primary visual language per screen (Fluent or Material).
- Centralize design tokens (color, typography, spacing, radius, elevation).
- Avoid mixing unrelated component systems in the same surface.
- Ensure clear light/dark behavior and desktop density.

## Layout and Navigation

- Build for wide layouts first, then adapt for compact widths.
- Keep navigation predictable and shallow where possible.
- Preserve stable landmarks (header, navigation, content area).

## Interaction Quality

- Respect hover, focus, pressed, and disabled states.
- Support keyboard navigation and visible focus indicators.
- Use non-blocking feedback for background operations.

## Accessibility

- Maintain sufficient color contrast.
- Provide semantic labels and meaningful control text.
- Do not rely on color alone to convey state.

## Performance and Visual Polish

- Use smooth transitions with purpose, not decoration.
- Avoid unnecessary rebuilds in high-frequency UI paths.
- Keep loading and error states explicit and consistent.

## Checklist

- [ ] Visual language is consistent per screen.
- [ ] Tokens are centralized and reused.
- [ ] Keyboard and focus behavior is valid.
- [ ] Accessibility and state feedback are covered.
