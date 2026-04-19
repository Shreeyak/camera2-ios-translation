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
title: Introduces scaffold
type: FEATURE
depends_on: [01]
touches: [02-concurrency]
scaffolding_introduced: [02:some-slug]
scaffolding_retired: []
tests_preserved: []
---
Visible: nothing.

---
stage: 03
title: Retires without depending on 02
type: MIGRATION
depends_on: [01]
touches: [02-concurrency]
scaffolding_introduced: []
scaffolding_retired: [02:some-slug]
tests_preserved: []
---
Visible: nothing.
