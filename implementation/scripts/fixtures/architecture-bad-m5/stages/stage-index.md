# Stage Index — Fixture

---
stage: 01
title: Bare preview
type: FEATURE
depends_on: []
touches: [01-system-shape, 08-ui]
scaffolding_introduced: []
scaffolding_retired: []
tests_preserved: []
---

Visible: Camera feed fills screen.

---
stage: 02
title: Orphan-scaffold stage
type: FEATURE
depends_on: [01]
touches: [02-concurrency]
scaffolding_introduced: [02:orphan-slug]
scaffolding_retired: []
tests_preserved: []
---
Visible: nothing.
